import CoreVideo
import Testing
@testable import DelosMedia

@Suite struct ColorConversionTests {
    private func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, tolerance: Double = 0.004) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.z - b.z) <= tolerance
    }

    @Test func limitedRangeBlackAndWhiteAre0And1() {
        let c = ColorConversion(matrix: .bt709, range: .limited)
        #expect(close(c.rgb(y: 16, cb: 128, cr: 128), .zero))
        #expect(close(c.rgb(y: 235, cb: 128, cr: 128), SIMD3(repeating: 1)))
        let gray = c.rgb(y: 126, cb: 128, cr: 128)
        #expect(close(gray, SIMD3(repeating: 110.0 / 219), tolerance: 0.003))
    }

    @Test func fullRangeUsesTheWholeScale() {
        let c = ColorConversion(matrix: .bt709, range: .full)
        #expect(close(c.rgb(y: 0, cb: 128, cr: 128), .zero))
        #expect(close(c.rgb(y: 255, cb: 128, cr: 128), SIMD3(repeating: 1)))
        // The same code values that are black and white in limited range are not here
        #expect(c.rgb(y: 235, cb: 128, cr: 128).x < 0.93)
    }

    @Test func primariesOfBT709() {
        let c = ColorConversion(matrix: .bt709, range: .limited)
        // Y'CbCr of pure red, green and blue in BT.709 limited range (8 bits), from the standard's formulas
        #expect(close(c.rgb(y: 63, cb: 102, cr: 240), SIMD3(1, 0, 0), tolerance: 0.01))
        #expect(close(c.rgb(y: 173, cb: 42, cr: 26), SIMD3(0, 1, 0), tolerance: 0.01))
        #expect(close(c.rgb(y: 32, cb: 240, cr: 118), SIMD3(0, 0, 1), tolerance: 0.01))
    }

    @Test func theMatricesDiffer() {
        let red709 = ColorConversion(matrix: .bt709).rgb(y: 81, cb: 90, cr: 240)
        let red601 = ColorConversion(matrix: .bt601).rgb(y: 81, cb: 90, cr: 240)
        let red2020 = ColorConversion(matrix: .bt2020).rgb(y: 74, cb: 97, cr: 240)
        // BT.601 red is Y'=81, Cb=90, Cr=240; the same codes are not pure red in BT.709
        #expect(close(red601, SIMD3(1, 0, 0), tolerance: 0.01))
        #expect(!close(red709, SIMD3(1, 0, 0), tolerance: 0.03))
        #expect(close(red2020, SIMD3(1, 0, 0), tolerance: 0.01))
    }

    @Test func tenBitSamplesInTheHighBitsOfWordsScaleLikeEightBit() {
        let limited = ColorConversion(matrix: .bt2020, range: .limited, transfer: .pq, bitDepth: 10)
        #expect(close(limited.rgb(y: 64, cb: 512, cr: 512), .zero))
        #expect(close(limited.rgb(y: 940, cb: 512, cr: 512), SIMD3(repeating: 1)))
        let full = ColorConversion(matrix: .bt2020, range: .full, transfer: .hlg, bitDepth: 10)
        #expect(close(full.rgb(y: 0, cb: 512, cr: 512), .zero))
        #expect(close(full.rgb(y: 1023, cb: 512, cr: 512), SIMD3(repeating: 1)))
    }

    @Test func thePixelFormatSaysRangeAndDepth() throws {
        let cases: [(OSType, ColorConversion.Range, Int)] = [
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, .limited, 8),
            (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, .full, 8),
            (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, .limited, 10),
            (kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, .full, 10),
        ]
        for (format, range, depth) in cases {
            let c = try #require(ColorConversion(pixelFormat: format, matrix: nil, transfer: nil))
            #expect(c.range == range)
            #expect(c.bitDepth == depth)
        }
        #expect(ColorConversion(pixelFormat: kCVPixelFormatType_32BGRA, matrix: nil, transfer: nil) == nil)
    }

    @Test func theAttachmentsSayMatrixAndTransfer() throws {
        let format = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let hdr = try #require(ColorConversion(
            pixelFormat: format, matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020 as String,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String))
        #expect(hdr.matrix == .bt2020 && hdr.transfer == .pq && hdr.isHDR)
        #expect(hdr.layerColorSpaceName == CGColorSpace.itur_2100_PQ)
        let hlg = try #require(ColorConversion(
            pixelFormat: format, matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020 as String,
            transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG as String))
        #expect(hlg.transfer == .hlg && hlg.layerColorSpaceName == CGColorSpace.itur_2100_HLG)
        let sd601 = try #require(ColorConversion(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String, transfer: nil))
        #expect(sd601.matrix == .bt601 && !sd601.isHDR && sd601.layerColorSpaceName == CGColorSpace.itur_709)
        // No description: what hosts send, BT.709 SDR
        let none = try #require(ColorConversion(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, matrix: nil, transfer: nil))
        #expect(none == ColorConversion())
    }

    @Test func theUniformsMatchTheShadersLayout() {
        #expect(MemoryLayout<VideoUniforms>.stride == 80)
        #expect(MemoryLayout<VideoUniforms>.alignment == 16)
    }
}
