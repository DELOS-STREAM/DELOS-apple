import Foundation
import Metal

/// The render pipeline states of one Metal library, made once per fragment function and pixel format; every draw uses
/// ``MetalPipelineCache/vertexFunction`` (one triangle with a crop, VideoShaders.metal).
final class MetalPipelineCache {
    let device: any MTLDevice
    let library: any MTLLibrary
    private var renders: [Key: any MTLRenderPipelineState] = [:]
    private var computes: [String: any MTLComputePipelineState] = [:]

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

    /// Encodes one full-viewport draw of `fragment` into `target` from `textures`, with `uniforms` at fragment buffer 0.
    @discardableResult
    func draw<Uniforms: BitwiseCopyable>(
        _ fragment: String, into target: any MTLTexture, textures: [any MTLTexture], uniforms: Uniforms?,
        viewport: MTLViewport? = nil, crop: SIMD4<Float> = wholePicture, clear: Bool = false, commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        guard let pipeline = render(fragment, for: target.pixelFormat),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: Self.pass(into: target, clear: clear))
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

/// `ViewportInfo[0]`, `sgsrStrength` and `sgsrEnabled` of the GLSL (UpscalerShaders.metal `UpscaleUniforms`).
struct UpscaleUniforms {
    /// 1 / sampled width, 1 / sampled height, stream width, stream height.
    var viewportInfo: SIMD4<Float>
    var strength: Float
    var enabled: Int32
    /// The Metal struct's padding to 16 bytes, so the bytes handed over are the struct's own.
    var padding = SIMD2<Float>.zero

    init(sampled: (width: Int, height: Int), stream: (width: Int, height: Int), strength: Float, enabled: Bool) {
        viewportInfo = SIMD4(1 / Float(sampled.width), 1 / Float(sampled.height), Float(stream.width), Float(stream.height))
        self.strength = strength
        self.enabled = enabled ? 1 : 0
    }
}

/// What the upscaler made of one frame: the texture the presentation pass samples, and that pass.
struct UpscaledPicture {
    var texture: any MTLTexture
    /// `supersamplePresentFragment`, `temporalPresentFragment`, or nil when `texture` is shown as it is (Sharpen only: the
    /// sharpened picture at the stream's size, scaled to the view like Android's compositor scales its stream-sized output).
    var presentFragment: String?
    var dimensions: UpscalerDimensions
}

/// The upscaler's passes on the GPU, the port of Android's `SgsrRenderer.java` draw path (spatial SGSR 1, supersampling,
/// Sharpen only) and `SgsrTemporal.java` (SGSR 2 for video). Its input is the decoded picture converted to RGB at the
/// stream's size (Android's copy of the external texture): 8-bit, or half floats for 10-bit streams, which keep HDR's
/// encoded PQ/HLG values as Android's P010 path does. Used from the renderer's drawing thread only.
final class MetalUpscaler {
    private let cache: MetalPipelineCache
    /// SGSR 1's reconstruction at the internal size (Android's supersample target), reused at every size.
    private var internalTexture: (any MTLTexture)?
    private var temporal: TemporalReconstruction?

    init(cache: MetalPipelineCache) {
        self.cache = cache
    }

    /// The largest texture side the GPU takes, Android's `GL_MAX_TEXTURE_SIZE`.
    var maxTextureSize: Int { cache.device.supportsFamily(.apple3) || cache.device.supportsFamily(.mac2) ? 16_384 : 8192 }

    /// Forgets the temporal history (the mode changed, the stream restarted).
    func reset() {
        temporal?.reset()
    }

    func releaseResources() {
        internalTexture = nil
        temporal = nil
    }

    /// Encodes the upscaling of `source` for a picture of `presentation` pixels and returns what the presentation pass
    /// samples; nil when a texture or a pass could not be made.
    func upscale(
        source: any MTLTexture, mode: UpscalerMode, presentation: (width: Int, height: Int), supersamplingLevel: Int,
        frameTime: Double, hdr: Bool, reuseFlow: Bool, commandBuffer: any MTLCommandBuffer
    ) -> UpscaledPicture? {
        let stream = (width: source.width, height: source.height)
        if mode == .sharpen {
            // No scaling at any supersampling level: the internal size is the stream's, only the pass runs
            let dimensions = UpscalerDimensions(
                presentationWidth: presentation.width, presentationHeight: presentation.height,
                internalWidth: stream.width, internalHeight: stream.height)
            return UpscaledPicture(texture: source, presentFragment: nil, dimensions: dimensions)
        }
        let dimensions = UpscalerDimensions.plan(
            source: stream, presentation: presentation, maxTextureSize: maxTextureSize, supersamplingLevel: supersamplingLevel)
        let size = (width: dimensions.internalWidth, height: dimensions.internalHeight)
        if mode.isTemporal {
            if temporal == nil || temporal!.width != stream.width || temporal!.height != stream.height {
                temporal = TemporalReconstruction(cache: cache, width: stream.width, height: stream.height)
            }
            guard let temporal,
                  let history = temporal.render(
                    source: source, output: size, timestamp: frameTime, hdr: hdr, quality: mode == .temporalQuality,
                    reuseFlow: reuseFlow, commandBuffer: commandBuffer)
            else { return nil }
            return UpscaledPicture(texture: history, presentFragment: "temporalPresentFragment", dimensions: dimensions)
        }
        // Reuse the supersampling target for the spatial reconstruction, then sharpen once at presentation
        if internalTexture?.width != size.width || internalTexture?.height != size.height || internalTexture?.pixelFormat != source.pixelFormat {
            internalTexture = cache.texture(source.pixelFormat, width: size.width, height: size.height, usage: [.renderTarget, .shaderRead])
        }
        guard let internalTexture else { return nil }
        let uniforms = UpscaleUniforms(
            sampled: stream, stream: stream, strength: 0, enabled: size.width >= stream.width && size.height >= stream.height)
        guard cache.draw(
            mode == .high ? "sgsr1HighFragment" : "sgsr1Fragment", into: internalTexture, textures: [source], uniforms: uniforms,
            commandBuffer: commandBuffer)
        else { return nil }
        return UpscaledPicture(texture: internalTexture, presentFragment: "supersamplePresentFragment", dimensions: dimensions)
    }

