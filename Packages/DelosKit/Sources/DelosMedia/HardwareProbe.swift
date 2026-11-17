import CoreMedia
import Foundation
import VideoToolbox

/// Whether the hardware decodes the 10-bit profiles. `VTIsHardwareDecodeSupported` answers per codec and says nothing
/// of a profile, so each probe builds a tiny Main10 stream description and asks VideoToolbox for a session that must
/// run in hardware (`RequireHardwareAcceleratedVideoDecoder`); if it cannot be created, the profile is not offered.
public enum HardwareProbe {
    /// HEVC Main10 in hardware.
    public static let hevcMain10: Bool = {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) else { return false }
        return Self.hardwareSession(for: Streams.hevcMain10Description)
    }()

    /// AV1 Main (10-bit) in hardware.
    public static let av1Main10: Bool = {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) else { return false }
        return Self.hardwareSession(for: Streams.av1Main10Description)
    }()

    /// Whether VideoToolbox creates a hardware-only decompression session for `format`. The session is not kept.
    static func hardwareSession(for format: CMVideoFormatDescription?) -> Bool {
        guard let format else { return false }
        let specification: [CFString: Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
        guard status == noErr, let session else { return false }
        VTDecompressionSessionInvalidate(session)
        return true
    }

    /// Parameter sets of a minimal 256 x 256 stream per 10-bit profile, enough for VideoToolbox to pick a decoder.
    enum Streams {
        static var hevcMain10Description: CMVideoFormatDescription? {
            try? VideoFormat.description(codec: .hevc, parameterSets: hevcMain10ParameterSets())
        }

        static var av1Main10Description: CMVideoFormatDescription? {
            try? VideoFormat.av1(Data(av1Main10SequenceHeaderOBU()))
        }

        /// VPS, SPS and PPS of a Main10 stream (H.265 sections 7.3.2.1 to 7.3.2.3), each with its NAL unit header and
        /// emulation prevention, without a start code.
        static func hevcMain10ParameterSets(width: Int = 256, height: Int = 256) -> [[UInt8]] {
            func profileTierLevel(_ w: inout BitWriter) {
                w.bits(0, 2) // general_profile_space
                w.bits(0, 1) // general_tier_flag
                w.bits(2, 5) // general_profile_idc: Main 10
                w.bits(0x6000_0000, 32) // compatibility flags 1 and 2
                w.bits(0b1001, 4) // progressive, not interlaced, not non-packed, frame only
                w.bits(0, 32)
                w.bits(0, 12) // 43 reserved bits and general_inbld_flag
                w.bits(120, 8) // general_level_idc: 4.0
            }
            var vps = BitWriter()
            vps.bits(0, 4) // vps_video_parameter_set_id
            vps.bits(0b11, 2) // base layer internal and available
            vps.bits(0, 6) // vps_max_layers_minus1
            vps.bits(0, 3) // vps_max_sub_layers_minus1
            vps.bits(1, 1) // vps_temporal_id_nesting_flag
            vps.bits(0xFFFF, 16)
            profileTierLevel(&vps)
            vps.bits(1, 1) // vps_sub_layer_ordering_info_present_flag
            vps.ue(1); vps.ue(0); vps.ue(0) // max_dec_pic_buffering_minus1, num_reorder, max_latency_increase_plus1
            vps.bits(0, 6) // vps_max_layer_id
            vps.ue(0) // vps_num_layer_sets_minus1
            vps.bits(0, 2) // vps_timing_info_present_flag, vps_extension_flag
            vps.trailing()

            var sps = BitWriter()
            sps.bits(0, 4) // sps_video_parameter_set_id
            sps.bits(0, 3) // sps_max_sub_layers_minus1
            sps.bits(1, 1) // sps_temporal_id_nesting_flag
            profileTierLevel(&sps)
            sps.ue(0) // sps_seq_parameter_set_id
            sps.ue(1) // chroma_format_idc: 4:2:0
            sps.ue(UInt32(width)); sps.ue(UInt32(height))
            sps.bits(0, 1) // conformance_window_flag
            sps.ue(2); sps.ue(2) // bit depth luma and chroma minus 8: 10 bits
            sps.ue(4) // log2_max_pic_order_cnt_lsb_minus4
            sps.bits(1, 1) // sps_sub_layer_ordering_info_present_flag
            sps.ue(1); sps.ue(0); sps.ue(0)
            sps.ue(0); sps.ue(3) // 8 x 8 minimum and 64 x 64 coding blocks
            sps.ue(0); sps.ue(3) // 4 x 4 minimum and 32 x 32 transform blocks
            sps.ue(0); sps.ue(0) // max transform hierarchy depth inter, intra
            sps.bits(0, 4) // scaling_list_enabled, amp_enabled, sample_adaptive_offset_enabled, pcm_enabled
            sps.ue(0) // num_short_term_ref_pic_sets
            sps.bits(0, 4) // long_term_ref_pics_present, temporal_mvp, strong_intra_smoothing, vui_parameters_present
            sps.bits(0, 1) // sps_extension_present_flag
            sps.trailing()

            var pps = BitWriter()
            pps.ue(0); pps.ue(0) // pps_pic_parameter_set_id, pps_seq_parameter_set_id
            pps.bits(0, 2) // dependent_slice_segments_enabled_flag, output_flag_present_flag
            pps.bits(0, 3) // num_extra_slice_header_bits
            pps.bits(0, 2) // sign_data_hiding_enabled_flag, cabac_init_present_flag
            pps.ue(0); pps.ue(0) // num_ref_idx_l0/l1_default_active_minus1
            pps.ue(0) // init_qp_minus26 (se(v) of 0)
            pps.bits(0, 3) // constrained_intra_pred, transform_skip_enabled, cu_qp_delta_enabled
            pps.ue(0); pps.ue(0) // pps_cb_qp_offset, pps_cr_qp_offset
            pps.bits(0, 4) // slice_chroma_qp_offsets_present, weighted_pred, weighted_bipred, transquant_bypass
            pps.bits(0, 3) // tiles_enabled, entropy_coding_sync_enabled, loop_filter_across_slices_enabled
            pps.bits(0, 3) // deblocking_filter_control_present, pps_scaling_list_data_present, lists_modification_present
            pps.ue(0) // log2_parallel_merge_level_minus2
            pps.bits(0, 2) // slice_segment_header_extension_present_flag, pps_extension_present_flag
            pps.trailing()

            return [
                [0x40, 0x01] + vps.rbsp(), // VPS_NUT
                [0x42, 0x01] + sps.rbsp(), // SPS_NUT
                [0x44, 0x01] + pps.rbsp(), // PPS_NUT
            ]
        }

        /// A sequence header OBU (AV1 section 5.5) for 10-bit 4:2:0 BT.2020 PQ video, with its header and size field.
        static func av1Main10SequenceHeaderOBU(width: Int = 256, height: Int = 256) -> [UInt8] {
            var w = BitWriter()
            w.bits(0, 3) // seq_profile: Main
            w.bits(0, 2) // still_picture, reduced_still_picture_header
            w.bits(0, 1) // timing_info_present_flag
            w.bits(0, 1) // initial_display_delay_present_flag
            w.bits(0, 5) // operating_points_cnt_minus_1
            w.bits(0, 12) // operating_point_idc
            w.bits(8, 5) // seq_level_idx: 4.0
            w.bits(0, 1) // seq_tier (level above 7)
            w.bits(8, 4); w.bits(8, 4) // frame_width_bits_minus_1, frame_height_bits_minus_1: 9 bits
            w.bits(UInt32(width - 1), 9); w.bits(UInt32(height - 1), 9)
            w.bits(0, 1) // frame_id_numbers_present_flag
            w.bits(0, 3) // use_128x128_superblock, enable_filter_intra, enable_intra_edge_filter
            w.bits(0, 4) // enable_interintra_compound, masked_compound, warped_motion, dual_filter
            w.bits(0, 1) // enable_order_hint
            w.bits(1, 1) // seq_choose_screen_content_tools
            w.bits(1, 1) // seq_choose_integer_mv
            w.bits(0, 3) // enable_superres, enable_cdef, enable_restoration
            w.bits(1, 1) // high_bitdepth
            w.bits(0, 1) // mono_chrome
            w.bits(1, 1) // color_description_present_flag
            w.bits(9, 8); w.bits(16, 8); w.bits(9, 8) // BT.2020, PQ, BT.2020 non-constant
            w.bits(0, 1) // color_range: limited
            w.bits(0, 2) // chroma_sample_position
            w.bits(0, 1) // separate_uv_delta_q
            w.bits(0, 1) // film_grain_params_present
            w.trailing()
            let payload = w.bytes
            // OBU header: type 1 (sequence header), has_size_field; the size is below 128 bytes
            return [0x0A, UInt8(payload.count)] + payload
        }
    }
}

