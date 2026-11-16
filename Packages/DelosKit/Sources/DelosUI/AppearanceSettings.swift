import DelosData
import Foundation

/// The rows of the current profile's ``Appearance`` in Settings (the native rows of `nativeSettings` in DELOS for
/// Android): Appearance → theme, palette, animated background and animations; the interface sounds under Audio and the
/// interface haptics under Controls, where Android has them. Each change applies at once.
///
/// Not ported: Material You (no counterpart on Apple platforms), the game colors and the game background with its blur
/// and opacity (no game background yet), the clock format (the status bar has no clock yet) and the interface scale
/// (the stage has no text scale yet).
struct AppearanceForm: Equatable {
    var appearance: Appearance

    static let theme = "ui_dark"
    static let palette = "ui_palette"
    static let background = "ui_background"
    static let motion = "ui_reduced_motion"
    static let sounds = "ui_sounds"
    static let haptics = "ui_haptics"

    /// The ids of every row this form owns.
    static let ids: Set<String> = [theme, palette, background, motion, sounds, haptics]

    /// The rows of [tab] in Android's order.
    func rows(_ tab: SettingsTab) -> [SettingRow] {
        switch tab {
        case .stream: []
        case .audio: [soundsRow]
        case .controls: [hapticsRow]
        case .appearance: [themeRow, paletteRow, backgroundRow, motionRow]
        }
    }

    // MARK: The values of each row

    /// Dark, light (`dark` of the appearance).
    static let themes = [true, false]
    /// Full, reduced (`reducedMotion` of the appearance).
    static let motions = [false, true]

    static func themeLabel(dark: Bool) -> String { L(dark ? "settings_native_theme_dark" : "settings_native_theme_light") }

    static func motionLabel(reduced: Bool) -> String {
        L(reduced ? "settings_native_animations_reduced" : "settings_native_animations_full")
    }

    // Literal names, so tools/l10n/check_usage.py sees every one of them
    static func label(_ palette: PaletteName) -> String {
        switch palette {
        case .delos: L("settings_option_palette_delos")
        case .ember: L("settings_option_palette_ember")
        case .rose: L("settings_option_palette_rose")
        case .orchid: L("settings_option_palette_orchid")
        case .dusk: L("settings_option_palette_dusk")
        case .iris: L("settings_option_palette_iris")
        case .graphite: L("settings_option_palette_graphite")
        case .mint: L("settings_option_palette_mint")
        }
    }

    static func label(_ background: BackgroundKind) -> String {
        switch background {
        case .aurora: L("settings_option_background_aurora")
        case .tide: L("settings_option_background_tide")
        case .silk: L("settings_option_background_silk")
        case .contour: L("settings_option_background_contour")
        case .nebula: L("settings_option_background_nebula")
        case .plasma: L("settings_option_background_plasma")
        case .lava: L("settings_option_background_lava")
        case .caustics: L("settings_option_background_caustics")
        case .bokeh: L("settings_option_background_bokeh")
        case .orbit: L("settings_option_background_orbit")
        case .still: L("settings_option_background_still")
        }
    }

    /// What a background looks like (`settings_native_help_background_<kind>`).
    static func help(_ background: BackgroundKind) -> String {
        switch background {
        case .aurora: L("settings_native_help_background_aurora")
        case .tide: L("settings_native_help_background_tide")
        case .silk: L("settings_native_help_background_silk")
        case .contour: L("settings_native_help_background_contour")
        case .nebula: L("settings_native_help_background_nebula")
        case .plasma: L("settings_native_help_background_plasma")
        case .lava: L("settings_native_help_background_lava")
        case .caustics: L("settings_native_help_background_caustics")
        case .bokeh: L("settings_native_help_background_bokeh")
        case .orbit: L("settings_native_help_background_orbit")
        case .still: L("settings_native_help_background_still")
        }
    }

    /// The dot beside a palette's name: its main hue (`hsl(accent, 90, 60)` of DELOS for Android), in either theme.
    static func swatch(_ palette: PaletteName) -> RGBA { hsl(Palette(palette).accent, 90, 60) }

    // MARK: Rows

    private var interface: String { L("settings_native_section_interface") }

    private var themeRow: SettingRow {
        let label = Self.themeLabel(dark: appearance.dark)
        return SettingRow(
            id: Self.theme, tab: .appearance, section: interface, icon: Symbols.darkMode, label: L("settings_native_theme_title"),
            value: .choice(label: label, options: Self.themes.map(Self.themeLabel), selected: Self.themes.firstIndex(of: appearance.dark)),
            help: Self.details(
                value: label,
                explanation: L(appearance.dark ? "settings_native_help_theme_dark" : "settings_native_help_theme_light"),
                about: L("settings_native_theme_description")))
    }