    /// The pass that sharpens Sharpen only's picture at the stream's size, into `target` (a stream-sized texture, or the
    /// view's picture when that has the stream's size).
    func sharpen(
        _ picture: UpscaledPicture, sharpness: Float, into target: any MTLTexture, viewport: MTLViewport?, crop: SIMD4<Float>,
        commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        let stream = (width: picture.texture.width, height: picture.texture.height)
        return cache.draw(
            "sharpenOnlyFragment", into: target, textures: [picture.texture],
            uniforms: UpscaleUniforms(sampled: stream, stream: stream, strength: sharpness, enabled: true),
            viewport: viewport, crop: crop, clear: true, commandBuffer: commandBuffer)
    }

    /// The presentation pass of a scaling mode: samples `picture` (at the internal size) into `viewport` of `target`.
    func present(
        _ picture: UpscaledPicture, stream: (width: Int, height: Int), sharpness: Float, into target: any MTLTexture,
        viewport: MTLViewport?, crop: SIMD4<Float>, commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        let sampled = (width: picture.texture.width, height: picture.texture.height)
        return cache.draw(
            picture.presentFragment ?? "supersamplePresentFragment", into: target, textures: [picture.texture],
            uniforms: UpscaleUniforms(sampled: sampled, stream: stream, strength: picture.presentFragment == nil ? 0 : sharpness, enabled: true),
            viewport: viewport, crop: crop, clear: true, commandBuffer: commandBuffer)
    }
}

/// SGSR 2 adapted to decoded video (Android `SgsrTemporal.java`): a luma pyramid of the current and previous frame,
/// backward and forward optical flow on an 8-pixel grid in four levels, a whole-frame cut detector, for the quality mode
/// a reactive mask, and the reconstruction into a history at the internal size.
final class TemporalReconstruction {
    static let levels = 4
    /// A larger gap between two frames' times starts the history again (Android: 50 ms of SurfaceTexture time).
    static let maximumGap = 0.05

    let width: Int
    let height: Int
    private let cache: MetalPipelineCache
    private var luma: [any MTLTexture] = []
    private var backward: [any MTLTexture] = []
    private var forward: [any MTLTexture] = []
    private var history: [any MTLTexture] = []
    private var scene: (any MTLTexture)?
    private var reactive: (any MTLTexture)?
    private var output = (width: 0, height: 0)
    private var index = 0
    private var previousTimestamp = -Double.infinity
    private var valid = false
    private var hdr = false
    private var flowComputed = false

    init?(cache: MetalPipelineCache, width: Int, height: Int) {
        self.cache = cache
        self.width = width
        self.height = height
        for _ in 0..<2 {
            guard let texture = cache.texture(.r8Unorm, width: width, height: height, levels: Self.levels, usage: [.renderTarget, .shaderRead])
            else { return nil }
            luma.append(texture)
        }
        let flowUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        for level in 0..<Self.levels {
            let w = ((width >> level) + 7) / 8, h = ((height >> level) + 7) / 8
            guard let b = cache.texture(.rgba16Float, width: w, height: h, usage: flowUsage),
                  let f = cache.texture(.rgba16Float, width: w, height: h, usage: flowUsage) else { return nil }
            backward.append(b)
            forward.append(f)
        }
        scene = cache.texture(.rgba16Float, width: 1, height: 1, usage: flowUsage)
        reactive = cache.texture(.rgba16Float, width: width, height: height, usage: flowUsage)
        guard scene != nil, reactive != nil else { return nil }
    }

    func reset() { valid = false }

