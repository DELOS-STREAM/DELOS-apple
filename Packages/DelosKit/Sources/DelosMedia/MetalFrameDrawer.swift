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
    private var pipelines: [MTLPixelFormat: any MTLRenderPipelineState] = [:]
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

    /// Encodes the drawing of `pixelBuffer` into `target` in `commandBuffer`. False when the buffer's format is not
    /// drawable or a texture could not be made.
    func draw(
        _ pixelBuffer: CVPixelBuffer, conversion: ColorConversion, into target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        let wide = conversion.bitDepth > 8
        guard let luma = texture(pixelBuffer, plane: 0, format: wide ? .r16Unorm : .r8Unorm),
              let chroma = texture(pixelBuffer, plane: 1, format: wide ? .rg16Unorm : .rg8Unorm),
              let pipeline = pipeline(for: target.pixelFormat),
              let lumaTexture = CVMetalTextureGetTexture(luma), let chromaTexture = CVMetalTextureGetTexture(chroma)
        else { return false }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setViewport(Self.fittedViewport(
            video: (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer)),
            target: (target.width, target.height)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        var uniforms = conversion.uniforms
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        // The textures must outlive the GPU's reading of them
        nonisolated(unsafe) let held = (luma, chroma, pixelBuffer)
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(held) {} }
        drawn += 1
        if drawn % 60 == 0 { CVMetalTextureCacheFlush(cache, 0) }
        return true
    }

    private func texture(_ pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, format, CVPixelBufferGetWidthOfPlane(pixelBuffer, plane),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, plane), plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }

    private func pipeline(for format: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
        if let pipeline = pipelines[format] { return pipeline }
        let description = MTLRenderPipelineDescriptor()
        description.vertexFunction = library.makeFunction(name: "videoVertex")
        description.fragmentFunction = library.makeFunction(name: "videoFragment")
        description.colorAttachments[0].pixelFormat = format
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: description) else { return nil }
        pipelines[format] = pipeline
        return pipeline
    }
}
