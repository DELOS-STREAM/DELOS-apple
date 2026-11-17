import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Draws decoded pictures into Metal textures: the pixel buffer's planes become textures through a
/// `CVMetalTextureCache` (no copy: they share the IOSurface), a fragment shader converts the Y'CbCr to RGB
/// (``ColorConversion``) and the picture is fitted into the target on black.
///
/// Used from one thread at a time (the display link's).
final class MetalFrameDrawer: @unchecked Sendable {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    private let library: any MTLLibrary
    private let cache: CVMetalTextureCache
    private var pipelines: [PipelineKey: any MTLRenderPipelineState] = [:]
    /// The arrival pass's source (``LaunchArrival``), kept from frame to frame while it runs.
    private var arrivalTexture: (any MTLTexture)?
    private let sampler: any MTLSamplerState
    private var drawn = 0

    init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .module) else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            return nil
        }
        let description = MTLSamplerDescriptor()
        description.minFilter = .linear
        description.magFilter = .linear
        description.sAddressMode = .clampToEdge
        description.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: description) else { return nil }
        self.device = device
        self.queue = queue
        self.library = library
        self.cache = cache
        self.sampler = sampler
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

    /// Encodes the drawing of `pixelBuffer` into `target` in `commandBuffer`. With an `arrival` pose the picture is first
    /// converted into an RGB texture of its own size (8-bit, or half floats for 10-bit pictures, which keep HDR's encoded
    /// values), its mip levels are generated, and the arrival pass draws it posed into the fitted rectangle; where that
    /// texture or pass cannot be made the picture is drawn directly. False when the buffer's format is not drawable or a
    /// texture could not be made.
    func draw(
        _ pixelBuffer: CVPixelBuffer, conversion: ColorConversion, into target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer, arrival: ArrivalPose? = nil
    ) -> Bool {
        let wide = conversion.bitDepth > 8
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard let luma = texture(pixelBuffer, plane: 0, format: wide ? .r16Unorm : .r8Unorm),
              let chroma = texture(pixelBuffer, plane: 1, format: wide ? .rg16Unorm : .rg8Unorm),
              let lumaTexture = CVMetalTextureGetTexture(luma), let chromaTexture = CVMetalTextureGetTexture(chroma)
        else { return false }
        let fitted = Self.fittedViewport(video: (width, height), target: (target.width, target.height))
        var uniforms = conversion.uniforms

        func convert(into texture: any MTLTexture, viewport: MTLViewport, with pipeline: any MTLRenderPipelineState) -> Bool {
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: Self.clearing(texture)) else { return false }
            encoder.setViewport(viewport)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(lumaTexture, index: 0)
            encoder.setFragmentTexture(chromaTexture, index: 1)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            return true
        }

        if let arrival, let source = arrivalSource(width: width, height: height, wide: wide),
           let conversionPipeline = pipeline("videoFragment", for: source.pixelFormat),
           let arrivalPipeline = pipeline("arrivalFragment", for: target.pixelFormat) {
            let whole = MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1)
            guard convert(into: source, viewport: whole, with: conversionPipeline),
                  let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
            blit.generateMipmaps(for: source)
            blit.endEncoding()
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: Self.clearing(target)) else { return false }
            encoder.setViewport(fitted)
            encoder.setRenderPipelineState(arrivalPipeline)
            encoder.setFragmentTexture(source, index: 0)
            var posed = ArrivalUniforms(pose: arrival, width: width, height: height)
            encoder.setFragmentBytes(&posed, length: MemoryLayout<ArrivalUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        } else {
            guard let pipeline = pipeline("videoFragment", for: target.pixelFormat),
                  convert(into: target, viewport: fitted, with: pipeline) else { return false }
            // The arrival is over (or has not begun): its texture is not kept for the rest of the stream
            arrivalTexture = nil
        }
        // The textures must outlive the GPU's reading of them
        nonisolated(unsafe) let held = (luma, chroma, pixelBuffer)
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(held) {} }
        drawn += 1
        if drawn % 60 == 0 { CVMetalTextureCacheFlush(cache, 0) }
        return true
    }

    /// A pass that clears `texture` to black and keeps what is drawn.
    private static func clearing(_ texture: any MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    /// The arrival's RGB texture with a full mip chain, made again when the picture's size or depth changes.
    private func arrivalSource(width: Int, height: Int, wide: Bool) -> (any MTLTexture)? {
        let format: MTLPixelFormat = wide ? .rgba16Float : .rgba8Unorm
        if let source = arrivalTexture, source.width == width, source.height == height, source.pixelFormat == format {
            return source
        }
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: true)
        description.usage = [.renderTarget, .shaderRead]
        description.storageMode = .private
        arrivalTexture = device.makeTexture(descriptor: description)
        return arrivalTexture
    }

    private func texture(_ pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, format, CVPixelBufferGetWidthOfPlane(pixelBuffer, plane),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, plane), plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }

    private func pipeline(_ fragment: String, for format: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
        let key = PipelineKey(fragment: fragment, format: format)
        if let pipeline = pipelines[key] { return pipeline }
        let description = MTLRenderPipelineDescriptor()
        description.vertexFunction = library.makeFunction(name: "videoVertex")
        description.fragmentFunction = library.makeFunction(name: fragment)
        description.colorAttachments[0].pixelFormat = format
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: description) else { return nil }
        pipelines[key] = pipeline
        return pipeline
    }

    private struct PipelineKey: Hashable {
        var fragment: String
        var format: MTLPixelFormat
    }
}
