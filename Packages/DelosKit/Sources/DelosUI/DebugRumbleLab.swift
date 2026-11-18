import DelosData
import DelosInput
import Foundation
import GameController

/// The haptics, vibration test, rumble laboratory and controllers sections of Debug info (rows `cap_vibrators` through
/// `pads_continuous` of DELOS for Android's DebugInfoScreen.kt). The device motor is this device's haptic engine (iPhone;
/// iPad, Apple TV and Mac have none); the patterns play through the stream's own translation of the selected preset, and
/// a preset or an advanced edit is saved to the profile's stream settings at once, as the Settings "Rumble feel" reads it.
@MainActor @Observable
final class DebugRumbleLab {
    private var strength = 220
    private var deviceContinuous = false
    private var padsContinuous = false
    private var pads: [GCController]
    /// The saved parameters, whether the translator applies them, and the preset they are (nil: Custom).
    private var profile: RumbleProfile
    private var translatorEnabled: Bool
    private var activePreset: RumblePreset?
    private var advancedExpanded = false
    private var playing: RumbleTestPattern?
    /// The running pattern's translated amplitude, 0...255, sampled about 60 times a second.
    private var amplitude = 0
    private var problem: RumbleProblem?

    @ObservationIgnored private let profileID: String
    @ObservationIgnored private let toasts: Toasts
    @ObservationIgnored private let store = StreamSettingsStore()
    @ObservationIgnored private let player: HapticTestPlayer
    @ObservationIgnored private let hasMotor: Bool
    /// Counts the patterns started and stopped, so a cancelled older pattern never stops its replacement (`patternRun`).
    @ObservationIgnored private var patternRun = 0
    @ObservationIgnored private var patternTask: Task<Void, Never>?
    @ObservationIgnored private var sampler: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// A slider row's range, step and unit.
    private struct Slider {
        let range: ClosedRange<Int>
        let step: Int
        let unit: String
    }

    private static let sliders: [String: Slider] = [
        "strength": Slider(range: 5...255, step: 5, unit: ""),
        "rumble_gain": Slider(range: 50...300, step: 1, unit: "%"),
        "rumble_curve": Slider(range: 50...300, step: 1, unit: "%"),
        "rumble_min": Slider(range: 0...255, step: 1, unit: ""),
        "rumble_kick": Slider(range: 0...120, step: 1, unit: " ms"),
        "rumble_low": Slider(range: 0...100, step: 1, unit: "%"),
        "rumble_high": Slider(range: 0...100, step: 1, unit: "%"),
        "rumble_smoothing": Slider(range: 0...100, step: 1, unit: "%"),
    ]

