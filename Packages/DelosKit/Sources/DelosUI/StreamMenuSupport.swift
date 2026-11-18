import DelosData
import DelosInput
import Foundation
#if os(iOS)
import UIKit
#endif

/// The screen's brightness, which the stream menu's Brightness page changes for the length of a stream.
@MainActor
protocol ScreenBrightness: AnyObject {
    /// The screen's brightness now, 0 to 100.
    var percent: Int { get }
    func set(_ percent: Int)
    /// Gives back the brightness the screen had before the first ``set(_:)``.
    func restore()
}

#if os(iOS)
/// The brightness of the screen the app is on (iPhone and iPad). The system's own setting is the screen's, so it is put back
/// when the stream ends or the app leaves the screen; Android changes only its window's brightness.
@MainActor
final class DeviceBrightness: ScreenBrightness {
    private var original: CGFloat?

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    var percent: Int { Int(((screen?.brightness ?? 1) * 100).rounded()) }

    func set(_ percent: Int) {
        guard let screen else { return }
        if original == nil { original = screen.brightness }
        screen.brightness = CGFloat(percent) / 100
    }

    func restore() {
        guard let original else { return }
        screen?.brightness = original
        self.original = nil
    }
}
#endif

/// The texts of the stream menu that are chosen by name (the Send keys labels), so that every name stays a literal the
/// usage check of the String Catalog can find.
enum StreamMenuText {
    /// The Overlay tile's pill (`StreamMenuRoot`): Off, On for the full panel, Compact for the line.
    static func overlayState(_ overlay: StatisticsOverlay) -> String {
        switch overlay {
        case .off: L("common_off")
        case .full: L("common_on")
        case .compact: L("stream_menu_overlay_compact")
        }
    }

    static func specialKey(_ name: String) -> String {
        switch name {
        case "game_menu_send_keys_esc": L("game_menu_send_keys_esc")
        case "game_menu_send_keys_f11": L("game_menu_send_keys_f11")
        case "game_menu_send_keys_alt_f4": L("game_menu_send_keys_alt_f4")
        case "game_menu_send_keys_alt_enter": L("game_menu_send_keys_alt_enter")
        case "game_menu_send_keys_ctrl_v": L("game_menu_send_keys_ctrl_v")
        case "game_menu_send_keys_win": L("game_menu_send_keys_win")
        case "game_menu_send_keys_win_d": L("game_menu_send_keys_win_d")
        case "game_menu_send_keys_win_g": L("game_menu_send_keys_win_g")
        case "game_menu_send_keys_ctrl_alt_tab": L("game_menu_send_keys_ctrl_alt_tab")
        case "game_menu_send_keys_shift_tab": L("game_menu_send_keys_shift_tab")
        case "game_menu_send_keys_win_shift_left": L("game_menu_send_keys_win_shift_left")
        case "game_menu_send_keys_ctrl_alt_shift_f1": L("game_menu_send_keys_ctrl_alt_shift_f1")
        case "game_menu_send_keys_ctrl_alt_shift_f12": L("game_menu_send_keys_ctrl_alt_shift_f12")
        case "game_menu_send_keys_alt_b": L("game_menu_send_keys_alt_b")
        default: name
        }
    }

    /// The help (caption) of a tile (`circleHelpKey` and `streamMenuHelp`, StreamMenuLayout.kt:556-591): the upscaler's starts
    /// with its status and is Supersampling's while the stream is supersampled. The Keyboard tile raises the system keyboard
    /// here (DELOS for Android's is its own keyboard), so its help says that.
    @MainActor static func caption(_ item: BarItem, upscaler: any UpscalerControl) -> String {
        switch item {
        case .resume: L("stream_help_resume")
        case .keyboard: L("stream_help_keyboard_system")
        // The text carries a literal percent sign (`1%% low`): formatted so it reads once
        case .overlay: String(format: L("stream_help_overlay"))
        case .brightness: L("stream_help_brightness")
        case .bitrate: L("stream_help_bitrate")
        case .upscaler:
            helpLine(upscaler.status.text + "\n\n" + L(upscaler.supersamplingMode ? "stream_help_supersampling" : "stream_help_upscaler"))
        case .more: L("stream_help_more")
        case .disconnect: L("stream_help_disconnect")
        case .quit: L("stream_help_quit_game")
        }
    }

    /// A help's paragraphs as one flowing text, each joined to the next with a space after a full stop, else a middle dot
    /// (`helpLineText`, StreamMenuLayout.kt:663-673).
    static func helpLine(_ text: String) -> String {
        let paragraphs = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return paragraphs.reduce("") { line, next in
            guard let last = line.last else { return next }
            return ".!?".contains(last) ? "\(line) \(next)" : "\(line) \u{00B7} \(next)"
        }
    }
}

/// The Send keys page's combinations for a profile (`GameMenu.specialKeyOptions` of DELOS for Android, GameMenu.java:63-149):
/// Android's built-in ones unless `checkbox_enable_clear_default_special_button` clears them, then the profile's imported
/// custom keys. [failed]: the custom file could not be read past some combination (`wrong_import_format`).
enum StreamSpecialKeys {
    static func options(clearDefaults: Bool, custom: String?) -> (options: [SpecialKeys.Option], failed: Bool) {
        let parsed = CustomKeyCombos.parse(custom ?? "")
        return ((clearDefaults ? [] : SpecialKeys.all) + parsed.options, parsed.failed)
    }
}
