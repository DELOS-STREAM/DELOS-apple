import Foundation

/// A touchscreen mode the stream menu's Mouse page offers (a `mouse_mode_list` choice): its stored value, its name and its help.
struct TouchModeOption: Equatable, Sendable {
    let value: Int
    let label: String
    let help: String
}

/// What the stream menu reads from and does to the stream's touch and pointer handling (the mouse part of `StreamMenuHost`,
/// StreamMenuHost.kt:84-90,127-134): the Zoom and Touch sensitivity switches of More, and the Mouse page's touchscreen mode and
/// local cursor. The stream's touch modes implement it on ``StreamController``; the defaults below stand in until they do: no
/// mode change (the Mouse mode row is hidden, as on Android when the mode cannot change), and switches that stay off.
@MainActor
protocol StreamTouchModes: AnyObject {
    /// The touchscreen mode may change during this stream (`allowChangeMouseMode`): More shows the Mouse mode row.
    var allowsTouchModeChange: Bool { get }
    var touchModeOptions: [TouchModeOption] { get }
    /// The value of the mode in use.
    var selectedTouchMode: Int { get }
    /// The profile keeps a mode chosen during the stream (`checkbox_remember_mouse_mode`).
    var rememberMouseMode: Bool { get }
    func setTouchMode(_ value: Int)
    /// The device's pointer shows over the stream.
    var localCursorVisible: Bool { get }
    func toggleLocalCursor()
    /// The stream's zoom-and-pan controls are on.
    var zoomOn: Bool { get }
    func toggleZoom()
    /// The touch sensitivity scaling of the settings is on.
    var touchSensitivityOn: Bool { get }
    func toggleTouchSensitivity()
}

extension StreamTouchModes {
    var allowsTouchModeChange: Bool { false }
    var touchModeOptions: [TouchModeOption] { [] }
    var selectedTouchMode: Int { 0 }
    var rememberMouseMode: Bool { false }
    func setTouchMode(_ value: Int) {}
    func toggleLocalCursor() {}
    var zoomOn: Bool { false }
    func toggleZoom() {}
    var touchSensitivityOn: Bool { false }
    func toggleTouchSensitivity() {}
}

extension StreamController: StreamTouchModes {}
