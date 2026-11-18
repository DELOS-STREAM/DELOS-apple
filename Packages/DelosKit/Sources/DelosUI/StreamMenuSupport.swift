import DelosData
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

    /// The help (caption) of a tile: the complete text of Android's menu. Overlay and More have none, because Android's texts
    /// describe its own compact statistics and rows; Keyboard's names the system keyboard only where More has its row.
    static func caption(_ item: BarItem, capabilities: StreamMenuCapabilities = .platform) -> String {
        switch item {
        case .resume: L("stream_help_resume")
        case .keyboard:
            L(capabilities.systemKeyboard ? "stream_help_delos_keyboard_system" : "stream_help_delos_keyboard",
              StreamMenuButtonsText.name(.a), StreamMenuButtonsText.name(.b))
        case .brightness: L("stream_help_brightness")
        case .disconnect: L("stream_help_disconnect")
        case .quit: L("stream_help_quit_game")
        case .overlay, .more: ""
        }
    }
}