    init(profileID: String, toasts: Toasts) {
        self.profileID = profileID
        self.toasts = toasts
        player = HapticTestPlayer()
        hasMotor = DeviceHardware.haptics
        let rumble = StreamSettingsStore().load(profile: profileID).rumble
        profile = rumble.savedProfile
        translatorEnabled = rumble.translatorEnabled
        activePreset = rumble.activePreset
        pads = GCController.controllers()
        // Connected and disconnected controllers show up at once
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPads(without: nil) }
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
                let gone = (note.object as? GCController).map(ObjectIdentifier.init)
                MainActor.assumeIsolated { self?.refreshPads(without: gone) }
            },
        ]
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        patternTask?.cancel()
        sampler?.cancel()
        player.stopAll()
    }

    // MARK: Rows

    /// Rows in Android order for the sections haptics, vibration test, rumble lab, rumble patterns, rumble advanced and
    /// controllers.
    func rows() -> [DebugRow] {
        let presetName = activePreset.map { L($0.labelKey) } ?? L("debug_preset_custom")
        let problemText = problem.map(text)
        let modeName = translatorEnabled ? L("debug_mode_translator_on", presetName) : L("debug_mode_translator_off", presetName)
        let playingName = playing.map(Self.label) ?? L("debug_stopped")
        // This device's haptic engine is its one motor, and its intensity is the amplitude control
        let vibrators = hasMotor ? 1 : 0
        var rows = [
            DebugRow(id: "cap_vibrators", section: .haptics, icon: Symbols.vibrators, label: L("debug_vibrators_label"),
                value: .info(vibrators == 1 ? L("debug_vibrators_single") : "\(vibrators)"), description: L("debug_vibrators_description")),
            DebugRow(id: "cap_amplitude", section: .haptics, icon: Symbols.amplitudeSupport, label: L("debug_amplitude_label"),
                value: .info(hasMotor ? L("debug_yes") : L("debug_no")), description: L("debug_amplitude_description")),
            DebugRow(id: "cap_problem", section: .haptics, icon: Symbols.warning, label: L("debug_last_problem_label"),
                value: .info(problemText ?? L("debug_none")), description: L("debug_last_problem_description")),
            DebugRow(id: "vibrate_once", section: .vibrationTest, icon: Symbols.deviceVibration, label: L("debug_vibrate_once_label"),
                value: .action(label: nil), description: hasMotor ? L("debug_vibrate_once_description") : L("debug_motor_no_description")),
            DebugRow(id: "vibrate_continuous", section: .vibrationTest, icon: Symbols.continuous, label: L("debug_continuous_label"),
                value: .toggle(deviceContinuous), description: L("debug_continuous_description")),
            sliderRow("strength", section: .vibrationTest, icon: Symbols.strength, label: L("debug_strength_label"),
                value: strength, description: L("debug_strength_description")),
            DebugRow(id: "rumble_preset", section: .rumbleLab, icon: Symbols.preset, label: L("debug_preset_label"),
                value: .info(presetName), description: L("debug_preset_description"), details: L("debug_preset_details", modeName)),
        ]
        for preset in RumblePreset.allCases {
            let id = "rumble_preset_\(preset.rawValue)"
            if let unavailable = unavailableReason(preset) {
                rows.append(DebugRow(id: id, section: .rumbleLab, icon: Self.icon(preset), label: L(preset.labelKey),
                    value: .info(L("debug_preset_problem")),
                    description: L("debug_preset_problem_description", Self.description(preset), unavailable), details: unavailable))
                continue
            }
            let active = activePreset == preset
            rows.append(DebugRow(id: id, section: .rumbleLab, icon: Self.icon(preset), label: L(preset.labelKey),
                value: .text(active ? L("debug_preset_active") : L("debug_preset_select")),
                description: active && problemText != nil
                    ? L("debug_preset_problem_description", Self.description(preset), problemText ?? "") : Self.description(preset)))
        }
        rows += [
            DebugRow(id: "rumble_amplitude", section: .rumbleLab, icon: Symbols.liveAmplitude, label: L("debug_live_amplitude_label", presetName),
                value: .info("\(amplitude) / 255"), description: L("debug_live_amplitude_description"),
                details: L("debug_live_amplitude_details", modeName, playingName)),
            DebugRow(id: "rumble_stop", section: .rumbleLab, icon: Symbols.stop, label: L("debug_stop_label"),
                value: .action(label: nil), description: L("debug_stop_description")),
            DebugRow(id: "rumble_test", section: .rumbleLab, icon: Symbols.replay, label: L("debug_replay_label"),
                value: .action(label: nil), description: Self.description(RumbleTestPattern.test)),
        ]
        for pattern in RumbleTestPattern.allCases where pattern != .test {
            rows.append(DebugRow(id: "rumble_pattern_\(pattern.rawValue)", section: .rumblePatterns, icon: Self.icon(pattern),
                label: Self.label(pattern), value: .action(label: nil), description: Self.description(pattern),
                details: L("debug_pattern_details", amplitude, modeName, playingName)))
        }
        rows.append(DebugRow(id: "rumble_advanced", section: .rumbleAdvanced, icon: Symbols.advanced, label: L("debug_advanced_label"),
            value: .toggle(advancedExpanded), description: L("debug_advanced_description")))
        if advancedExpanded {
            rows += [
                DebugRow(id: "rumble_enabled", section: .rumbleAdvanced, icon: Symbols.translator, label: L("debug_enabled_label"),
                    value: .toggle(translatorEnabled), description: L("debug_enabled_description")),
                sliderRow("rumble_gain", icon: Symbols.gain, label: L("debug_gain_label"), description: L("debug_gain_description")),
                sliderRow("rumble_curve", icon: Symbols.curve, label: L("debug_curve_label"), description: L("debug_curve_description", 100)),
                sliderRow("rumble_min", icon: Symbols.minAmplitude, label: L("debug_min_label"), description: L("debug_min_description")),
                sliderRow("rumble_kick", icon: Symbols.presetKick, label: L("debug_kick_label"), description: L("debug_kick_description")),
                sliderRow("rumble_low", icon: Symbols.lowWeight, label: L("debug_low_label"), description: L("debug_low_description")),
                sliderRow("rumble_high", icon: Symbols.highWeight, label: L("debug_high_label"), description: L("debug_high_description")),
                sliderRow("rumble_smoothing", icon: Symbols.smoothing, label: L("debug_smoothing_label"), description: L("debug_smoothing_description")),
                DebugRow(id: "rumble_reset", section: .rumbleAdvanced, icon: Symbols.reset, label: L("debug_reset_label"),
                    value: .action(label: nil), description: L("debug_reset_description")),
            ]
        }
        rows += padRows()
        return rows
    }

    private func sliderRow(_ id: String, section: DebugSection = .rumbleAdvanced, icon: String, label: String, value: Int? = nil,
                           description: String) -> DebugRow {
        let slider = Self.sliders[id] ?? Slider(range: 0...0, step: 1, unit: "")
        return DebugRow(id: id, section: section, icon: icon, label: label,
            value: .slider(value: value ?? sliderValue(id) ?? 0, range: slider.range, step: slider.step, divisor: 1, unit: slider.unit),
            description: description)
    }

    private func padRows() -> [DebugRow] {
        guard !pads.isEmpty else {
            return [DebugRow(id: "no_pads", section: .controllers, icon: Symbols.sportsEsports, label: L("debug_no_pads_label"),
                value: .info(""), description: L("debug_no_pads_description"))]
        }
        var rows = pads.enumerated().map { index, pad in
            // GCController exposes no USB vendor and product ids (Android shows "vvvv:pppp" and "vendor_product"): its
            // product category ("DualSense", "Xbox One", "MFi") is the closest identifier the system gives
            let ids = pad.productCategory
            let sensors = Self.sensors(pad)
            return DebugRow(id: "pad_\(index)", section: .controllers, icon: Symbols.sportsEsports, label: Self.name(pad),
                value: .text(ids),
                description: HapticTestPlayer.vibrates(pad)
                    ? L("debug_pad_description_apple_vibrates", ids, sensors) : L("debug_pad_description_apple_silent", ids, sensors),
                details: Self.details(pad))
        }
        rows.append(DebugRow(id: "pads_continuous", section: .controllers, icon: Symbols.padsContinuous, label: L("debug_pads_continuous_label"),
            value: .toggle(padsContinuous), description: L("debug_pads_continuous_description")))
        return rows
    }

    // MARK: Input

    /// A (or a tap) on row [id]; false when the id is not one of this model's rows.
    @discardableResult
    func activate(_ id: String) -> Bool {
        switch id {
        case "cap_vibrators", "cap_amplitude", "cap_problem", "rumble_preset", "rumble_amplitude", "no_pads":
            return true
        case "vibrate_once":
            stopAll()
            if hasMotor { player.vibrateDeviceOnce() } else { noMotor() }
            return true
        case "vibrate_continuous", "rumble_advanced", "pads_continuous":
            toggle(id)
            return true
        case "rumble_enabled":
            guard advancedExpanded else { return false }
            toggle(id)
            return true
        case "rumble_stop":
            stopAll()
            return true
        case "rumble_test":
            playPattern(.test, playedProfile)
            return true
        case "rumble_reset":
            guard advancedExpanded else { return false }
            updateProfile(RumbleProfile())
            return true
        default:
            if Self.sliders[id] != nil {
                guard id == "strength" || advancedExpanded else { return false }
                step(id, by: 1)
                return true
            }
            if let preset = RumblePreset.allCases.first(where: { "rumble_preset_\($0.rawValue)" == id }) {
                if unavailableReason(preset) == nil { select(preset) }
                return true
            }
            if let pattern = RumbleTestPattern.allCases.first(where: { $0 != .test && "rumble_pattern_\($0.rawValue)" == id }) {
                playPattern(pattern, playedProfile)
                return true
            }
            guard let pad = controller(id) else { return false }
            stopAll()
            if HapticTestPlayer.vibrates(pad) { player.vibrateOnce(pad) }
            else { toasts.show(L("debug_pad_no_vibration_toast", Self.name(pad)), icon: Symbols.info) }
            return true
        }
    }

    /// Left/right on a slider or toggle row; true when the value changed.
    @discardableResult
    func step(_ id: String, by direction: Int) -> Bool {
        switch id {
        case "vibrate_continuous", "rumble_advanced", "pads_continuous": return toggle(id)
        case "rumble_enabled": return advancedExpanded && toggle(id)
        default:
            guard let slider = Self.sliders[id], let value = sliderValue(id) else { return false }
            return setSlider(id, value + direction * slider.step)
        }
    }

    /// A slider set by touch.
    func slide(_ id: String, to value: Int) {
        guard let slider = Self.sliders[id] else { return }
        let lower = slider.range.lowerBound
        let snapped = lower + Int((Double(value - lower) / Double(slider.step)).rounded()) * slider.step
        setSlider(id, snapped)
    }

    /// Leaving the screen or going to the background: every pattern and continuous vibration stops.
    func stopAll() {
        stopLab()
        deviceContinuous = false
        padsContinuous = false
        player.stopDevice()
        player.stopControllers()
    }

    // MARK: Changes

    @discardableResult
    private func toggle(_ id: String) -> Bool {
        switch id {
        case "vibrate_continuous":
            let on = !deviceContinuous
            if on && !hasMotor { noMotor(); return false }
            stopAll()
            deviceContinuous = on
            if on { player.vibrateDevice(strength: strength) }
        case "pads_continuous":
            let on = !padsContinuous
            stopAll()
            padsContinuous = on
            if on { player.vibrate(pads, strength: strength) }
        case "rumble_advanced":
            advancedExpanded.toggle()
        case "rumble_enabled":
            stopLab()
            translatorEnabled.toggle()
            activePreset = nil
            save { [profile, translatorEnabled] in $0.saveCustom(profile, translator: translatorEnabled) }
        default:
            return false
        }
        return true
    }

    private func sliderValue(_ id: String) -> Int? {
        func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }
        return switch id {
        case "strength": strength
        case "rumble_gain": percent(profile.gain)
        case "rumble_curve": percent(profile.curve)
        case "rumble_min": profile.minimumAmplitude
        case "rumble_kick": Int(profile.kickMilliseconds.rounded())
        case "rumble_low": percent(profile.lowWeight)
        case "rumble_high": percent(profile.highWeight)
        case "rumble_smoothing": percent(profile.smoothing)
        default: nil
        }
    }

    /// Sets slider [id] to [value] within its range; false when it is not a slider shown now or the value stays.
    @discardableResult
    private func setSlider(_ id: String, _ value: Int) -> Bool {
        guard let slider = Self.sliders[id], let current = sliderValue(id), id == "strength" || advancedExpanded else { return false }
        let value = min(slider.range.upperBound, max(slider.range.lowerBound, value))
        guard value != current else { return false }
        var edited = profile
        switch id {
        case "strength":
            // Continuous vibration follows the strength while it runs
            strength = value
            if deviceContinuous { player.vibrateDevice(strength: value) }
            if padsContinuous { player.vibrate(pads, strength: value) }
            return true
        case "rumble_gain": edited.gain = Double(value) / 100
        case "rumble_curve": edited.curve = Double(value) / 100
        case "rumble_min": edited.minimumAmplitude = value
        case "rumble_kick": edited.kickMilliseconds = Double(value)
        case "rumble_low": edited.lowWeight = Double(value) / 100
        case "rumble_high": edited.highWeight = Double(value) / 100
        case "rumble_smoothing": edited.smoothing = Double(value) / 100
        default: return false
        }
        updateProfile(edited)
        return true
    }

    /// An advanced edit: it keeps the pulse of the selected preset and is saved as Custom (`updateProfile`).
    private func updateProfile(_ edited: RumbleProfile) {
        stopLab()
        var updated = edited
        updated.pulseMilliseconds = profile.pulseMilliseconds
        profile = updated
        activePreset = nil
        save { [translatorEnabled] in $0.saveCustom(updated, translator: translatorEnabled) }
    }

    /// Saves [preset] and plays the Test sample through it.
    private func select(_ preset: RumblePreset) {
        save { $0.applyPreset(preset) }
        profile = preset.profile
        translatorEnabled = preset.translator
        activePreset = preset
        playPattern(.test, preset.translator ? preset.profile : RumbleProfile())
    }

    /// The profile's stream settings with [change] made to the rumble; the stream and Settings read them from there.
    private func save(_ change: (inout RumbleConfiguration) -> Void) {
        var settings = store.load(profile: profileID)
        change(&settings.rumble)
        store.save(settings, profile: profileID)
    }

    /// What the patterns play through: the saved parameters while the translator is on, else Original.
    private var playedProfile: RumbleProfile { translatorEnabled ? profile : RumbleProfile() }

    // MARK: Playback

    private func playPattern(_ pattern: RumbleTestPattern, _ played: RumbleProfile) {
        stopAll()
        guard hasMotor else { noMotor(); return }
        let run = patternRun
        playing = pattern
        problem = nil
        patternTask = Task { [weak self, player] in
            await player.play(pattern, profile: played)
            self?.finished(run)
        }
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                guard let lab = self else { return }
                lab.sample()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func sample() {
        let now = player.patternAmplitude
        if amplitude != now { amplitude = now }
        if let found = player.patternProblem, problem != found { problem = found }
    }

    /// The end of pattern [run]; a cancelled older pattern never stops its replacement.
    private func finished(_ run: Int) {
        guard patternRun == run else { return }
        sample()
        stopLab()
    }

    private func stopLab() {
        patternRun += 1
        patternTask?.cancel()
        patternTask = nil
        sampler?.cancel()
        sampler = nil
        player.stopPattern()
        if playing != nil { playing = nil }
        if amplitude != 0 { amplitude = 0 }
    }

    private func noMotor() {
        toasts.show(L("debug_no_motor_toast"), icon: Symbols.info)
    }

    private func refreshPads(without gone: ObjectIdentifier?) {
        pads = GCController.controllers().filter { ObjectIdentifier($0) != gone }
        if padsContinuous { player.vibrate(pads, strength: strength) }
    }

    private func controller(_ id: String) -> GCController? {
        guard id.hasPrefix("pad_"), let index = Int(id.dropFirst(4)), pads.indices.contains(index) else { return nil }
        return pads[index]
    }

    // MARK: Texts

    /// Why [preset] cannot run here: a pulse needs amplitude control, which only a device with a haptic engine has.
    private func unavailableReason(_ preset: RumblePreset) -> String? {
        preset.profile.pulseMilliseconds > 0 && !hasMotor ? L("rumble_unavailable_no_amplitude") : nil
    }

    private func text(_ problem: RumbleProblem) -> String {
        // The technique names are Android's identities (developer text)
        let technique = playedProfile.pulseMilliseconds > 0 ? "PULSE" : "AMPLITUDE"
        return switch problem {
        case .noAmplitudeControl: L("rumble_problem_no_amplitude")
        case .singleVibratorOnly: L("rumble_problem_single_vibrator", technique)
        case let .failed(detail): L("rumble_problem_failed", technique, detail)
        }
    }

    private static func name(_ pad: GCController) -> String { pad.vendorName ?? pad.productCategory }

    private static func sensors(_ pad: GCController) -> String {
        let accelerometer = pad.motion?.hasGravityAndUserAcceleration == true
        let gyroscope = pad.motion?.hasRotationRate == true
        return switch (accelerometer, gyroscope) {
        case (true, true): L("debug_sensors_both")
        case (true, false): L("debug_sensors_accelerometer")
        case (false, true): L("debug_sensors_gyroscope")
        case (false, false): L("debug_sensors_none")
        }
    }

    /// The technical block of a controller (Android shows the input device's own description).
    private static func details(_ pad: GCController) -> String {
        let profile = pad.extendedGamepad != nil ? "extended gamepad" : pad.microGamepad != nil ? "micro gamepad" : "none"
        let localities = pad.haptics?.supportedLocalities.map(\.rawValue).sorted().joined(separator: ", ")
        var lines = [
            "vendorName: \(pad.vendorName ?? "-")",
            "productCategory: \(pad.productCategory)",
            "playerIndex: \(pad.playerIndex.rawValue)",
            "attachedToDevice: \(pad.isAttachedToDevice)",
            "profile: \(profile)",
            "haptics: \(localities ?? "none")",
        ]
        if let motion = pad.motion {
            lines.append("motion: gravity+userAcceleration \(motion.hasGravityAndUserAcceleration), rotationRate \(motion.hasRotationRate), "
                + "attitude \(motion.hasAttitude), manual activation \(motion.sensorsRequireManualActivation)")
        } else {
            lines.append("motion: none")
        }
        if let battery = pad.battery {
            lines.append("battery: \(Int((battery.batteryLevel * 100).rounded())) %, state \(battery.batteryState.rawValue)")
        }
        return lines.joined(separator: "\n")
    }

    private static func icon(_ preset: RumblePreset) -> String {
        switch preset {
        case .original: Symbols.presetOriginal
        case .soft: Symbols.presetSoft
        case .kickStart: Symbols.presetKick
        case .pulsing: Symbols.presetPulsing
        }
    }

    /// What a rumble feel does: the same sentence as its choice in Settings.
    private static func description(_ preset: RumblePreset) -> String {
        switch preset {
        case .original: L("help_list_rumble_feel_original")
        case .soft: L("help_list_rumble_feel_gentle")
        case .kickStart: L("help_list_rumble_feel_kick_only")
        case .pulsing: L("help_list_rumble_feel_pulse_25")
        }
    }

    private static func icon(_ pattern: RumbleTestPattern) -> String {
        switch pattern {
        case .test: Symbols.replay
        case .steady25: Symbols.patternSteady25
        case .steady50: Symbols.patternSteady50
        case .steady75: Symbols.patternSteady75
        case .steady100: Symbols.patternSteady100
        case .ramp: Symbols.patternRamp
        case .tap30: Symbols.patternTap30
        case .tap60: Symbols.patternTap60
        case .tap100: Symbols.patternTap100
        case .heartbeat: Symbols.patternHeartbeat
        case .explosion: Symbols.patternExplosion
        case .flutter: Symbols.patternFlutter
        }
    }

    private static func label(_ pattern: RumbleTestPattern) -> String {
        switch pattern {
        case .test: L("debug_pattern_test_label")
        case .steady25: L("debug_pattern_steady_25_label")
        case .steady50: L("debug_pattern_steady_50_label")
        case .steady75: L("debug_pattern_steady_75_label")
        case .steady100: L("debug_pattern_steady_100_label")
        case .ramp: L("debug_pattern_ramp_label")
        case .tap30: L("debug_pattern_tap_30_label")
        case .tap60: L("debug_pattern_tap_60_label")
        case .tap100: L("debug_pattern_tap_100_label")
        case .heartbeat: L("debug_pattern_heartbeat_label")
        case .explosion: L("debug_pattern_explosion_label")
        case .flutter: L("debug_pattern_flutter_label")
        }
    }

    private static func description(_ pattern: RumbleTestPattern) -> String {
        switch pattern {
        case .test: L("debug_pattern_test_description")
        case .steady25: L("debug_pattern_steady_25_description")
        case .steady50: L("debug_pattern_steady_50_description")
        case .steady75: L("debug_pattern_steady_75_description")
        case .steady100: L("debug_pattern_steady_100_description")
        case .ramp: L("debug_pattern_ramp_description")
        case .tap30: L("debug_pattern_tap_30_description")
        case .tap60: L("debug_pattern_tap_60_description")
        case .tap100: L("debug_pattern_tap_100_description")
        case .heartbeat: L("debug_pattern_heartbeat_description")
        case .explosion: L("debug_pattern_explosion_description")
        case .flutter: L("debug_pattern_flutter_description")
        }
    }
}
