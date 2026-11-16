import Foundation

/// AV1 as the host sends it: low-overhead OBUs. Only the sequence header is read, for the decoder's configuration
/// record (`av1C`), which is what Moonlight used FFmpeg for.
public enum AV1 {
    /// One OBU: its type and the whole OBU as it appears in the stream (header, size field and payload).
    public struct OBU: Equatable, Sendable {
        public let type: UInt8
        public let bytes: Data
        public let payload: Data
    }

    public static let sequenceHeaderType: UInt8 = 1

    public enum Failure: Error, Equatable {
        case truncated
        case noSequenceHeader
        case unsupported(String)
    }

    /// The OBUs of a temporal unit. Every OBU must carry its size field, as the low-overhead format requires.
    public static func obus(_ data: Data) throws -> [OBU] {
        let bytes = [UInt8](data)
        var result: [OBU] = []
        var i = 0
        while i < bytes.count {
            let start = i
            let header = bytes[i]
            let type = (header >> 3) & 0x0F
            let hasExtension = header & 0x04 != 0
            let hasSize = header & 0x02 != 0
            i += hasExtension ? 2 : 1
            guard hasSize else { throw Failure.unsupported("OBU without a size field") }
            var size = 0
            var shift = 0
            while true {
                guard i < bytes.count, shift < 56 else { throw Failure.truncated }
                let byte = bytes[i]
                i += 1
                size |= Int(byte & 0x7F) << shift
                shift += 7
                if byte & 0x80 == 0 { break }
            }
            guard i + size <= bytes.count else { throw Failure.truncated }
            result.append(OBU(type: type, bytes: Data(bytes[start..<(i + size)]), payload: Data(bytes[i..<(i + size)])))
            i += size
        }
        return result
    }

    /// The fields of a sequence header that the configuration record and the format description need.
    public struct SequenceHeader: Equatable, Sendable {
        public var profile: UInt8 = 0
        public var level: UInt8 = 0
        public var tier: UInt8 = 0
        public var bitDepth: Int = 8
        public var monochrome = false
        public var subsamplingX = true
        public var subsamplingY = true
        public var chromaSamplePosition: UInt8 = 0
        public var maxWidth = 0
        public var maxHeight = 0
        /// Color description (ISO/IEC 23091-4 code points), nil when the stream does not carry one.
        public var colorPrimaries: UInt8?
        public var transferCharacteristics: UInt8?
        public var matrixCoefficients: UInt8?
        public var fullRange = false
    }

    /// Parses a sequence header OBU's payload (AV1 specification, section 5.5).
    public static func parseSequenceHeader(_ payload: Data) throws -> SequenceHeader {
        var r = BitReader([UInt8](payload))
        var h = SequenceHeader()
        do {
            h.profile = UInt8(try r.bits(3))
            _ = try r.flag() // still_picture
            let reduced = try r.flag()
            if reduced {
                h.level = UInt8(try r.bits(5))
            } else {
                var decoderModelInfoPresent = false
                var bufferDelayLength = 0
                if try r.flag() { // timing_info_present_flag
                    _ = try r.bits(32) // num_units_in_display_tick
                    _ = try r.bits(32) // time_scale
                    if try r.flag() { _ = try r.uvlc() } // equal_picture_interval
                    decoderModelInfoPresent = try r.flag()
                    if decoderModelInfoPresent {
                        bufferDelayLength = Int(try r.bits(5)) + 1
                        _ = try r.bits(32) // num_units_in_decoding_tick
                        _ = try r.bits(5) // buffer_removal_time_length_minus_1
                        _ = try r.bits(5) // frame_presentation_time_length_minus_1
                    }
                }
                let initialDisplayDelayPresent = try r.flag()
                let operatingPoints = Int(try r.bits(5)) + 1
                for point in 0..<operatingPoints {
                    _ = try r.bits(12) // operating_point_idc
                    let level = UInt8(try r.bits(5))
                    let tier: UInt8 = level > 7 ? UInt8(try r.bit()) : 0
                    if point == 0 {
                        h.level = level
                        h.tier = tier
                    }
                    if decoderModelInfoPresent, try r.flag() {
                        _ = try r.bits(bufferDelayLength) // decoder_buffer_delay
                        _ = try r.bits(bufferDelayLength) // encoder_buffer_delay
                        _ = try r.flag() // low_delay_mode_flag
                    }
                    if initialDisplayDelayPresent, try r.flag() { _ = try r.bits(4) }
                }
            }
            let widthBits = Int(try r.bits(4)) + 1
            let heightBits = Int(try r.bits(4)) + 1
            h.maxWidth = Int(try r.bits(widthBits)) + 1
            h.maxHeight = Int(try r.bits(heightBits)) + 1
            if !reduced, try r.flag() { // frame_id_numbers_present_flag
                _ = try r.bits(4)
                _ = try r.bits(3)
            }
            _ = try r.bits(3) // use_128x128_superblock, enable_filter_intra, enable_intra_edge_filter
            var orderHint = false
            if !reduced {
                _ = try r.bits(4) // interintra, masked compound, warped motion, dual filter
                orderHint = try r.flag()
                if orderHint { _ = try r.bits(2) } // jnt_comp, ref_frame_mvs
                let forceScreenContentTools: UInt32 = try r.flag() ? 2 : r.bit()
                if forceScreenContentTools > 0, try !r.flag() { _ = try r.bit() } // seq_choose_integer_mv, seq_force_integer_mv
                if orderHint { _ = try r.bits(3) }
            }
            _ = try r.bits(3) // enable_superres, enable_cdef, enable_restoration
            try parseColorConfig(&r, into: &h)
        } catch is BitReader.Failure {
            throw Failure.truncated
        }
        return h
    }