    private var paletteRow: SettingRow {
        let label = Self.label(appearance.palette)
        // A palette needs no explanation of its own: the description panel shows its three colors
        return SettingRow(
            id: Self.palette, tab: .appearance, section: interface, icon: Symbols.palette, label: L("settings_native_palette_title"),
            value: .choice(label: label, options: PaletteName.allCases.map(Self.label), selected: PaletteName.allCases.firstIndex(of: appearance.palette)),
            help: Self.details(value: label, explanation: nil, about: L("settings_native_palette_description")),
            swatch: Self.swatch(appearance.palette))
    }

    private var backgroundRow: SettingRow {
        let label = Self.label(appearance.background)
        // Android's description of the row names its Android version; the chosen background's explanation stands alone
        return SettingRow(
            id: Self.background, tab: .appearance, section: interface, icon: Symbols.animation, label: L("settings_native_background_title"),
            value: .choice(label: label, options: BackgroundKind.allCases.map(Self.label), selected: BackgroundKind.allCases.firstIndex(of: appearance.background)),
            help: Self.details(value: label, explanation: Self.help(appearance.background), about: nil))
    }

    private var motionRow: SettingRow {
        let reduced = appearance.reducedMotion
        let label = Self.motionLabel(reduced: reduced)
        return SettingRow(
            id: Self.motion, tab: .appearance, section: interface, icon: Symbols.reducedMotion, label: L("settings_native_animations_title"),
            value: .choice(label: label, options: Self.motions.map(Self.motionLabel), selected: Self.motions.firstIndex(of: reduced)),
            help: Self.details(
                value: label,
                explanation: L(reduced ? "settings_native_help_motion_reduced" : "settings_native_help_motion_full"),
                about: L("settings_native_animations_description")))
    }

    private var soundsRow: SettingRow {
        SettingRow(
            id: Self.sounds, tab: .audio, section: interface, icon: Symbols.musicNote, label: L("settings_native_sounds_title"),
            value: .toggle(appearance.sounds), help: L("settings_native_sounds_description"))
    }

    private var hapticsRow: SettingRow {
        SettingRow(
            id: Self.haptics, tab: .controls, section: interface, icon: Symbols.haptics, label: L("settings_native_haptics_title"),
            value: .toggle(appearance.haptics), help: L("settings_native_haptics_description"))
    }

    /// `NativeSettingsHelp.details`: the chosen value with its explanation, a blank line, then what the row does.
    static func details(value: String, explanation: String?, about: String?) -> String {
        [explanation.map { "\(value)\n\($0)" } ?? value, about].compactMap { $0 }.joined(separator: "\n\n")
    }

    // MARK: Changes

    /// Left / right (A: +1) on row [id]: the next value, wrapping around; a toggle flips. False when nothing changed.
    @discardableResult
    mutating func step(_ id: String, by direction: Int) -> Bool {
        let before = appearance
        switch id {
        case Self.theme: appearance.dark = Self.next(appearance.dark, in: Self.themes, direction)
        case Self.palette: appearance.palette = Self.next(appearance.palette, in: PaletteName.allCases, direction)
        case Self.background: appearance.background = Self.next(appearance.background, in: BackgroundKind.allCases, direction)
        case Self.motion: appearance.reducedMotion = Self.next(appearance.reducedMotion, in: Self.motions, direction)
        case Self.sounds: appearance.sounds.toggle()
        case Self.haptics: appearance.haptics.toggle()
        default: break
        }
        return appearance != before
    }

    /// A value picked from a choice row's list.
    mutating func pick(_ id: String, option index: Int) {
        switch id {
        case Self.theme: if Self.themes.indices.contains(index) { appearance.dark = Self.themes[index] }
        case Self.palette: if PaletteName.allCases.indices.contains(index) { appearance.palette = PaletteName.allCases[index] }
        case Self.background: if BackgroundKind.allCases.indices.contains(index) { appearance.background = BackgroundKind.allCases[index] }
        case Self.motion: if Self.motions.indices.contains(index) { appearance.reducedMotion = Self.motions[index] }
        default: break
        }
    }

    private static func next<T: Equatable>(_ value: T, in list: [T], _ direction: Int) -> T {
        guard let index = list.firstIndex(of: value) else { return list[0] }
        return list[((index + direction) % list.count + list.count) % list.count]
    }
}
