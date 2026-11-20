import Foundation

/// The groups of the Debug info screen, in the order their rows appear (`DebugSection` of DELOS for Android's
/// DebugInfoScreen.kt). The shape simulator of Android's debug builds is a tool of its emulator setup and has no rows here.
enum DebugSection: CaseIterable, Sendable {
    case device, displays, diagnostics, haptics, vibrationTest, rumbleLab, rumblePatterns, rumbleAdvanced, onScreenControls, controllers

    var title: String {
        switch self {
        case .device: L("debug_section_device")
        case .displays: L("debug_section_displays")
        case .diagnostics: L("debug_section_diagnostics")
        case .haptics: L("debug_section_haptics")
        case .vibrationTest: L("debug_section_vibration_test")
        case .rumbleLab: L("debug_section_rumble_lab")
        case .rumblePatterns: L("debug_section_rumble_patterns")
        case .rumbleAdvanced: L("debug_section_rumble_advanced")
        case .onScreenControls: L("debug_section_osc")
        case .controllers: L("debug_section_controllers")
        }
    }
}

/// A row of the Debug info screen (`DebugRow`): its [value] works like a settings row's (an action runs with A, a toggle
/// flips, a slider steps with left and right), [description] is the panel's text (and, when short, the line under the label) and
/// [details] the monospaced block under it.
struct DebugRow: Identifiable, Equatable {
    let id: String
    let section: DebugSection
    let icon: String
    let label: String
    let value: SettingValue
    let description: String
    var details: String? = nil
    /// False: the row is dimmed and its action only plays the error sound (a tool this device cannot run).
    var enabled = true
}
