import CoreVideo
import Foundation

/// How a decoded picture's Y'CbCr values become the RGB values the display layer shows: the matrix of the stream's
/// colour space, the range its values use and the bit depth. It is read from the pixel buffer VideoToolbox decoded
/// (the format says the range and depth, the attachments the matrix and the transfer function), so a host that
/// sends full-range or BT.601 video is shown correctly.
///
/// The shader converts the matrix and the range only. The transfer function stays as encoded: BT.709 and sRGB
/// look as they were encoded, and a PQ or HLG stream is passed through to a layer tagged with the matching colour
/// space (``layerColorSpaceName``), which is where the HDR path (issue #11) continues; the shader takes the
/// transfer as a field already, so it can tone map or linearise there.
public struct ColorConversion: Sendable, Equatable {
    public enum Matrix: Sendable, Equatable {
        case bt601
        case bt709
        case bt2020

        /// The luma weights Kr and Kb of the matrix.
        var weights: (kr: Double, kb: Double) {
            switch self {
            case .bt601: (0.299, 0.114)
            case .bt709: (0.2126, 0.0722)
            case .bt2020: (0.2627, 0.0593)
            }
        }
    }

    public enum Range: Sendable, Equatable {
        /// Luma 16…235, chroma 16…240 (at 8 bits): what H.264, HEVC and AV1 hosts send by default.
        case limited
        case full
    }

    public enum Transfer: Sendable, Equatable {
        /// BT.709, BT.601 or sRGB: SDR.
        case sdr
        /// SMPTE ST 2084 (HDR10).
        case pq
        /// ARIB STD-B67 (HLG).
        case hlg
    }

    public var matrix: Matrix
    public var range: Range
    public var transfer: Transfer
    /// 8 or 10; the 10-bit formats keep their samples in the high bits of 16-bit words.
    public var bitDepth: Int

    public init(matrix: Matrix = .bt709, range: Range = .limited, transfer: Transfer = .sdr, bitDepth: Int = 8) {
        self.matrix = matrix
        self.range = range
        self.transfer = transfer
        self.bitDepth = bitDepth
    }

