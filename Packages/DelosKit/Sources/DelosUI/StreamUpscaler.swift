import DelosData
import DelosMedia
import Foundation
import Observation

extension UpscalerMode {
    /// The name the Mode row shows: the label of the setting's own choice (`list_sgsr_quality` in the settings catalog), so the
    /// stream menu and Settings always name a method alike.
    var label: String {
        UpscalerModeText.choice(self)?.label ?? rawValue
    }

    /// The help of the method, the same as the setting's choice (`SettingsHelp.choice`).
    var help: String {
        UpscalerModeText.choice(self)?.help ?? ""
    }

    /// The method one press in [direction] (-1 or +1) leads to: the list wraps around (`nextUpscalerMode`).
    func next(_ direction: Int) -> UpscalerMode {
        let count = Self.allCases.count
        return Self.allCases[((index + direction) % count + count) % count]
    }
}

/// The upscaler's methods as the settings catalog lists them.
private enum UpscalerModeText {
    static func choice(_ mode: UpscalerMode) -> CatalogChoice? {
        guard case .choice(let choices)? = SettingsCatalog.spec(SettingKey.upscalerMode.rawValue)?.kind else { return nil }
        return choices.first { $0.value == mode.rawValue }
    }
}

extension UpscalerStatus {
    /// The status as the upscaler's help says it first (`statusText`, StreamMenuLayout.kt:645-652).
    var text: String {
        switch self {
        case .off: L("common_off")
        case .starting: L("stream_menu_upscaler_starting")
        case .stopping: L("stream_menu_upscaler_stopping")
        case .on(let mode): L("stream_menu_upscaler_on_mode", mode.label)
        case .unavailable: L("stream_menu_upscaler_unavailable_status")
        }
    }

    /// The one word in the tile's pill (`pillText`, StreamMenuLayout.kt:655-661).
    var pill: String {
        switch self {
        case .off: L("common_off")
        case .starting: L("stream_menu_upscaler_starting")
        case .stopping: L("stream_menu_upscaler_stopping")
        case .on: L("common_on")
        case .unavailable: L("stream_menu_upscaler_unavailable")
        }
    }
}

/// The live upscaler and supersampling controls of the running stream (`StreamMenuHost`'s upscaler part,
/// StreamMenuHost.kt:62-77; `surfaceController` of DELOS for Android). ``RendererUpscaler`` is the stream's renderer behind it.
@MainActor
protocol UpscalerControl: AnyObject {
    /// This device and stream can run the upscaler at all; without it the Upscaler page's rows cannot be used.
    var available: Bool { get }
    /// The player asked for the upscaler (`checkbox_sgsr`, or the page's Enabled switch).
    var requested: Bool { get }
    var status: UpscalerStatus { get }
    /// The upscaler supersamples, or would: the stream already matches the display and a level fits (the tile and page say
    /// Supersampling).
    var supersamplingMode: Bool { get }
    /// 1 (1.33×) or 2 (2×).
    var supersamplingLevel: Int { get }
    /// What the upscaler works with on this display, for the sizes the page shows; nil where nothing is upscaled.
    var sizePlan: UpscalerSizePlan? { get }
    var mode: UpscalerMode { get }
    /// The final sharpening, 0 … 100.
    var sharpness: Int { get }
    func setEnabled(_ on: Bool)
    func setMode(_ mode: UpscalerMode)
    func setSharpness(_ percent: Int)
    func setSupersamplingLevel(_ level: Int)
}

/// The upscaler of the stream's renderer (``VideoRenderer/setUpscaler(_:)``): each change goes to the renderer at once, and the
/// status the renderer reports is read again every 250 ms while the stream menu shows it (StreamMenuRoot.kt:286-296).
@MainActor
@Observable
final class RendererUpscaler: UpscalerControl {
    @ObservationIgnored private let renderer: any VideoRenderer
    /// The renderer draws through Metal, where the upscaler runs; the display layer has none.
    let available: Bool
    private(set) var settings: UpscalerSettings
    private(set) var status: UpscalerStatus
    private(set) var supersamplingMode: Bool
    let sizePlan: UpscalerSizePlan?

    /// The renderer was made with the stream's upscaler settings (``StreamSettings/videoRenderOptions``); the Metal renderer
    /// runs the upscaler, the display layer cannot. [sizePlan] is the stream on this display.
    init(renderer: any VideoRenderer, sizePlan: UpscalerSizePlan? = nil) {
        self.renderer = renderer
        available = renderer is MetalRenderer
        settings = renderer.upscalerSettings
        status = renderer.upscalerStatus
        self.sizePlan = sizePlan
        supersamplingMode = Self.supersampling(renderer, plan: sizePlan, mode: renderer.upscalerSettings.mode)
    }

    var requested: Bool { settings.enabled }
    var supersamplingLevel: Int { settings.supersamplingLevel }
    var mode: UpscalerMode { settings.mode }
    var sharpness: Int { settings.sharpness }

    func setEnabled(_ on: Bool) { change { $0.enabled = on } }
    func setMode(_ mode: UpscalerMode) { change { $0.mode = mode } }
    func setSharpness(_ percent: Int) { change { $0.sharpness = percent } }
    func setSupersamplingLevel(_ level: Int) { change { $0.supersamplingLevel = level } }

    /// Reads what the renderer is doing now (the status and whether it supersamples).
    func refresh() {
        let now = renderer.upscalerStatus
        if now != status { status = now }
        let supersampling = Self.supersampling(renderer, plan: sizePlan, mode: settings.mode)
        if supersampling != supersamplingMode { supersamplingMode = supersampling }
    }

    /// Supersampling as the menu names it (`isSupersamplingMode`): the renderer supersamples now, or a scaling mode would,
    /// because the stream already has the picture's size and a level fits. A 2× that does not fit draws without
    /// supersampling, and the level row stays to choose the 1.33× that does.
    private static func supersampling(_ renderer: any VideoRenderer, plan: UpscalerSizePlan?, mode: UpscalerMode) -> Bool {
        renderer.isSupersampling || (mode.scales && plan?.supersamples(mode: mode) == true)
    }

    private func change(_ edit: (inout UpscalerSettings) -> Void) {
        var next = settings
        edit(&next)
        settings = next
        renderer.setUpscaler(next)
        refresh()
    }
}

/// The upscaler of a stream without a renderer (a controller made without one): nothing to upscale, the rows cannot be used.
@MainActor
final class NoUpscaler: UpscalerControl {
    var available: Bool { false }
    var requested: Bool { false }
    var status: UpscalerStatus { .off }
    var supersamplingMode: Bool { false }
    var supersamplingLevel: Int { 1 }
    var sizePlan: UpscalerSizePlan? { nil }
    var mode: UpscalerMode { .spatial }
    var sharpness: Int { 50 }
    func setEnabled(_ on: Bool) {}
    func setMode(_ mode: UpscalerMode) {}
    func setSharpness(_ percent: Int) {}
    func setSupersamplingLevel(_ level: Int) {}
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