/// Writes bits, most significant first (the order of H.26x and AV1 syntax elements).
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var used = 0

    mutating func bits(_ value: UInt32, _ count: Int) {
        for shift in stride(from: count - 1, through: 0, by: -1) {
            if used == 0 { bytes.append(0) }
            bytes[bytes.count - 1] |= UInt8((value >> UInt32(shift)) & 1) << UInt8(7 - used)
            used = (used + 1) % 8
        }
    }

    /// An unsigned Exp-Golomb code, `ue(v)`.
    mutating func ue(_ value: UInt32) {
        let code = UInt64(value) + 1
        let length = 64 - code.leadingZeroBitCount
        for _ in 0..<(length - 1) { bits(0, 1) }
        for shift in stride(from: length - 1, through: 0, by: -1) { bits(UInt32((code >> UInt64(shift)) & 1), 1) }
    }

    /// `rbsp_trailing_bits()`: a one, then zeros to the byte boundary.
    mutating func trailing() {
        bits(1, 1)
        while used != 0 { bits(0, 1) }
    }

    /// The payload with emulation prevention bytes (`00 00 0x` becomes `00 00 03 0x` for x up to 3).
    func rbsp() -> [UInt8] {
        var out: [UInt8] = []
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte <= 3 {
                out.append(3)
                zeros = 0
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }
}