    /// The two-plane 4:2:0 formats the renderer draws; anything else is converted by VideoToolbox.
    public static let pixelFormats: [OSType] = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
    ]

    /// The conversion of a decoded picture; nil for a pixel format the renderer does not draw.
    public init?(pixelBuffer: CVPixelBuffer) {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard Self.pixelFormats.contains(format) else { return nil }
        let matrixName = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let transferName = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String
        self.init(pixelFormat: format, matrix: matrixName, transfer: transferName)
    }

    /// From a pixel format and the names of the `kCVImageBufferYCbCrMatrix` and `kCVImageBufferTransferFunction`
    /// attachments; a missing name is BT.709 and SDR (what hosts send without a description of the colours).
    public init?(pixelFormat: OSType, matrix: String?, transfer: String?) {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: (range, bitDepth) = (.limited, 8)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: (range, bitDepth) = (.full, 8)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: (range, bitDepth) = (.limited, 10)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: (range, bitDepth) = (.full, 10)
        default: return nil
        }
        func named(_ name: String?, _ constant: CFString) -> Bool { name == constant as String }
        if named(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4) {
            self.matrix = .bt601
        } else if named(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
            self.matrix = .bt2020
        } else {
            self.matrix = .bt709
        }
        if named(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) {
            self.transfer = .pq
        } else if named(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG) {
            self.transfer = .hlg
        } else {
            self.transfer = .sdr
        }
    }

    /// The name of the colour space to tag the Metal layer with, so the system matches the picture to the display.
    public var layerColorSpaceName: CFString {
        switch (transfer, matrix) {
        case (.pq, _): CGColorSpace.itur_2100_PQ
        case (.hlg, _): CGColorSpace.itur_2100_HLG
        case (.sdr, .bt2020): CGColorSpace.itur_2020
        case (.sdr, _): CGColorSpace.itur_709
        }
    }

    /// Whether the picture needs the layer's extended-range (HDR) pixel format.
    public var isHDR: Bool { transfer != .sdr }

    /// The numbers the fragment shader uses (`VideoUniforms` in VideoShaders.metal).
    var uniforms: VideoUniforms {
        let (kr, kb) = matrix.weights
        let kg = 1 - kr - kb
        // rgb = M · (Y', Cb', Cr') with Y' in 0…1 and Cb', Cr' in -0.5…0.5; the columns of M
        let column1 = SIMD4<Float>(0, Float(-2 * kb * (1 - kb) / kg), Float(2 * (1 - kb)), 0)
        let column2 = SIMD4<Float>(Float(2 * (1 - kr)), Float(-2 * kr * (1 - kr) / kg), 0, 0)
        // The sampled value v is the code over `codeMax`: 255 at 8 bits, 1023.98 at 10 bits (the code shifted into
        // 16 bits, over 65535)
        let codeMax = bitDepth == 8 ? 255.0 : 65535.0 / 64
        let shift = Double(1 << (bitDepth - 8))
        let lumaOffset: Double, lumaRange: Double, chromaRange: Double
        switch range {
        case .limited:
            lumaOffset = 16 * shift
            lumaRange = 219 * shift
            chromaRange = 224 * shift
        case .full:
            lumaOffset = 0
            lumaRange = Double((1 << bitDepth) - 1)
            chromaRange = lumaRange
        }
        let chromaOffset = 128 * shift
        return VideoUniforms(
            column0: SIMD4<Float>(1, 1, 1, 0), column1: column1, column2: column2,
            range: SIMD4<Float>(
                Float(lumaOffset / codeMax), Float(codeMax / lumaRange),
                Float(chromaOffset / codeMax), Float(codeMax / chromaRange)),
            transfer: SIMD4<Float>(transfer == .sdr ? 0 : (transfer == .pq ? 1 : 2), 0, 0, 0))
    }

    /// The conversion on the CPU, the reference the shader is tested against: the RGB of the code values Y, Cb and Cr
    /// (at the conversion's bit depth), each 0…1 before the transfer function.
    public func rgb(y: Int, cb: Int, cr: Int) -> SIMD3<Double> {
        let u = uniforms
        let codeMax = bitDepth == 8 ? 255.0 : 65535.0 / 64
        func sample(_ code: Int) -> Double { Double(code) / codeMax }
        let luma = (sample(y) - Double(u.range.x)) * Double(u.range.y)
        let blue = (sample(cb) - Double(u.range.z)) * Double(u.range.w)
        let red = (sample(cr) - Double(u.range.z)) * Double(u.range.w)
        let c1 = u.column1, c2 = u.column2
        let result = SIMD3<Double>(
            luma + Double(c2.x) * red,
            luma + Double(c1.y) * blue + Double(c2.y) * red,
            luma + Double(c1.z) * blue)
        return result.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
    }
}

/// The HDR10 metadata attached to a decoded picture (`kCVImageBufferMasteringDisplayColorVolumeKey`,
/// `kCVImageBufferContentLightLevelInfoKey`): the 24-byte mastering display colour volume and the 4-byte content light
/// level, big-endian. The Metal layer's EDR metadata is made from them.
public struct HDRPictureInfo: Sendable, Equatable {
    public var masteringDisplayColorVolume: Data?
    public var contentLightLevelInfo: Data?

    public init(masteringDisplayColorVolume: Data?, contentLightLevelInfo: Data?) {
        self.masteringDisplayColorVolume = masteringDisplayColorVolume
        self.contentLightLevelInfo = contentLightLevelInfo
    }

    /// Nil when the picture has neither.
    public init?(pixelBuffer: CVPixelBuffer) {
        let mastering = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data
        let level = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferContentLightLevelInfoKey, nil) as? Data
        guard mastering != nil || level != nil else { return nil }
        self.init(masteringDisplayColorVolume: mastering, contentLightLevelInfo: level)
    }
}

/// The constants of `videoFragment`; the layout matches the Metal struct of the same name (four 16-byte vectors).
struct VideoUniforms: Equatable {
    var column0: SIMD4<Float>
    var column1: SIMD4<Float>
    var column2: SIMD4<Float>
    /// Luma offset, luma scale, chroma offset, chroma scale.
    var range: SIMD4<Float>
    /// x: 0 SDR, 1 PQ, 2 HLG.
    var transfer: SIMD4<Float>
}