    func render(
        source: any MTLTexture, output size: (width: Int, height: Int), timestamp: Double, hdr: Bool, quality: Bool,
        reuseFlow: Bool, commandBuffer: any MTLCommandBuffer
    ) -> (any MTLTexture)? {
        if output != size {
            history = (0..<2).compactMap { _ in
                cache.texture(.rgba16Float, width: size.width, height: size.height, usage: [.renderTarget, .shaderRead])
            }
            output = size
            valid = false
        }
        guard history.count == 2, let scene, let reactive else { return nil }
        let reset = !valid || timestamp <= previousTimestamp || timestamp - previousTimestamp > Self.maximumGap || self.hdr != hdr
        self.hdr = hdr
        previousTimestamp = timestamp
        guard makeLuma(source, into: luma[index], commandBuffer: commandBuffer) else { return nil }
        // Both flow inputs come from this frame after a reset, so no uninitialised texture is read
        if reset, !makeLuma(source, into: luma[1 - index], commandBuffer: commandBuffer) { return nil }
        // Under load (FlowGovernor) every second frame reuses the previous frame's motion; never after a reset, and never
        // before the first computation
        if !(reuseFlow && !reset && flowComputed) {
            guard flow(current: luma[index], previous: luma[1 - index], into: backward, commandBuffer: commandBuffer),
                  flow(current: luma[1 - index], previous: luma[index], into: forward, commandBuffer: commandBuffer)
            else { return nil }
            flowComputed = true
        }
        guard dispatch("sgsrSceneChange", textures: [scene, luma[index], luma[1 - index]], groups: MTLSize(width: 1, height: 1, depth: 1),
                       commandBuffer: commandBuffer)
        else { return nil }
        if quality {
            var inputSize = SIMD2<Int32>(Int32(width), Int32(height))
            guard dispatch(
                "sgsrActivate", textures: [reactive, luma[index], luma[1 - index], backward[0], forward[0]],
                bytes: &inputSize, length: MemoryLayout<SIMD2<Int32>>.stride,
                groups: MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1), commandBuffer: commandBuffer)
            else { return nil }
        }
        // Official Qualcomm SGSR2RenderPass: bias = output / input, box factor = min(20, areaRatio^3)
        let scaleX = Float(size.width) / Float(width), scaleY = Float(size.height) / Float(height)
        let uniforms = TemporalUniforms(
            renderSize: SIMD2(Float(width), Float(height)), outputSize: SIMD2(Float(size.width), Float(size.height)),
            renderSizeRcp: SIMD2(1 / Float(width), 1 / Float(height)), scaleRatio: SIMD2(scaleX, min(20, pow(scaleX * scaleY, 3))),
            reset: reset ? 1 : 0, qualityMode: quality ? 1 : 0)
        // On reset the shader discards the history; an initialised input is bound anyway
        let previous = reset ? source : history[1 - index]
        guard cache.draw(
            "sgsr2VideoFragment", into: history[index],
            textures: [source, previous, backward[0], forward[0], scene, quality ? reactive : scene], uniforms: uniforms,
            commandBuffer: commandBuffer)
        else { return nil }
        let result = history[index]
        index = 1 - index
        valid = true
        return result
    }

    private func makeLuma(_ source: any MTLTexture, into texture: any MTLTexture, commandBuffer: any MTLCommandBuffer) -> Bool {
        guard cache.draw("sgsrLumaFragment", into: texture, textures: [source], uniforms: Int32?.none, commandBuffer: commandBuffer),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        return true
    }

    private func flow(
        current: any MTLTexture, previous: any MTLTexture, into output: [any MTLTexture], commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        guard let scene else { return false }
        for level in stride(from: Self.levels - 1, through: 0, by: -1) {
            let w = width >> level, h = height >> level
            // The coarsest level does not sample the coarse flow; a different texture is bound anyway
            var uniforms = FlowUniforms(
                level: Int32(level), coarsest: level == Self.levels - 1 ? 1 : 0, levelSize: SIMD2(Int32(w), Int32(h)))
            let coarse = level == Self.levels - 1 ? scene : output[level + 1]
            guard dispatch(
                "sgsrFlow", textures: [output[level], current, previous, coarse], bytes: &uniforms,
                length: MemoryLayout<FlowUniforms>.stride,
                groups: MTLSize(width: (((w + 7) / 8) + 7) / 8, height: (((h + 7) / 8) + 7) / 8, depth: 1), commandBuffer: commandBuffer)
            else { return false }
        }
        return true
    }

    private func dispatch(
        _ kernel: String, textures: [any MTLTexture], bytes: UnsafeRawPointer? = nil, length: Int = 0, groups: MTLSize,
        commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        guard let pipeline = cache.compute(kernel), let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        if let bytes { encoder.setBytes(bytes, length: length, index: 0) }
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        return true
    }
}

/// UpscalerShaders.metal `FlowUniforms`.
struct FlowUniforms {
    var level: Int32
    var coarsest: Int32
    var levelSize: SIMD2<Int32>
}

/// UpscalerShaders.metal `TemporalUniforms`.
struct TemporalUniforms {
    var renderSize: SIMD2<Float>
    var outputSize: SIMD2<Float>
    var renderSizeRcp: SIMD2<Float>
    var scaleRatio: SIMD2<Float>
    var reset: Float
    var qualityMode: Int32
}
