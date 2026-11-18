import DelosInput

extension StreamSettingsForm {
    static let rumbleEnabled = "checkbox_enable_rumble"
    static let rumbleFeel = "list_rumble_feel"
    static let rumbleFallback = "checkbox_vibrate_fallback"
    static let rumbleDevice = "checkbox_enable_device_rumble"
    static let rumbleStrength = "seekbar_vibrate_fallback_strength"

    var rumbleRows: [SettingRow] {
        let config = settings.rumble
        let presets = RumblePreset.allCases
        // The advanced edits of Debug info read Custom; picking a preset replaces them
        let feel = config.activePreset.map { L($0.labelKey) } ?? L("debug_preset_custom")
        func toggle(_ id: String, icon: String, title: String, help: String, value: Bool, enabled: Bool = true) -> SettingRow {
            SettingRow(id: id, tab: .controls, section: L("category_gamepad_settings"), icon: icon,
                label: L(title), value: .toggle(value), help: L(help), enabled: enabled)
        }
        return [
            toggle(Self.rumbleEnabled, icon: Symbols.vibration, title: "title_enable_rumble", help: "help_checkbox_enable_rumble", value: config.enabled),
            SettingRow(id: Self.rumbleFeel, tab: .controls, section: L("category_gamepad_settings"), icon: Symbols.preset,
                label: L("stream_menu_row_rumble_feel"), value: .choice(label: feel,
                    options: presets.map { L($0.labelKey) }, selected: config.activePreset.flatMap { presets.firstIndex(of: $0) }),
                help: config.activePreset == nil
                    ? Self.details(value: feel, explanation: L("help_list_rumble_feel_custom"), unavailable: false, about: L("help_list_rumble_feel"))
                    : L("help_list_rumble_feel"),
                enabled: config.enabled),
            toggle(Self.rumbleFallback, icon: Symbols.deviceVibration, title: "title_checkbox_vibrate_fallback", help: "help_checkbox_vibrate_fallback",
                value: config.deviceFallback, enabled: config.enabled),
            toggle(Self.rumbleDevice, icon: Symbols.deviceForce, title: "title_device_rumble", help: "help_checkbox_enable_device_rumble",
                value: config.deviceEnabled, enabled: config.enabled && config.deviceFallback),
            SettingRow(id: Self.rumbleStrength, tab: .controls, section: L("category_gamepad_settings"), icon: Symbols.strength,
                label: L("title_seekbar_vibrate_fallback_strength"),
                value: .slider(value: config.deviceStrength, range: 1...200, step: 1, divisor: 1, unit: "%"),
                help: L("help_seekbar_vibrate_fallback_strength"), enabled: config.enabled && config.deviceFallback),
        ]
    }

    mutating func stepRumble(_ id: String, by direction: Int) {
        switch id {
        case Self.rumbleEnabled: settings.rumble.enabled.toggle()
        case Self.rumbleFeel where settings.rumble.enabled:
            let presets = RumblePreset.allCases
            // Custom follows the presets while it is active, so right goes to the first and left to the last
            let options = presets.count + (settings.rumble.activePreset == nil ? 1 : 0)
            let index = settings.rumble.activePreset.flatMap { presets.firstIndex(of: $0) } ?? presets.count
            let next = ((index + direction) % options + options) % options
            if presets.indices.contains(next) { settings.rumble.applyPreset(presets[next]) }
        case Self.rumbleFallback where settings.rumble.enabled: settings.rumble.deviceFallback.toggle()
        case Self.rumbleDevice where settings.rumble.enabled && settings.rumble.deviceFallback: settings.rumble.deviceEnabled.toggle()
        case Self.rumbleStrength where settings.rumble.enabled && settings.rumble.deviceFallback:
            settings.rumble.deviceStrength += direction
        default: break
        }
    }
}
