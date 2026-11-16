import CoreMedia
import DelosCore
import VideoToolbox

/// The video formats this device offers the host. H.264 always (every Apple device decodes it); HEVC and AV1 where
/// VideoToolbox decodes them in hardware. Only 8-bit SDR formats for now: 10-bit is offered once HDR is supported.
public enum DecoderSupport {
    public static func formats(hevc: Bool, av1: Bool) -> VideoFormats {
        var formats: VideoFormats = .h264
        if hevc { formats.insert(.hevc) }
        if av1 { formats.insert(.av1Main8) }
        return formats
    }

    /// What this device's hardware decodes.
    public static var device: VideoFormats {
        formats(hevc: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), av1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))
    }
}
