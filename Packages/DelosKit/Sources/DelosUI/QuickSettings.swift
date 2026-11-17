import DelosData

/// The quick settings of the side menu (`SideMenuRows` of DELOS for Android): the theme, Material You colors (where the
/// system has a color to follow, ``SystemAccent``), the animated background, the interface sounds and the haptics, each
/// changed at once and kept with the current profile's appearance, above "All settings". The "Show hidden apps" row
/// waits for hiding games.
enum QuickSettings {
    /// The rows' ids, in the menu's order: the ones of the same settings in Settings → Appearance, Audio and Controls.
    static var ids: [String] {
        [AppearanceForm.theme] + (SystemAccent.supported ? [AppearanceForm.materialYou] : [])
            + [AppearanceForm.background, AppearanceForm.sounds, AppearanceForm.haptics]
    }

    /// The rows for [appearance]; they show the same values as Settings does, under the side menu's own names.
    static func rows(_ appearance: Appearance) -> [SettingRow] {
        let backgrounds = BackgroundKind.allCases
        let theme = SettingRow(
            id: AppearanceForm.theme, tab: .appearance, section: "", icon: Symbols.darkMode, label: L("shell_side_theme"),
            value: .choice(
                label: L(appearance.dark ? "shell_side_theme_dark" : "shell_side_theme_light"),
                options: AppearanceForm.themes.map { L($0 ? "shell_side_theme_dark" : "shell_side_theme_light") },
                selected: AppearanceForm.themes.firstIndex(of: appearance.dark)),
            help: "")
        let materialYou = SettingRow(
            id: AppearanceForm.materialYou, tab: .appearance, section: "", icon: Symbols.systemColors, label: L("shell_side_material_you"),
            value: .toggle(appearance.materialYou), help: "")
        return [theme] + (SystemAccent.supported ? [materialYou] : []) + [
            SettingRow(
                id: AppearanceForm.background, tab: .appearance, section: "", icon: Symbols.animation, label: L("shell_side_background"),
                value: .choice(
                    label: AppearanceForm.label(appearance.background), options: backgrounds.map(AppearanceForm.label),
                    selected: backgrounds.firstIndex(of: appearance.background)),
                help: ""),
            SettingRow(
                id: AppearanceForm.sounds, tab: .audio, section: "", icon: Symbols.musicNote, label: L("shell_side_sounds"),
                value: .toggle(appearance.sounds), help: ""),
            SettingRow(
                id: AppearanceForm.haptics, tab: .controls, section: "", icon: Symbols.haptics, label: L("shell_side_haptics"),
                value: .toggle(appearance.haptics), help: ""),
        ]
    }

    /// The appearance after row [id] was stepped by [direction] (A and right: 1, left: -1; a choice wraps round, a toggle
    /// flips); nil when nothing changed.
    static func step(_ id: String, by direction: Int, from appearance: Appearance) -> Appearance? {
        guard ids.contains(id) else { return nil }
        var form = AppearanceForm(appearance: appearance, offersMaterialYou: SystemAccent.supported)
        return form.step(id, by: direction) ? form.appearance : nil
    }
}
