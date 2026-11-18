import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Where a picture goes on a target for a scale mode (Android `StreamDisplayPlanner`'s aspect ratio and fill flag, which
/// size the stream's SurfaceView): the viewport on the target, the part of the picture it shows, and the size of the whole
/// picture in pixels (the upscaler's presentation size; larger than the target for Fill).
struct PictureGeometry {
    var viewport: MTLViewport
    /// Origin and size of the shown part, in picture coordinates (0–1).
    var crop: SIMD4<Float>
    var presentationWidth: Int
    var presentationHeight: Int

    /// [topAligned] (`checkbox_enable_view_top_center`): Fit puts the picture at the top of the target instead of the
    /// middle, and Fill cuts off only its bottom; Stretch fills the target either way.
    static func make(
        video: (width: Int, height: Int), target: (width: Int, height: Int), mode: VideoScaleMode, topAligned: Bool = false
    ) -> PictureGeometry {
        let whole = MTLViewport(originX: 0, originY: 0, width: Double(target.width), height: Double(target.height), znear: 0, zfar: 1)
        guard video.width > 0, video.height > 0, target.width > 0, target.height > 0 else {
            return PictureGeometry(viewport: whole, crop: MetalPipelineCache.wholePicture, presentationWidth: target.width, presentationHeight: target.height)
        }
        switch mode {
        case .fit:
            var fitted = MetalFrameDrawer.fittedViewport(video: video, target: target)
            if topAligned { fitted.originY = 0 }
            return PictureGeometry(
                viewport: fitted, crop: MetalPipelineCache.wholePicture,
                presentationWidth: Int(fitted.width), presentationHeight: Int(fitted.height))
        case .stretch:
            return PictureGeometry(
                viewport: whole, crop: MetalPipelineCache.wholePicture, presentationWidth: target.width, presentationHeight: target.height)
        case .fill:
            let scale = max(Double(target.width) / Double(video.width), Double(target.height) / Double(video.height))
            let width = max(Double(target.width), (Double(video.width) * scale).rounded())
            let height = max(Double(target.height), (Double(video.height) * scale).rounded())
            let shown = SIMD2<Float>(Float(Double(target.width) / width), Float(Double(target.height) / height))
            return PictureGeometry(
                viewport: whole, crop: SIMD4((1 - shown.x) / 2, topAligned ? 0 : (1 - shown.y) / 2, shown.x, shown.y),
                presentationWidth: Int(width), presentationHeight: Int(height))
        }
    }
}

/// What the renderer asks of the upscaler for one drawing.
struct UpscaleRequest {
    var settings: UpscalerSettings
    /// The frame's number: a drawing of the same frame again (a resize, the arrival) presents its upscaled picture again
    /// and never feeds it to the temporal history twice.
    var sequence: Int
    /// When the frame was decoded (seconds): the temporal history starts again after a gap.
    var frameTime: Double
}

/// What a drawing through the upscaler did, for the renderer's statistics and load decisions.
/// Command buffers are thread-safe Metal objects; the report crosses into the pipeline's lock and completion handlers.
struct UpscaleReport: @unchecked Sendable {
    /// The mode that ran: the requested one, or Sharpen only where this device lacks its MetalFX scaler.
    var mode: UpscalerMode
    var dimensions: UpscalerDimensions
    /// True when this frame was upscaled now, false when an earlier upscaled picture was presented again.
    var fresh: Bool
    /// The requested mode could not run here and Sharpen only stood in (the status is unavailable).
    var fellBack = false
    /// Sharpen only: the conversion and the pass in command buffers of their own, so their GPU times are known apart
    /// (Android's `SharpenMeter` copy and pass spans).
    var preparation: (any MTLCommandBuffer)?
    var pass: (any MTLCommandBuffer)?
}

/// Draws decoded pictures into Metal textures: the pixel buffer's planes become textures through a
/// `CVMetalTextureCache` (no copy: they share the IOSurface), a fragment shader converts the Y'CbCr to RGB
/// (``ColorConversion``) and the picture is placed on the target by the scale mode, on black. With the upscaler the
/// picture is converted at its own size first and the ``MetalUpscaler`` reconstructs and presents it.
///
/// Used from one thread at a time (the display link's).
final class MetalFrameDrawer: @unchecked Sendable {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let cache: MetalPipelineCache
    private let textureCache: CVMetalTextureCache
    private let upscaler: MetalUpscaler
    /// The arrival pass's source (``LaunchArrival``), kept from frame to frame while it runs.
    private var arrivalTexture: (any MTLTexture)?
    /// The picture converted to RGB at its own size, the upscaler's input (Android's `colorTexture`).
    private var sourceTexture: (any MTLTexture)?
    /// Sharpen only's output at the stream's size.
    private var sharpenedTexture: (any MTLTexture)?
    private var upscaled: (key: UpscaleKey, picture: UpscaledPicture)?
    private var upscaledMode: UpscalerMode?
    private var drawn = 0
    /// What the last drawing through the upscaler did; nil when it was drawn directly.
    private(set) var lastReport: UpscaleReport?

    private struct UpscaleKey: Equatable {
        var sequence: Int
        var mode: UpscalerMode
        var presentationWidth: Int
        var presentationHeight: Int
        var level: Int
        var sharpness: Int
        var format: MTLPixelFormat
    }

    /// `metalFX`: the MetalFX scalers to use, nil for those of `device` (tests pass ``MetalFXSupport/none``).
    init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(), metalFX: MetalFXSupport? = nil) {
        guard let device, let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .module) else { return nil }
        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess, let textureCache else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.textureCache = textureCache
        cache = MetalPipelineCache(device: device, library: library)
        upscaler = MetalUpscaler(cache: cache, support: metalFX ?? MetalFXSupport.probe(device))
    }

    /// The rectangle of a `width` × `height` target the picture fills, in pixels: as large as fits, in the middle.
    static func fittedViewport(video: (width: Int, height: Int), target: (width: Int, height: Int)) -> MTLViewport {
        guard video.width > 0, video.height > 0, target.width > 0, target.height > 0 else {
            return MTLViewport(originX: 0, originY: 0, width: Double(target.width), height: Double(target.height), znear: 0, zfar: 1)
        }
        let scale = min(Double(target.width) / Double(video.width), Double(target.height) / Double(video.height))
        let width = (Double(video.width) * scale).rounded(), height = (Double(video.height) * scale).rounded()
        return MTLViewport(
            originX: ((Double(target.width) - width) / 2).rounded(), originY: ((Double(target.height) - height) / 2).rounded(),
            width: width, height: height, znear: 0, zfar: 1)
    }

    /// Encodes the drawing of `pixelBuffer` into `target` in `commandBuffer`, placed by `scaleMode` (at the top when
    /// `topAligned`, ``PictureGeometry/make(video:target:mode:topAligned:)``). With an `upscale`
    /// request the upscaler draws it (``lastReport`` says what it did). With an `arrival` pose the picture (converted, or
    /// upscaled) is first drawn into an RGB texture with mip levels (8-bit, or half floats for 10-bit pictures, which keep
    /// HDR's encoded values), and the arrival pass draws it posed. False when the buffer's format is not drawable or a
    /// texture or pass could not be made.
    func draw(
        _ pixelBuffer: CVPixelBuffer, conversion: ColorConversion, into target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer, arrival: ArrivalPose? = nil, scaleMode: VideoScaleMode = .fit,
        topAligned: Bool = false, upscale: UpscaleRequest? = nil
    ) -> Bool {
        lastReport = nil
        let wide = conversion.bitDepth > 8
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let geometry = PictureGeometry.make(
            video: (width, height), target: (target.width, target.height), mode: scaleMode, topAligned: topAligned)
        let drew: Bool
        if let upscale {
            drew = drawUpscaled(
                pixelBuffer, conversion: conversion, size: (width, height), wide: wide, into: target, geometry: geometry,
                commandBuffer: commandBuffer, arrival: arrival, request: upscale)
        } else {
            releaseUpscaler()
            drew = drawDirect(
                pixelBuffer, conversion: conversion, size: (width, height), wide: wide, into: target, geometry: geometry,
                commandBuffer: commandBuffer, arrival: arrival)
        }
        guard drew else { return false }
        drawn += 1
        if drawn % 60 == 0 { CVMetalTextureCacheFlush(textureCache, 0) }
        return true
    }

    private func drawDirect(
        _ pixelBuffer: CVPixelBuffer, conversion: ColorConversion, size: (width: Int, height: Int), wide: Bool,
        into target: any MTLTexture, geometry: PictureGeometry, commandBuffer: any MTLCommandBuffer, arrival: ArrivalPose?
    ) -> Bool {
        if let arrival, let source = arrivalSource(width: size.width, height: size.height, wide: wide) {
            let whole = MTLViewport(originX: 0, originY: 0, width: Double(size.width), height: Double(size.height), znear: 0, zfar: 1)
            guard convert(pixelBuffer, conversion: conversion, into: source, viewport: whole, crop: MetalPipelineCache.wholePicture,
                          commandBuffer: commandBuffer)
            else { return false }
            return drawArrival(source, pose: arrival, into: target, geometry: geometry, commandBuffer: commandBuffer)
        }
        // The arrival is over (or has not begun): its texture is not kept for the rest of the stream
        arrivalTexture = nil
        return convert(pixelBuffer, conversion: conversion, into: target, viewport: geometry.viewport, crop: geometry.crop,
                       commandBuffer: commandBuffer)
    }

    private func drawUpscaled(
        _ pixelBuffer: CVPixelBuffer, conversion: ColorConversion, size: (width: Int, height: Int), wide: Bool,
        into target: any MTLTexture, geometry: PictureGeometry, commandBuffer: any MTLCommandBuffer, arrival: ArrivalPose?,
        request: UpscaleRequest
    ) -> Bool {
        let settings = request.settings
        // Without the mode's MetalFX scaler Sharpen only stands in, and the status says the upscaler is unavailable
        let mode = upscaler.support.effectiveMode(settings.mode)
        let fellBack = mode != settings.mode
        let format: MTLPixelFormat = wide ? .rgba16Float : .rgba8Unorm
        if upscaledMode != mode {
            // A new mode starts with a fresh history
            upscaledMode = mode
            upscaler.reset()
        }
        let key = UpscaleKey(
            sequence: request.sequence, mode: mode, presentationWidth: geometry.presentationWidth,
            presentationHeight: geometry.presentationHeight, level: settings.supersamplingLevel,
            sharpness: mode == .sharpen ? settings.sharpness : 0, format: format)
        let sharpness = Float(settings.sharpness) / 100
        var report: UpscaleReport
        let picture: UpscaledPicture
        if let upscaled, upscaled.key == key {
            picture = upscaled.picture
            report = UpscaleReport(mode: mode, dimensions: picture.dimensions, fresh: false, fellBack: fellBack)
        } else {
            if sourceTexture?.width != size.width || sourceTexture?.height != size.height || sourceTexture?.pixelFormat != format {
                sourceTexture = cache.texture(format, width: size.width, height: size.height, usage: MetalUpscaler.sourceUsage)
            }
            guard let source = sourceTexture else { return false }
            let sharpenOnly = mode == .sharpen
            // Sharpen only measures its preparation and its pass apart, each in a command buffer of its own
            guard let preparation = sharpenOnly ? queue.makeCommandBuffer() : commandBuffer else { return false }
            let whole = MTLViewport(originX: 0, originY: 0, width: Double(size.width), height: Double(size.height), znear: 0, zfar: 1)
            guard convert(pixelBuffer, conversion: conversion, into: source, viewport: whole, crop: MetalPipelineCache.wholePicture,
                          commandBuffer: preparation)
            else { return false }
            if sharpenOnly { preparation.commit() }
            guard var made = upscaler.upscale(
                source: source, mode: mode,
                presentation: (geometry.presentationWidth, geometry.presentationHeight),
                supersamplingLevel: settings.supersamplingLevel, frameTime: request.frameTime, hdr: conversion.isHDR,
                commandBuffer: commandBuffer)
            else { return false }
            report = UpscaleReport(mode: mode, dimensions: made.dimensions, fresh: true, fellBack: fellBack)
            if sharpenOnly {
                if sharpenedTexture?.width != size.width || sharpenedTexture?.height != size.height || sharpenedTexture?.pixelFormat != format {
                    sharpenedTexture = cache.texture(format, width: size.width, height: size.height, usage: [.renderTarget, .shaderRead])
                }
                guard let sharpened = sharpenedTexture, let pass = queue.makeCommandBuffer(),
                      upscaler.sharpen(made, sharpness: sharpness, into: sharpened, commandBuffer: pass)
                else { return false }
                pass.commit()
                made.texture = sharpened
                report.preparation = preparation
                report.pass = pass
            }
            picture = made
            upscaled = (key, picture)
        }
        if let arrival {
            // The arrival poses the upscaled picture: it is presented into the arrival's texture first
            let sourceSize = picture.sharpenAtPresentation
                ? (width: geometry.presentationWidth, height: geometry.presentationHeight)
                : (width: picture.texture.width, height: picture.texture.height)
            guard let source = arrivalSource(width: sourceSize.width, height: sourceSize.height, wide: wide),
                  upscaler.present(picture, sharpness: sharpness, into: source, viewport: nil,
                                   crop: MetalPipelineCache.wholePicture, commandBuffer: commandBuffer),
                  drawArrival(source, pose: arrival, into: target, geometry: geometry, commandBuffer: commandBuffer)
            else { return false }
        } else {
            arrivalTexture = nil
            guard upscaler.present(picture, sharpness: sharpness, into: target, viewport: geometry.viewport,
                                   crop: geometry.crop, commandBuffer: commandBuffer)
            else { return false }
        }
        lastReport = report
        return true
    }

    /// The upscaler is off: its textures, scalers and history go.
    private func releaseUpscaler() {
        guard upscaled != nil || sourceTexture != nil || upscaledMode != nil else { return }
        upscaled = nil
        upscaledMode = nil
        sourceTexture = nil
        sharpenedTexture = nil
        upscaler.releaseResources()
    }

    /// The Y'CbCr to RGB conversion of `pixelBuffer` into `viewport` of `texture` (cleared to black first).
    private func convert(
        _ pixelBuffer: CVPixelBuffer, conversion: ColorConversion, into texture: any MTLTexture, viewport: MTLViewport,
        crop: SIMD4<Float>, commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        let wide = conversion.bitDepth > 8
        guard let luma = planeTexture(pixelBuffer, plane: 0, format: wide ? .r16Unorm : .r8Unorm),
              let chroma = planeTexture(pixelBuffer, plane: 1, format: wide ? .rg16Unorm : .rg8Unorm),
              let lumaTexture = CVMetalTextureGetTexture(luma), let chromaTexture = CVMetalTextureGetTexture(chroma)
        else { return false }
        guard cache.draw(
            "videoFragment", into: texture, textures: [lumaTexture, chromaTexture], uniforms: conversion.uniforms,
            viewport: viewport, crop: crop, clear: true, commandBuffer: commandBuffer)
        else { return false }
        // The textures must outlive the GPU's reading of them
        nonisolated(unsafe) let held = (luma, chroma, pixelBuffer)
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(held) {} }
        return true
    }

    /// The arrival pass: mip levels of `source`, then `source` posed into the picture's place on `target`.
    private func drawArrival(
        _ source: any MTLTexture, pose: ArrivalPose, into target: any MTLTexture, geometry: PictureGeometry,
        commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
        blit.generateMipmaps(for: source)
        blit.endEncoding()
        return cache.draw(
            "arrivalFragment", into: target, textures: [source],
            uniforms: ArrivalUniforms(pose: pose, width: source.width, height: source.height),
            viewport: geometry.viewport, crop: geometry.crop, clear: true, commandBuffer: commandBuffer)
    }

    /// The arrival's RGB texture with a full mip chain, made again when the picture's size or depth changes.
    private func arrivalSource(width: Int, height: Int, wide: Bool) -> (any MTLTexture)? {
        let format: MTLPixelFormat = wide ? .rgba16Float : .rgba8Unorm
        if let source = arrivalTexture, source.width == width, source.height == height, source.pixelFormat == format {
            return source
        }
        let levels = Int(log2(Double(max(width, height)))) + 1
        arrivalTexture = cache.texture(format, width: width, height: height, levels: levels, usage: [.renderTarget, .shaderRead])
        return arrivalTexture
    }

    private func planeTexture(_ pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, format, CVPixelBufferGetWidthOfPlane(pixelBuffer, plane),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, plane), plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }
}
