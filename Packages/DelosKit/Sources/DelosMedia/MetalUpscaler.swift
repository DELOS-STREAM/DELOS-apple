import Foundation
import Metal
#if canImport(MetalFX)
import MetalFX
#endif

/// The GPU passes of an upscaled drawing that a ``GPUPassObserver`` can time apart.
enum GPUPass: Int, CaseIterable, Sendable {
    case conversion, flow, metalFX, sharpen, present
}

/// Sees each pass descriptor before its encoder is made (to attach counter sample buffers, for example). MetalFX's own
/// encoders inside `encode(commandBuffer:)` take no descriptor and are not seen.
protocol GPUPassObserver: AnyObject {
    func willEncode(_ pass: GPUPass, render: MTLRenderPassDescriptor)
    func willEncode(_ pass: GPUPass, compute: MTLComputePassDescriptor)
}

/// The render pipeline states of one Metal library, made once per fragment function and pixel format; every draw uses
/// ``MetalPipelineCache/vertexFunction`` (one triangle with a crop, VideoShaders.metal).
final class MetalPipelineCache {
    let device: any MTLDevice
    let library: any MTLLibrary
    private var renders: [Key: any MTLRenderPipelineState] = [:]
    private var computes: [String: any MTLComputePipelineState] = [:]
    /// Sees the descriptors of the passes encoded through this cache; nil changes nothing.
    weak var passObserver: (any GPUPassObserver)?

    private struct Key: Hashable {
        var fragment: String
        var format: MTLPixelFormat
    }

    init(device: any MTLDevice, library: any MTLLibrary) {
        self.device = device
        self.library = library
    }

    func render(_ fragment: String, for format: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
        let key = Key(fragment: fragment, format: format)
        if let pipeline = renders[key] { return pipeline }
        let description = MTLRenderPipelineDescriptor()
        description.vertexFunction = library.makeFunction(name: "videoVertex")
        description.fragmentFunction = library.makeFunction(name: fragment)
        description.colorAttachments[0].pixelFormat = format
        guard description.fragmentFunction != nil, let pipeline = try? device.makeRenderPipelineState(descriptor: description) else {
            return nil
        }
        renders[key] = pipeline
        return pipeline
    }

    func compute(_ kernel: String) -> (any MTLComputePipelineState)? {
        if let pipeline = computes[kernel] { return pipeline }
        guard let function = library.makeFunction(name: kernel),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        computes[kernel] = pipeline
        return pipeline
    }

    /// The crop that shows the whole picture.
    static let wholePicture = SIMD4<Float>(0, 0, 1, 1)

