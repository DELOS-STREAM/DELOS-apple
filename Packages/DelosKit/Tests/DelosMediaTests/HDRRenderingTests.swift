import CoreGraphics
import CoreVideo
import Metal
import QuartzCore
import Testing
@testable import DelosMedia

struct HDRRenderingTests {
    @MainActor @Test func hdrLayerUsesFloatingPointAndMatchingTransferAndReturnsToSDR() throws {
        let layer = CAMetalLayer()
        for transfer in [ColorConversion.Transfer.pq, .hlg] {
            let conversion = ColorConversion(matrix: .bt2020, range: .limited, transfer: transfer, bitDepth: 10)
            LayerRetagger.configure(layer, conversion: conversion)
            #expect(layer.pixelFormat == .rgba16Float)
            #expect(layer.wantsExtendedDynamicRangeContent)
            let space = try #require(layer.colorspace)
            #expect(space.name == conversion.layerColorSpaceName)
        }
        LayerRetagger.configure(layer, conversion: ColorConversion())
        #expect(layer.pixelFormat == .bgra8Unorm)
        #expect(!layer.wantsExtendedDynamicRangeContent)
        #expect(layer.colorspace?.name == CGColorSpace.itur_709)
    }

    /// PQ/HLG code values are passed through, not EOTF-decoded a second time beneath a PQ/HLG layer tag.
    @Test func tenBitBT2020PQAndHLGShaderOutputMatchesCPUReferenceInFloatTarget() throws {
        let drawer = try #require(MetalFrameDrawer())
        let queue = try #require(drawer.device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 2, height: 2, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try #require(drawer.device.makeTexture(descriptor: descriptor))
        for transfer in [ColorConversion.Transfer.pq, .hlg] {
            let conversion = ColorConversion(matrix: .bt2020, range: .limited, transfer: transfer, bitDepth: 10)
            for (y, cb, cr) in [(64, 512, 512), (940, 512, 512), (502, 300, 700)] {
                let buffer = try PixelBuffers.make(width: 2, height: 2, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                                   luma: { _, _ in y }, chroma: { _, _ in (cb, cr) })
                let command = try #require(queue.makeCommandBuffer())
                #expect(drawer.draw(buffer, conversion: conversion, into: target, commandBuffer: command))
                command.commit()
                command.waitUntilCompleted()
                #expect(command.status == .completed)
                var pixels = [Float16](repeating: 0, count: 16)
                pixels.withUnsafeMutableBytes {
                    target.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
                }
                let expected = conversion.rgb(y: y, cb: cb, cr: cr)
                #expect(abs(Double(pixels[0]) - expected.x) < 0.002)
                #expect(abs(Double(pixels[1]) - expected.y) < 0.002)
                #expect(abs(Double(pixels[2]) - expected.z) < 0.002)
                #expect(pixels[3] == 1)
            }
        }
    }
}
