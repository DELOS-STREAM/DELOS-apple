import CoreMedia
import DelosCore
import VideoToolbox

/// The video formats this device offers the host. H.264 always (every Apple device decodes it); HEVC and AV1 where
/// VideoToolbox decodes them in hardware; the 10-bit HDR profiles (HEVC Main10, AV1 Main 10) where a hardware session for
/// that profile can be created (``HardwareProbe``). Which of them a stream asks for follows the codec and HDR settings.
public enum DecoderSupport {
    public static func formats(hevc: Bool, av1: Bool, hevcMain10: Bool = false, av1Main10: Bool = false) -> VideoFormats {
        var formats: VideoFormats = .h264
        if hevc { formats.insert(.hevc) }
        if av1 { formats.insert(.av1Main8) }
        if hevc, hevcMain10 { formats.insert(.hevcMain10) }
        if av1, av1Main10 { formats.insert(.av1Main10) }
        return formats
    }

    /// What this device's hardware decodes.
    public static var device: VideoFormats {
        let hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let av1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        return formats(
            hevc: hevc, av1: av1, hevcMain10: hevc && HardwareProbe.hevcMain10, av1Main10: av1 && HardwareProbe.av1Main10)
    }
}