    /// A pass that clears `texture` to black (or keeps nothing of it) and stores what is drawn.
    static func pass(into texture: any MTLTexture, clear: Bool = true) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = clear ? .clear : .dontCare
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    /// Encodes one full-viewport draw of `fragment` into `target` from `textures`, with `uniforms` at fragment buffer 0;
    /// `pass` is what ``passObserver`` is told the draw is.
    @discardableResult
    func draw<Uniforms: BitwiseCopyable>(
        _ fragment: String, into target: any MTLTexture, textures: [any MTLTexture], uniforms: Uniforms?,
        viewport: MTLViewport? = nil, crop: SIMD4<Float> = wholePicture, clear: Bool = false, pass: GPUPass = .present,
        commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        let descriptor = Self.pass(into: target, clear: clear)
        passObserver?.willEncode(pass, render: descriptor)
        guard let pipeline = render(fragment, for: target.pixelFormat),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return false }
        encoder.setViewport(viewport ?? MTLViewport(
            originX: 0, originY: 0, width: Double(target.width), height: Double(target.height), znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        var crop = crop
        encoder.setVertexBytes(&crop, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        for (index, texture) in textures.enumerated() { encoder.setFragmentTexture(texture, index: index) }
        if var uniforms {
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    func texture(
        _ format: MTLPixelFormat, width: Int, height: Int, levels: Int = 1, usage: MTLTextureUsage
    ) -> (any MTLTexture)? {
        let description = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: max(1, width), height: max(1, height), mipmapped: levels > 1)
        if levels > 1 { description.mipmapLevelCount = levels }
        description.usage = usage
        description.storageMode = .private
        return device.makeTexture(descriptor: description)
    }
}

/// UpscalerShaders.metal `CASUniforms`.
struct CASUniforms {
    /// 1 / width, 1 / height of the sampled texture.
    var texelSize: SIMD2<Float>
    /// The sharpness, 0–1.
    var strength: Float
    /// The Metal struct's padding to 16 bytes, so the bytes handed over are the struct's own.
    var padding: Float = 0

    init(sampled: (width: Int, height: Int), strength: Float) {
        texelSize = SIMD2(1 / Float(sampled.width), 1 / Float(sampled.height))
        self.strength = strength
    }
}

/// Which MetalFX scalers this GPU runs. MetalFX is part of iOS and iPadOS, of macOS (`supportsDevice` decides per GPU), and
/// of tvOS from 27.1; the simulators' SDKs have no MetalFX at all. A mode whose scaler is missing runs as Sharpen only and
/// reports the upscaler unavailable (``effectiveMode(_:)``).
public struct MetalFXSupport: Sendable, Equatable {
    public var spatial: Bool
    public var temporal: Bool
    /// The temporal scaler's smallest and largest scale factor on this GPU.
    var temporalScale: ClosedRange<Float>

    /// No MetalFX: every mode runs as Sharpen only.
    public static let none = MetalFXSupport(spatial: false, temporal: false, temporalScale: 1...1)

    /// The scalers of this device's default GPU.
    public static let system = probe(MTLCreateSystemDefaultDevice())

    static func probe(_ device: (any MTLDevice)?) -> MetalFXSupport {
        #if canImport(MetalFX)
        guard let device, #available(tvOS 27.1, *) else { return .none }
        let temporal = MTLFXTemporalScalerDescriptor.supportsDevice(device)
        let low = MTLFXTemporalScalerDescriptor.supportedInputContentMinScale(device: device)
        let high = MTLFXTemporalScalerDescriptor.supportedInputContentMaxScale(device: device)
        return MetalFXSupport(
            spatial: MTLFXSpatialScalerDescriptor.supportsDevice(device), temporal: temporal,
            temporalScale: temporal ? low...max(low, high) : 1...1)
        #else
        return .none
        #endif
    }

    public func supports(_ mode: UpscalerMode) -> Bool {
        switch mode {
        case .spatial: spatial
        case .temporal: temporal
        case .sharpen: true
        }
    }

    /// The mode that runs for `mode` on this GPU: Sharpen only stands in for a missing MetalFX scaler.
    public func effectiveMode(_ mode: UpscalerMode) -> UpscalerMode { supports(mode) ? mode : .sharpen }

    /// The scale factors a scaler for `mode` takes: the temporal scaler's range, any enlargement for the spatial one.
    func scales(_ mode: UpscalerMode) -> ClosedRange<Float> {
        mode == .temporal ? temporalScale : 1...Float.greatestFiniteMagnitude
    }
}

/// What the upscaler made of one frame: the texture the presentation pass samples, and how.
struct UpscaledPicture {
    var texture: any MTLTexture
    /// The MetalFX modes sharpen (CAS) while the picture is presented; Sharpen only's picture was sharpened at the stream's
    /// size already and is presented as it is, scaled to the view.
    var sharpenAtPresentation: Bool
    var dimensions: UpscalerDimensions
}

/// The upscaler's passes on the GPU: MetalFX Spatial (`MTLFXSpatialScaler`), MetalFX Temporal (`MTLFXTemporalScaler`, with
/// motion vectors and a reactive mask made from the video by ``VideoMotion``), and Sharpen only (CAS at the stream's
/// size). MetalFX has no sharpness input, so the MetalFX modes keep the sharpness setting as a CAS pass while their output
/// is presented. The input is the decoded picture converted to RGB at the stream's size: 8-bit, or half floats for 10-bit
/// streams, which keep HDR's encoded PQ/HLG values in 0–1 (MetalFX's perceptual colour processing). Used from the
/// renderer's drawing thread only.
final class MetalUpscaler {
    /// What the stream's RGB picture (the scalers' colour input) must allow besides being drawn into.
    static let sourceUsage: MTLTextureUsage = [.renderTarget, .shaderRead]

    let support: MetalFXSupport
    private let cache: MetalPipelineCache
    /// MetalFX Temporal's motion of the stream (read by the tests).
    private(set) var motion: VideoMotion?
    private var scaler: MetalFXScaler?

    init(cache: MetalPipelineCache, support: MetalFXSupport) {
        self.cache = cache
        self.support = support
    }

    /// The largest texture side the GPU takes.
    var maxTextureSize: Int { cache.device.supportsFamily(.apple3) || cache.device.supportsFamily(.mac2) ? 16_384 : 8192 }

    /// Forgets the temporal history (the mode changed, the stream restarted).
    func reset() {
        motion?.reset()
        scaler?.reset()
    }

    func releaseResources() {
        motion = nil
        scaler = nil
    }

    /// The size MetalFX writes for a stream of `input` pixels when the upscaler's internal size is `target`: the stream
    /// enlarged by one factor on both axes, the smaller of the two (MetalFX keeps the aspect ratio; the presentation
    /// stretches the rest), at most the largest factor in `scales`. Nil when that factor does not enlarge the stream or is
    /// below the smallest in `scales` (a stream as large as the picture or larger): the stream is then presented directly.
    static func scalerOutput(
        input: (width: Int, height: Int), target: (width: Int, height: Int), scales: ClosedRange<Float>
    ) -> (width: Int, height: Int)? {
        guard input.width > 0, input.height > 0 else { return nil }
        let fit = min(Float(target.width) / Float(input.width), Float(target.height) / Float(input.height))
        let scale = min(fit, scales.upperBound)
        guard scale > 1, scale >= scales.lowerBound else { return nil }
        let output = (width: Int((Float(input.width) * scale).rounded()), height: Int((Float(input.height) * scale).rounded()))
        guard output.width > input.width || output.height > input.height else { return nil }
        return (max(output.width, input.width), max(output.height, input.height))
    }

    /// Encodes the upscaling of `source` for a picture of `presentation` pixels and returns what the presentation pass
    /// samples; nil when a texture, a scaler or a pass could not be made. `mode` is one this GPU runs
    /// (``MetalFXSupport/effectiveMode(_:)``).
    func upscale(
        source: any MTLTexture, mode: UpscalerMode, presentation: (width: Int, height: Int), supersamplingLevel: Int,
        frameTime: Double, hdr: Bool, commandBuffer: any MTLCommandBuffer
    ) -> UpscaledPicture? {
        let stream = (width: source.width, height: source.height)
        if mode == .sharpen {
            // No scaling at any supersampling level: the internal size is the stream's, only the pass runs
            let dimensions = UpscalerDimensions(
                presentationWidth: presentation.width, presentationHeight: presentation.height,
                internalWidth: stream.width, internalHeight: stream.height)
            return UpscaledPicture(texture: source, sharpenAtPresentation: false, dimensions: dimensions)
        }
        var dimensions = UpscalerDimensions.plan(
            source: stream, presentation: presentation, maxTextureSize: maxTextureSize, supersamplingLevel: supersamplingLevel)
        guard let output = Self.scalerOutput(
            input: stream, target: (dimensions.internalWidth, dimensions.internalHeight), scales: support.scales(mode))
        else {
            // MetalFX only enlarges: a stream as large as the picture or larger is sampled into it directly
            return UpscaledPicture(texture: source, sharpenAtPresentation: true, dimensions: dimensions)
        }
        dimensions.internalWidth = output.width
        dimensions.internalHeight = output.height
        let key = MetalFXScaler.Key(
            mode: mode, inputWidth: stream.width, inputHeight: stream.height, outputWidth: output.width,
            outputHeight: output.height, format: source.pixelFormat)
        if scaler?.key != key {
            scaler = MetalFXScaler(key: key, cache: cache)
        }
        guard let scaler else { return nil }
        if mode == .temporal {
            if motion?.width != stream.width || motion?.height != stream.height || motion?.usage != scaler.motionUsage {
                motion = VideoMotion(cache: cache, width: stream.width, height: stream.height, usage: scaler.motionUsage)
            }
            guard let motion,
                  let reset = motion.render(
                    source: source, timestamp: frameTime, hdr: hdr, commandBuffer: commandBuffer),
                  scaler.encodeTemporal(
                    color: source, motion: motion.motion, reactiveMask: motion.reactiveMask, reset: reset,
                    commandBuffer: commandBuffer)
            else { return nil }
        } else {
            guard scaler.encodeSpatial(color: source, commandBuffer: commandBuffer) else { return nil }
        }
        return UpscaledPicture(texture: scaler.output, sharpenAtPresentation: true, dimensions: dimensions)
    }

    /// The pass that sharpens Sharpen only's picture at the stream's size, into `target` (a stream-sized texture).
    func sharpen(
        _ picture: UpscaledPicture, sharpness: Float, into target: any MTLTexture, commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        let stream = (width: picture.texture.width, height: picture.texture.height)
        return cache.draw(
            "casFragment", into: target, textures: [picture.texture],
            uniforms: CASUniforms(sampled: stream, strength: sharpness), clear: true, pass: .sharpen,
            commandBuffer: commandBuffer)
    }

    /// The presentation pass: samples `picture` into `viewport` of `target`, sharpened by `sharpness` in the MetalFX modes.
    func present(
        _ picture: UpscaledPicture, sharpness: Float, into target: any MTLTexture, viewport: MTLViewport?, crop: SIMD4<Float>,
        commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        let sampled = (width: picture.texture.width, height: picture.texture.height)
        return cache.draw(
            "casFragment", into: target, textures: [picture.texture],
            uniforms: CASUniforms(sampled: sampled, strength: picture.sharpenAtPresentation ? sharpness : 0),
            viewport: viewport, crop: crop, clear: true, pass: .present, commandBuffer: commandBuffer)
    }
}

/// One MetalFX scaler with its output texture (and for the temporal scaler its depth texture), made again when the mode,
/// the sizes or the format change. Decoded video has no depth: the temporal scaler gets a constant plane at depth 0.5
/// (not reversed), so depth never separates one pixel from another, and disocclusions come from the reactive mask
/// instead. Its jitter is 0 (the video is not rendered with sub-pixel jitter). The scalers are kept as `AnyObject`
/// because their protocols exist on tvOS only from 27.1; the simulators build without MetalFX and never make one.
final class MetalFXScaler {
    struct Key: Equatable {
        var mode: UpscalerMode
        var inputWidth: Int
        var inputHeight: Int
        var outputWidth: Int
        var outputHeight: Int
        var format: MTLPixelFormat
    }

    static let depthFormat: MTLPixelFormat = .depth32Float
    static let motionFormat: MTLPixelFormat = .rg16Float
    static let reactiveMaskFormat: MTLPixelFormat = .r16Float
    /// The video's constant depth: the middle of the range, away from the cleared near and far values.
    static let depth = 0.5

    let key: Key
    let output: any MTLTexture
    /// The usage the temporal scaler needs on the motion texture and the reactive mask, besides being written by a kernel.
    let motionUsage: MTLTextureUsage
    private let scaler: AnyObject
    private let depth: (any MTLTexture)?
    private let cache: MetalPipelineCache
    /// The depth plane is still to be cleared (the first encoding), or the history to be dropped.
    private var depthCleared = false
    private var needsReset = true

    init?(key: Key, cache: MetalPipelineCache) {
        #if canImport(MetalFX)
        guard #available(tvOS 27.1, *) else { return nil }
        let device = cache.device
        self.key = key
        self.cache = cache
        switch key.mode {
        case .spatial:
            let description = MTLFXSpatialScalerDescriptor()
            description.inputWidth = key.inputWidth
            description.inputHeight = key.inputHeight
            description.outputWidth = key.outputWidth
            description.outputHeight = key.outputHeight
            description.colorTextureFormat = key.format
            description.outputTextureFormat = key.format
            description.colorProcessingMode = .perceptual
            guard let scaler = description.makeSpatialScaler(device: device),
                  scaler.colorTextureUsage.isSubset(of: MetalUpscaler.sourceUsage),
                  let output = cache.texture(
                    key.format, width: key.outputWidth, height: key.outputHeight, usage: scaler.outputTextureUsage.union(.shaderRead))
            else { return nil }
            self.scaler = scaler
            self.output = output
            depth = nil
            motionUsage = []
        case .temporal:
            let description = Self.temporalDescriptor(key)
            guard let scaler = description.makeTemporalScaler(device: device),
                  scaler.colorTextureUsage.isSubset(of: MetalUpscaler.sourceUsage),
                  let output = cache.texture(
                    key.format, width: key.outputWidth, height: key.outputHeight, usage: scaler.outputTextureUsage.union(.shaderRead)),
                  let depth = cache.texture(
                    Self.depthFormat, width: key.inputWidth, height: key.inputHeight,
                    usage: scaler.depthTextureUsage.union(.renderTarget))
            else { return nil }
            self.scaler = scaler
            self.output = output
            self.depth = depth
            motionUsage = scaler.motionTextureUsage
        case .sharpen:
            return nil
        }
        #else
        return nil
        #endif
    }

    /// The next encoding drops the temporal history.
    func reset() { needsReset = true }

    #if canImport(MetalFX)
    /// The temporal scaler's settings for decoded video: no auto exposure (the colours are display-encoded already), the
    /// reactive mask on, fixed input size.
    @available(tvOS 27.1, *)
    static func temporalDescriptor(_ key: Key) -> MTLFXTemporalScalerDescriptor {
        let description = MTLFXTemporalScalerDescriptor()
        description.inputWidth = key.inputWidth
        description.inputHeight = key.inputHeight
        description.outputWidth = key.outputWidth
        description.outputHeight = key.outputHeight
        description.colorTextureFormat = key.format
        description.outputTextureFormat = key.format
        description.depthTextureFormat = depthFormat
        description.motionTextureFormat = motionFormat
        description.isAutoExposureEnabled = false
        description.isInputContentPropertiesEnabled = false
        description.isReactiveMaskTextureEnabled = true
        description.reactiveMaskTextureFormat = reactiveMaskFormat
        return description
    }

    /// The per-frame settings of the temporal scaler for decoded video (``TemporalFrame``).
    @available(tvOS 27.1, *)
    static func configure(_ scaler: any MTLFXTemporalScaler, _ frame: TemporalFrame) {
        scaler.inputContentWidth = frame.inputWidth
        scaler.inputContentHeight = frame.inputHeight
        scaler.jitterOffsetX = frame.jitter.x
        scaler.jitterOffsetY = frame.jitter.y
        scaler.motionVectorScaleX = frame.motionVectorScale.x
        scaler.motionVectorScaleY = frame.motionVectorScale.y
        scaler.isDepthReversed = frame.depthReversed
        scaler.preExposure = 1
        scaler.reset = frame.reset
    }
    #endif

    func encodeSpatial(color: any MTLTexture, commandBuffer: any MTLCommandBuffer) -> Bool {
        #if canImport(MetalFX)
        guard #available(tvOS 27.1, *), let scaler = scaler as? any MTLFXSpatialScaler else { return false }
        scaler.colorTexture = color
        scaler.outputTexture = output
        scaler.inputContentWidth = key.inputWidth
        scaler.inputContentHeight = key.inputHeight
        scaler.encode(commandBuffer: commandBuffer)
        return true
        #else
        return false
        #endif
    }

    func encodeTemporal(
        color: any MTLTexture, motion: any MTLTexture, reactiveMask: any MTLTexture, reset: Bool,
        commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        #if canImport(MetalFX)
        guard #available(tvOS 27.1, *), let scaler = scaler as? any MTLFXTemporalScaler, let depth else { return false }
        if !depthCleared {
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = Self.depth
            pass.depthAttachment.storeAction = .store
            cache.passObserver?.willEncode(.metalFX, render: pass)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
            encoder.endEncoding()
            depthCleared = true
        }
        scaler.colorTexture = color
        scaler.depthTexture = depth
        scaler.motionTexture = motion
        scaler.reactiveMaskTexture = reactiveMask
        scaler.outputTexture = output
        Self.configure(scaler, TemporalFrame(inputWidth: key.inputWidth, inputHeight: key.inputHeight, reset: reset || needsReset))
        needsReset = false
        scaler.encode(commandBuffer: commandBuffer)
        return true
        #else
        return false
        #endif
    }
}

/// What MetalFX Temporal is told about one frame of decoded video: the whole input, no jitter, motion vectors in input
/// pixels (scale 1, pointing from the pixel to where it was in the previous frame), the depth plane not reversed, and
/// whether the history starts again.
struct TemporalFrame: Equatable {
    var inputWidth: Int
    var inputHeight: Int
    var reset: Bool
    var jitter = SIMD2<Float>.zero
    var motionVectorScale = SIMD2<Float>(1, 1)
    var depthReversed = false
}

/// The motion of decoded video for MetalFX Temporal, which a game would render itself: a luma pyramid of the current and
/// the previous frame, backward and forward optical flow on an 8-pixel grid in four levels (computed for every frame: a
/// reused flow is stale by a frame and makes MetalFX drift), a whole-frame cut detector, and from them per-pixel motion
/// vectors and a reactive mask at the stream's size (UpscalerShaders.metal `videoMotion`). A cut cannot reset the scaler
/// from the CPU in the same frame (its result is on the GPU), so it sets the whole reactive mask to 1, which makes MetalFX
/// ignore the history for that frame.
/// Every pass of a frame runs in one compute encoder (its dispatches run in order), and every texture is made once.
final class VideoMotion {
    /// The pyramid's levels: `videoLumaPyramid` reduces an 8 × 8 threadgroup to one texel of level 3.
    static let levels = 4
    /// A larger gap between two frames' times starts the history again.
    static let maximumGap = 0.05
    static let flowFormat: MTLPixelFormat = .rg16Float

    let width: Int
    let height: Int
    let usage: MTLTextureUsage
    /// MetalFX's motion texture (``MetalFXScaler/motionFormat``).
    let motion: any MTLTexture
    /// MetalFX's reactive mask (``MetalFXScaler/reactiveMaskFormat``).
    let reactiveMask: any MTLTexture
    private let cache: MetalPipelineCache
    private var luma: [any MTLTexture] = []
    private var backward: [any MTLTexture] = []
    private var forward: [any MTLTexture] = []
    /// Per-pixel rejection before adding the boundary between competing motions.
    private let pixelMask: any MTLTexture
    private let scene: any MTLTexture
    private var index = 0
    private var previousTimestamp = -Double.infinity
    private var valid = false
    private var hdr = false

    init?(cache: MetalPipelineCache, width: Int, height: Int, usage: MTLTextureUsage) {
        self.cache = cache
        self.width = width
        self.height = height
        self.usage = usage
        let kernelUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        for _ in 0..<2 {
            guard let texture = cache.texture(.r8Unorm, width: width, height: height, levels: Self.levels, usage: kernelUsage)
            else { return nil }
            luma.append(texture)
        }
        for level in 0..<Self.levels {
            let w = ((width >> level) + 7) / 8, h = ((height >> level) + 7) / 8
            guard let b = cache.texture(Self.flowFormat, width: w, height: h, usage: kernelUsage),
                  let f = cache.texture(Self.flowFormat, width: w, height: h, usage: kernelUsage) else { return nil }
            backward.append(b)
            forward.append(f)
        }
        guard let scene = cache.texture(.r16Float, width: 1, height: 1, usage: kernelUsage),
              let pixelMask = cache.texture(.r8Unorm, width: width, height: height, usage: kernelUsage),
              let motion = cache.texture(MetalFXScaler.motionFormat, width: width, height: height, usage: kernelUsage.union(usage)),
              let reactiveMask = cache.texture(
                MetalFXScaler.reactiveMaskFormat, width: width, height: height, usage: kernelUsage.union(usage))
        else { return nil }
        self.pixelMask = pixelMask
        self.scene = scene
        self.motion = motion
        self.reactiveMask = reactiveMask
    }

    func reset() { valid = false }

    /// Whether a frame at `timestamp` starts the history again: the first frame, a frame out of order or after a gap, or a
    /// change between SDR and HDR (the encoded values change meaning).
    static func startsAgain(valid: Bool, previous: Double, timestamp: Double, hdrChanged: Bool) -> Bool {
        !valid || timestamp <= previous || timestamp - previous > maximumGap || hdrChanged
    }

    /// Encodes the motion and the reactive mask of `source` against the previous frame. Returns whether the scaler must
    /// drop its history (``startsAgain(valid:previous:timestamp:hdrChanged:)``), nil when a pass could not be made.
    func render(
        source: any MTLTexture, timestamp: Double, hdr: Bool, commandBuffer: any MTLCommandBuffer
    ) -> Bool? {
        let reset = Self.startsAgain(valid: valid, previous: previousTimestamp, timestamp: timestamp, hdrChanged: self.hdr != hdr)
        self.hdr = hdr
        previousTimestamp = timestamp
        let pass = MTLComputePassDescriptor()
        cache.passObserver?.willEncode(.flow, compute: pass)
        guard let encoder = commandBuffer.makeComputeCommandEncoder(descriptor: pass) else { return nil }
        defer { encoder.endEncoding() }
        let pyramid = MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1)
        guard dispatch("videoLumaPyramid", textures: [luma[index], source], groups: pyramid, encoder: encoder) else { return nil }
        // Both flow inputs come from this frame after a reset, so no uninitialised texture is read
        if reset, !dispatch("videoLumaPyramid", textures: [luma[1 - index], source], groups: pyramid, encoder: encoder) {
            return nil
        }
        guard flow(current: luma[index], previous: luma[1 - index], into: backward, encoder: encoder),
              flow(current: luma[1 - index], previous: luma[index], into: forward, encoder: encoder)
        else { return nil }
        guard dispatch(
            "videoSceneChange", textures: [scene, luma[index], luma[1 - index]], groups: MTLSize(width: 1, height: 1, depth: 1),
            encoder: encoder)
        else { return nil }
        var inputSize = SIMD2<Int32>(Int32(width), Int32(height))
        guard dispatch(
            "videoMotion",
            textures: [motion, pixelMask, luma[index], luma[1 - index], backward[0], forward[0], scene],
            bytes: &inputSize, length: MemoryLayout<SIMD2<Int32>>.stride, groups: pyramid, encoder: encoder),
              dispatch("videoReactiveMask", textures: [reactiveMask, pixelMask, motion, luma[index]], groups: pyramid, encoder: encoder)
        else { return nil }
        index = 1 - index
        valid = true
        return reset
    }

    private func flow(
        current: any MTLTexture, previous: any MTLTexture, into output: [any MTLTexture], encoder: any MTLComputeCommandEncoder
    ) -> Bool {
        for level in stride(from: Self.levels - 1, through: 0, by: -1) {
            let w = width >> level, h = height >> level
            // The coarsest level does not sample the coarse flow; a different texture is bound anyway
            var uniforms = FlowUniforms(
                level: Int32(level), coarsest: level == Self.levels - 1 ? 1 : 0, levelSize: SIMD2(Int32(w), Int32(h)))
            let coarse = level == Self.levels - 1 ? scene : output[level + 1]
            guard dispatch(
                "videoFlow", textures: [output[level], current, previous, coarse], bytes: &uniforms,
                length: MemoryLayout<FlowUniforms>.stride,
                groups: MTLSize(width: (output[level].width + 7) / 8, height: (output[level].height + 7) / 8, depth: 1),
                encoder: encoder)
            else { return false }
        }
        return true
    }

    private func dispatch(
        _ kernel: String, textures: [any MTLTexture], bytes: UnsafeRawPointer? = nil, length: Int = 0, groups: MTLSize,
        encoder: any MTLComputeCommandEncoder
    ) -> Bool {
        guard let pipeline = cache.compute(kernel) else { return false }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        if let bytes { encoder.setBytes(bytes, length: length, index: 0) }
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        return true
    }
}

/// UpscalerShaders.metal `FlowUniforms`.
struct FlowUniforms {
    var level: Int32
    var coarsest: Int32
    var levelSize: SIMD2<Int32>
}
