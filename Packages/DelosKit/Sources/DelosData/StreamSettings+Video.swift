import DelosCore
import DelosMedia
import Foundation

extension StreamSettings {
    /// The upscaler rows of Settings → Display (`checkbox_sgsr`, `list_sgsr_quality`, `seekbar_sgsr_sharpness`,
    /// `list_sgsr_supersampling_level`).
    public var upscalerSettings: UpscalerSettings {
        UpscalerSettings(
            enabled: bool(.upscaler), mode: UpscalerMode(value: text(.upscalerMode)), sharpness: int(.upscalerSharpness),
            supersamplingLevel: Int(text(.upscalerSupersampling)) ?? 1)
    }

    /// What the renderer needs from the settings besides the pacing and the frame rate, on a display of `displayWidth` ×
    /// `displayHeight` pixels (where the stream's resolution follows the display). HDR is asked for as ``StreamPlan`` asks
    /// the host: with an HDR display and a 10-bit format to carry it.
    public func videoRenderOptions(
        displayWidth: Int, displayHeight: Int, decodable: VideoFormats, displaySupportsHDR: Bool
    ) -> VideoRenderOptions {
        let size = resolution(displayWidth: displayWidth, displayHeight: displayHeight)
        let formats = codec.formats(decodable: decodable, hdr: hdr && displaySupportsHDR)
        return VideoRenderOptions(
            scaleMode: VideoScaleMode(value: text(.videoScaleMode)), upscaler: upscalerSettings,
            vrr: VariableRefreshRate(value: text(.vrr)), reduceRefreshRate: bool(.reduceRefreshRate),
            enforceDisplayMode: bool(.enforceDisplayMode), streamWidth: size.width, streamHeight: size.height, frameRate: fps,
            hdr: !formats.isDisjoint(with: .tenBit))
    }
}
