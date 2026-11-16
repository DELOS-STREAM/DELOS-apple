import CoreMedia
import Foundation

/// The video codecs DELOS decodes.
public enum VideoCodec: Sendable {
    case h264, hevc, av1
}

/// Builds the `CMVideoFormatDescription` VideoToolbox needs from the parameter sets the host sends with each IDR
/// frame (H.264 SPS/PPS, HEVC VPS/SPS/PPS) or from the AV1 sequence header.
public enum VideoFormat {
    public enum Failure: Error, Equatable {
        case missingParameterSets
        case coreMedia(OSStatus)
    }

    /// The format description from the parameter sets of a key frame, in the order `AnnexB.parameterSets` finds them:
    /// SPS and PPS for H.264, VPS, SPS and PPS for HEVC.
    static func description(codec: VideoCodec, parameterSets sets: [[UInt8]]) throws -> CMVideoFormatDescription {
        var format: CMVideoFormatDescription?
        let status = withParameterSets(sets) { pointers, sizes in
            switch codec {
            case .h264:
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            case .hevc:
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            case .av1:
                kCMFormatDescriptionError_InvalidParameter
            }
        }
        guard status == noErr, let format else { throw Failure.coreMedia(status) }
        return format
    }

    /// Calls `body` with C pointers to the parameter sets, which stay valid during the call.
    private static func withParameterSets<T>(
        _ sets: [[UInt8]], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> T
    ) -> T {
        let copies = sets.map { set -> UnsafeMutableBufferPointer<UInt8> in
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: set.count)
            _ = buffer.initialize(from: set)
            return buffer
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0.baseAddress!) }
        let sizes = sets.map(\.count)
        return pointers.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) }
        }
    }

    /// The format description from an AV1 temporal unit with a sequence header (or that OBU alone).
    static func av1(_ frame: Data) throws -> CMVideoFormatDescription {
        guard let obu = try AV1.obus(frame).first(where: { $0.type == AV1.sequenceHeaderType }) else {
            throw Failure.missingParameterSets
        }
        let header = try AV1.parseSequenceHeader(obu.payload)
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [
                "av1C": AV1.configurationRecord(header, sequenceHeaderOBU: obu.bytes),
            ] as CFDictionary,
            kCMFormatDescriptionExtension_FullRangeVideo: header.fullRange,
            kCMFormatDescriptionExtension_Depth: header.bitDepth > 8 ? 30 : 24,
        ]
        extensions.merge(colorExtensions(header)) { _, new in new }
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_AV1,
            width: Int32(header.maxWidth), height: Int32(header.maxHeight),
            extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw Failure.coreMedia(status) }
        return format
    }

    /// The color extensions for the code points the host uses (BT.709 for SDR, BT.2020 with PQ or HLG for HDR).
    static func colorExtensions(_ header: AV1.SequenceHeader) -> [CFString: Any] {
        var result: [CFString: Any] = [:]
        switch header.colorPrimaries {
        case 1: result[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case 9: result[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
        default: break
        }
        switch header.transferCharacteristics {
        case 1, 6: result[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case 16: result[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case 18: result[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        default: break
        }
        switch header.matrixCoefficients {
        case 1: result[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case 9: result[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        case 6: result[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        default: break
        }
        return result
    }
}
