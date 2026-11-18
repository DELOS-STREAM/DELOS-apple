import Foundation

/// How the picture fills the view (`list_video_scale_mode` of DELOS for Android, `PreferenceConfiguration.ScaleMode`).
public enum VideoScaleMode: String, CaseIterable, Sendable {
    /// The whole picture, as large as fits, black bars where the aspect ratios differ.
    case fit
    /// The whole view, as small as covers it: the picture's edges beyond the view are cut off.
    case fill
    /// The whole view, the picture's aspect ratio ignored.
    case stretch

    /// The stored value's mode; anything unknown is Fit, Android's default.
    public init(value: String) {
        self = Self(rawValue: value) ?? .fit
    }
}

/// The upscaler's methods (`list_sgsr_quality`, Android `preferences/UpscalerMode.java:13-18`). The declaration order is
/// Android's: the stream menu's Mode row order, and ``index`` the renderers' mode number.
public enum UpscalerMode: String, CaseIterable, Sendable {
    /// SGSR 1, Qualcomm's spatial upscaler.
    case standard
    /// SGSR 1 in its high quality variant.
    case high
    /// SGSR 2 adapted to video: optical flow, history.
    case temporal
    /// SGSR 2 with the reactive mask and the chroma-aware history clip.
    case temporalQuality = "temporal-quality"
    /// No scaling: one contrast-adaptive sharpen pass at the stream's own resolution.
    case sharpen

    /// The stored value's mode; anything unknown (an older or newer build's value) is Standard.
    public init(value: String) {
        self = Self(rawValue: value) ?? .standard
    }

    /// The mode at a stream menu position, clamped into the list.
    public init(index: Int) {
        let all = Self.allCases
        self = all[max(0, min(all.count - 1, index))]
    }

    /// The position in the stream menu's Mode row; also the bit of the once-per-stream overload notice.
    public var index: Int { Self.allCases.firstIndex(of: self)! }

    /// SGSR 2 modes keep a history of earlier frames.
    public var isTemporal: Bool { self == .temporal || self == .temporalQuality }

    /// Whether the mode changes the picture's size (upscaling, or supersampling when the stream already matches the
    /// view). Sharpen only does not: the supersampling quality means nothing to it.
    public var scales: Bool { self != .sharpen }
}

/// What the stream asks of the upscaler: the four rows of Settings → Display (`checkbox_sgsr`, `list_sgsr_quality`,
/// `seekbar_sgsr_sharpness`, `list_sgsr_supersampling_level`) and of the stream menu's Upscaler page.
public struct UpscalerSettings: Sendable, Equatable {
    public var enabled: Bool
    public var mode: UpscalerMode
    /// 0–100; the shaders take it as 0–1.
    public var sharpness: Int { didSet { sharpness = Self.clampSharpness(sharpness) } }
    /// 1 (4/3 of the view, the "1.33×" choice) or 2 (twice the view).
    public var supersamplingLevel: Int { didSet { supersamplingLevel = Self.clampLevel(supersamplingLevel) } }

    public init(enabled: Bool = false, mode: UpscalerMode = .standard, sharpness: Int = 50, supersamplingLevel: Int = 1) {
        self.enabled = enabled
        self.mode = mode
        self.sharpness = Self.clampSharpness(sharpness)
        self.supersamplingLevel = Self.clampLevel(supersamplingLevel)
    }

    /// Android `SgsrRenderer.setSharpness`: clamped into 0–100.
    static func clampSharpness(_ value: Int) -> Int { max(0, min(100, value)) }
    /// Android `SgsrRenderer.setSupersamplingLevel`: 2 and above is 2, anything else 1.
    static func clampLevel(_ value: Int) -> Int { value >= 2 ? 2 : 1 }
}

/// What the upscaler is doing right now (Android `UpscalerStatus.java`), for the stream menu's status pill.
public enum UpscalerStatus: Sendable, Equatable {
    /// Not requested and not running.
    case off
    /// Requested; no picture has been drawn through it yet.
    case starting
    /// Switched off; the picture on screen is still the upscaled one.
    case stopping
    /// Running with this method.
    case on(UpscalerMode)
    /// Requested but impossible here (no Metal upscaler on this renderer, or it failed): the picture is drawn directly.
    case unavailable

    /// Starting or stopping: the on/off switch waits.
    public var isChanging: Bool { self == .starting || self == .stopping }
}

/// Android's Variable refresh rate setting (`list_vrr`, `VrrMode.java`).
public enum VariableRefreshRate: String, CaseIterable, Sendable {
    case auto
    case on
    case off

    /// An unknown stored value behaves as Auto, the default.
    public init(value: String) {
        self = Self(rawValue: value) ?? .auto
    }

    /// Whether VRR is active: Auto follows the display's report, On forces it, Off disables it (`VrrMode.resolve`).
    public func resolve(reported: Bool) -> Bool {
        switch self {
        case .on: true
        case .off: false
        case .auto: reported
        }
    }
}

/// Everything about the picture a renderer needs from the settings besides the pacing and the frame rate.
public struct VideoRenderOptions: Sendable, Equatable {
    public var scaleMode: VideoScaleMode
    public var upscaler: UpscalerSettings
    public var vrr: VariableRefreshRate
    /// `checkbox_reduce_refresh_rate`: Balanced prefers the lowest refresh rate that matches the stream.
    public var reduceRefreshRate: Bool
    /// `checkbox_enforce_display_mode`: a display mode that only differs in refresh rate is switched to as a mode.
    public var enforceDisplayMode: Bool
    /// The stream's resolution and frame rate as the settings ask for them (before Cap FPS and the warp factor), for the
    /// refresh rate plan (``DisplayRefreshPlanner``); zero when unknown (the display's own size is used then).
    public var streamWidth: Int
    public var streamHeight: Int
    public var frameRate: Int
    /// The stream asks the host for HDR (a 10-bit format and an HDR display).
    public var hdr: Bool

    public init(
        scaleMode: VideoScaleMode = .fit, upscaler: UpscalerSettings = UpscalerSettings(), vrr: VariableRefreshRate = .auto,
        reduceRefreshRate: Bool = false, enforceDisplayMode: Bool = false, streamWidth: Int = 0, streamHeight: Int = 0,
        frameRate: Int = 0, hdr: Bool = false
    ) {
        self.scaleMode = scaleMode
        self.upscaler = upscaler
        self.vrr = vrr
        self.reduceRefreshRate = reduceRefreshRate
        self.enforceDisplayMode = enforceDisplayMode
        self.streamWidth = streamWidth
        self.streamHeight = streamHeight
        self.frameRate = frameRate
        self.hdr = hdr
    }

    /// The refresh rate plan for `display`: `pacing` and `fps` are the renderer's (fps is used when no configured frame
    /// rate is set).
    public func refreshPlan(for display: VideoDisplay, pacing: FramePacing, fps: Int) -> DisplayRefreshPlanner.Plan {
        let configured = frameRate > 0 ? frameRate : fps
        var plan = DisplayRefreshPlanner.plan(DisplayRefreshPlanner.Input(
            display: display, streamWidth: streamWidth > 0 ? streamWidth : display.currentMode.width,
            streamHeight: streamHeight > 0 ? streamHeight : display.currentMode.height, fps: Double(configured), pacing: pacing,
            reduceRefreshRate: reduceRefreshRate, enforceDisplayMode: enforceDisplayMode,
            refreshRateCeiling: display.refreshRateCeiling, vrr: vrr.resolve(reported: display.reportsVariableRefreshRate)))
        plan.hdr = hdr
        return plan
    }
}
