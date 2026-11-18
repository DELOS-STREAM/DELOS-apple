import DelosData
import Foundation
import Observation

/// The upscaler's methods (`UpscalerMode` of DELOS for Android, preferences/UpscalerMode.java:13-18): the order is the stream
/// menu's Mode row, the raw value is what `list_sgsr_quality` stores.
enum UpscalerMode: String, CaseIterable, Sendable {
    case standard
    case high
    case temporal
    case temporalQuality = "temporal-quality"
    /// No scaling: the stream keeps its resolution and only a sharpen pass runs.
    case sharpen

    /// The mode of a stored value; anything unknown is Standard (`fromValue`).
    init(stored: String?) {
        self = stored.flatMap(UpscalerMode.init(rawValue:)) ?? .standard
    }

    /// The mode at a position of the Mode row, clamped into the list (`fromIndex`).
    init(index: Int) {
        self = Self.allCases[min(max(index, 0), Self.allCases.count - 1)]
    }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// The name the Mode row and the settings list show.
    var label: String {
        switch self {
        case .standard: L("sgsr_quality_standard")
        case .high: L("sgsr_quality_high")
        case .temporal: L("sgsr_quality_temporal")
        case .temporalQuality: L("sgsr_quality_temporal_quality")
        case .sharpen: L("sgsr_quality_sharpen")
        }
    }

    /// The help of the mode in the settings list (`SettingsHelp.choice` of `list_sgsr_quality`).
    var help: String {
        switch self {
        case .standard: L("help_list_sgsr_quality_standard")
        case .high: L("help_list_sgsr_quality_high")
        case .temporal: L("help_list_sgsr_quality_temporal")
        case .temporalQuality: L("help_list_sgsr_quality_temporal_quality")
        case .sharpen: L("help_list_sgsr_quality_sharpen")
        }
    }

    /// The mode changes the picture's size; Sharpen only does not, so the supersampling quality means nothing for it.
    var scales: Bool { self != .sharpen }

    /// The mode one press in [direction] (-1 or +1) leads to: the list wraps around (`nextUpscalerMode`).
    func next(_ direction: Int) -> UpscalerMode {
        let count = Self.allCases.count
        return Self.allCases[((index + direction) % count + count) % count]
    }
}

/// What the renderer's upscaler is doing (`UpscalerStatus`, binding/video/UpscalerStatus.java:9-47).
struct UpscalerStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// Not requested and not running.
        case off
        /// Requested; its output stage is still being built.
        case starting
        /// Removed; its output stage is still being torn down.
        case stopping
        /// Running; ``mode`` says which method when the renderer knows it.
        case on
        /// Requested but impossible on this stream: the picture is drawn directly.
        case unavailable
    }

    var state: State
    var mode: UpscalerMode?

    static let off = UpscalerStatus(state: .off)
    static let unavailable = UpscalerStatus(state: .unavailable)

    /// Starting or stopping: the on/off switch waits.
    var isChanging: Bool { state == .starting || state == .stopping }

    /// The status as the upscaler's help says it first (`statusText`, StreamMenuLayout.kt:645-652).
    var text: String {
        switch state {
        case .off: L("common_off")
        case .starting: L("stream_menu_upscaler_starting")
        case .stopping: L("stream_menu_upscaler_stopping")
        case .on: mode.map { L("stream_menu_upscaler_on_mode", $0.label) } ?? L("common_on")
        case .unavailable: L("stream_menu_upscaler_unavailable_status")
        }
    }

    /// The one word in the tile's pill (`pillText`, StreamMenuLayout.kt:655-661).
    var pill: String {
        switch state {
        case .off: L("common_off")
        case .starting: L("stream_menu_upscaler_starting")
        case .stopping: L("stream_menu_upscaler_stopping")
        case .on: L("common_on")
        case .unavailable: L("stream_menu_upscaler_unavailable")
        }
    }
}

/// The live upscaler and supersampling controls of the running stream (`StreamMenuHost`'s upscaler part,
/// StreamMenuHost.kt:62-77; `surfaceController` of DELOS for Android). A renderer that upscales implements it; until one
/// does, ``UnavailableUpscaler`` answers.
@MainActor
protocol UpscalerControl: AnyObject {
    /// This device and stream can run the upscaler at all; without it the Upscaler page's rows cannot be used.
    var available: Bool { get }
    /// The player asked for the upscaler (`checkbox_sgsr`, or the page's Enabled switch).
    var requested: Bool { get }
    var status: UpscalerStatus { get }
    /// The stream already matches the display, so the upscaler supersamples (the tile and page say Supersampling).
    var supersamplingMode: Bool { get }
    /// 1 (1.33×) or 2 (2×).
    var supersamplingLevel: Int { get }
    var mode: UpscalerMode { get }
    /// The final sharpening, 0 … 100.
    var sharpness: Int { get }
    func setEnabled(_ on: Bool)
    func setMode(_ mode: UpscalerMode)
    func setSharpness(_ percent: Int)
    func setSupersamplingLevel(_ level: Int)
}

/// The upscaler of a renderer that has none: the profile's choices are kept and shown (and saved for the game when the page
/// changes them), the status is Off, or Unavailable while it is asked for, and the page's rows cannot be used. No renderer of
/// DELOS for Apple upscales yet; Android's is SGSR on OpenGL ES (binding/video/SgsrRenderer).
@MainActor
@Observable
final class UnavailableUpscaler: UpscalerControl {
    private(set) var requested: Bool
    private(set) var mode: UpscalerMode
    private(set) var sharpness: Int
    private(set) var supersamplingLevel: Int

    init(settings: StreamSettings) {
        requested = settings.bool(.upscaler)
        mode = UpscalerMode(stored: settings.text(.upscalerMode))
        sharpness = settings.int(.upscalerSharpness)
        supersamplingLevel = settings.text(.upscalerSupersampling) == "2" ? 2 : 1
    }

    var available: Bool { false }
    var status: UpscalerStatus { requested ? .unavailable : .off }
    var supersamplingMode: Bool { false }
    func setEnabled(_ on: Bool) { requested = on }
    func setMode(_ mode: UpscalerMode) { self.mode = mode }
    func setSharpness(_ percent: Int) { sharpness = min(max(percent, 0), 100) }
    func setSupersamplingLevel(_ level: Int) { supersamplingLevel = level >= 2 ? 2 : 1 }
}

/// The upscaler's settings as the stream menu keeps them for the running game (`upscalerSaveValues`, settings/UpscalerSave.kt):
/// clamped, so what is stored reads back unchanged.
enum UpscalerSave {
    @MainActor static func values(_ upscaler: any UpscalerControl) -> [SettingKey: StoredSetting] {
        [
            .upscaler: .bool(upscaler.requested),
            .upscalerMode: .text(upscaler.mode.rawValue),
            .upscalerSharpness: .int(min(max(upscaler.sharpness, 0), 100)),
            .upscalerSupersampling: .text(upscaler.supersamplingLevel >= 2 ? "2" : "1"),
        ]
    }
}