    private static func parseColorConfig(_ r: inout BitReader, into h: inout SequenceHeader) throws {
        let highBitDepth = try r.flag()
        if h.profile == 2, highBitDepth {
            h.bitDepth = try r.flag() ? 12 : 10
        } else {
            h.bitDepth = highBitDepth ? 10 : 8
        }
        h.monochrome = h.profile == 1 ? false : try r.flag()
        if try r.flag() { // color_description_present_flag
            h.colorPrimaries = UInt8(try r.bits(8))
            h.transferCharacteristics = UInt8(try r.bits(8))
            h.matrixCoefficients = UInt8(try r.bits(8))
        }
        if h.monochrome {
            h.fullRange = try r.flag()
            h.subsamplingX = true
            h.subsamplingY = true
            return
        }
        if h.colorPrimaries == 1, h.transferCharacteristics == 13, h.matrixCoefficients == 0 {
            // sRGB
            h.fullRange = true
            h.subsamplingX = false
            h.subsamplingY = false
        } else {
            h.fullRange = try r.flag()
            switch h.profile {
            case 0: (h.subsamplingX, h.subsamplingY) = (true, true)
            case 1: (h.subsamplingX, h.subsamplingY) = (false, false)
            default:
                if h.bitDepth == 12 {
                    h.subsamplingX = try r.flag()
                    h.subsamplingY = h.subsamplingX ? try r.flag() : false
                } else {
                    (h.subsamplingX, h.subsamplingY) = (true, false)
                }
            }
            if h.subsamplingX, h.subsamplingY { h.chromaSamplePosition = UInt8(try r.bits(2)) }
        }
    }

    /// The `av1C` configuration record (AV1 Codec ISO Media File Format Binding, section 2.3) for a sequence header
    /// OBU, which it carries as its configOBUs.
    public static func configurationRecord(_ header: SequenceHeader, sequenceHeaderOBU: Data) -> Data {
        var record = Data([
            0x81, // marker 1, version 1
            header.profile << 5 | header.level,
            header.tier << 7
                | (header.bitDepth > 8 ? 1 : 0) << 6
                | (header.bitDepth == 12 ? 1 : 0) << 5
                | (header.monochrome ? 1 : 0) << 4
                | (header.subsamplingX ? 1 : 0) << 3
                | (header.subsamplingY ? 1 : 0) << 2
                | header.chromaSamplePosition,
            0x00, // no initial presentation delay
        ])
        record.append(sequenceHeaderOBU)
        return record
    }
}
