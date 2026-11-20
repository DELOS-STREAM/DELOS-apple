import DelosData
import DelosMedia
import Foundation
import Testing
@testable import DelosUI

/// The settings catalog against DELOS for Android 1.2.0's `res/xml/preferences.xml` and `nativeSettings`.
@Suite struct SettingsCatalogTests {
    /// Every key of Android's preferences.xml, in its order.
    static let androidXMLKeys = """
        list_resolution list_fps seekbar_bitrate_kbps seekbar_metered_bitrate_kbps frame_pacing checkbox_async_decode checkbox_sgsr \
        list_sgsr_quality seekbar_sgsr_sharpness list_sgsr_supersampling_level pref_low_latency_frame_balance checkbox_ultra_low_latency \
        checkbox_use_virtual_display checkbox_auto_orientation checkbox_auto_invert_video_resolution checkbox_enable_view_top_center \
        seekbar_resolution_scale_factor list_video_scale_mode list_vrr edit_diy_w_h edit_diy_bitrate custom_refresh_rate \
        checkbox_enforce_display_mode checkbox_enable_hdr checkbox_enable_fullexdisplay list_audio_config checkbox_enable_audiofx \
        seekbar_deadzone checkbox_multi_controller checkbox_usb_driver checkbox_usb_bind_all checkbox_mouse_emulation analog_scrolling \
        checkbox_flip_face_buttons checkbox_gamepad_touchpad_as_mouse checkbox_gamepad_motion_sensors checkbox_gamepad_motion_fallback \
        checkbox_force_device_motion seekbar_gyro_smoothing checkbox_enable_joyconfix checkbox_gamepad_enable_battery_report \
        checkbox_enable_rumble list_rumble_feel checkbox_vibrate_fallback checkbox_enable_device_rumble seekbar_vibrate_fallback_strength \
        mouse_mode_list checkbox_remember_mouse_mode checkbox_mouse_local_cursor checkbox_multi_touch_gestures checkbox_mouse_nav_buttons \
        checkbox_absolute_mouse_mode seekbar_trackpad_sensitivity_x seekbar_trackpad_sensitivity_y checkbox_trackpad_drag_drop_vibration \
        seekbar_trackpad_drag_drop_threshold checkbox_trackpad_swap_axis checkbox_force_qwerty checkbox_right_alt_as_meta \
        checkbox_ignore_synth_events checkbox_enable_commit_text checkbox_host_audio checkbox_smart_clipboard_sync \
        checkbox_smart_clipboard_sync_toast checkbox_hide_clipboard_content seekbar_keyboard_axi_opacity onscreen_keyboard_autofit \
        seekbar_onscreen_keyboard_height seekbar_onscreen_keyboard_width list_onscreen_keyboard_align_mode \
        checkbox_enable_sticky_modifier_key_virtual_keyboard checkbox_disable_warnings checkbox_remember_zoom_pan checkbox_enable_pip \
        checkbox_show_onscreen_controls checkbox_hide_osc_when_has_gamepad checkbox_vibrate_osc checkbox_only_show_L3R3 \
        checkbox_show_guide_button seekbar_osc_opacity checkbox_enable_analog_stick_new seekbar_osc_free_analog_stick_opacity \
        option_reset_osc_preference checkbox_enable_keyboard checkbox_enable_clear_default_special_button checkbox_vibrate_keyboard \
        keyboard_axi_list checkbox_enable_keyboard_square option_reset_osc import_keyboard_file export_keyboard_file \
        checkbox_enable_touch_sensitivity checkbox_enable_global_touch_sensitivity checkbox_enable_touch_sensitivity_rotation_auto \
        seekbar_touch_sensitivity_opacity_x seekbar_touch_sensitivity_opacity_y seekbar_touchpad_sensitivity_opacity \
        seekbar_touchpad_sensitivity_y_opacity checkbox_enable_perf_overlay checkbox_enable_perf_overlay_lite video_format \
        list_pyrowave_chroma checkbox_unlock_fps checkbox_reduce_refresh_rate checkbox_full_range checkbox_prevent_packet_loss \
        list_languages import_special_button_file option_help_custom_keys pref_debug_info
        """.split(separator: " ").map(String.init)

    /// Android rows with no counterpart (the N/A list of the parity inventory), and the debug screen of issue #71.
    static let notApplicable: Set<String> = [
        "checkbox_enable_audiofx", "checkbox_usb_driver", "checkbox_usb_bind_all", "checkbox_enable_joyconfix",
        "checkbox_ignore_synth_events", "pref_debug_info",
    ]

    /// Android rows DELOS for Apple removed: no meaning on Apple (landscape only, no PyroWave 4:4:4, layout-independent
    /// HID keys, no drag-and-drop haptics, MediaCodec-only decoder options), or the on-screen virtual keys that are not
    /// ported yet.
    static let removedOnApple: Set<String> = [
        "pref_low_latency_frame_balance", "checkbox_ultra_low_latency",
        "checkbox_auto_orientation", "checkbox_auto_invert_video_resolution", "list_pyrowave_chroma",
        "checkbox_trackpad_drag_drop_vibration", "seekbar_trackpad_drag_drop_threshold", "checkbox_force_qwerty",
        "checkbox_enable_keyboard", "keyboard_axi_list", "checkbox_enable_keyboard_square", "option_reset_osc",
        "import_keyboard_file", "export_keyboard_file",
    ]

    @Test func everyAndroidKeyIsInTheCatalogInAndroidsOrder() {
        let expected = Self.androidXMLKeys.filter { !Self.notApplicable.contains($0) && !Self.removedOnApple.contains($0) }
        #expect(SettingsCatalog.all.map(\.id) == expected)
        #expect(Self.removedOnApple.allSatisfy { SettingKey(rawValue: $0) == nil })
    }

    @Test func everyStoredKeyHasAndroidsDefault() {
        let defaults: [SettingKey: StoredSetting] = [
            .meteredBitrate: .int(0), .asyncDecode: .bool(false), .upscaler: .bool(false), .upscalerMode: .text("standard"),
            .upscalerSharpness: .int(50), .upscalerSupersampling: .text("1"),
            .resolutionScaleFactor: .int(100), .videoScaleMode: .text("fit"), .vrr: .text("auto"),
            .customResolution: .text("1920x1080"), .customBitrate: .text("20"), .customRefreshRate: .text("59.94"),
            .audioConfiguration: .text("2"), .deadzone: .int(5), .multiController: .bool(true), .mouseEmulation: .bool(true),
            .analogScrolling: .text("right"), .gamepadMotionSensors: .bool(true), .gyroSmoothing: .int(0),
            .gamepadEnableBatteryReport: .bool(true), .touchMode: .text("0"),
            .smartClipboardSyncToast: .bool(true), .hideClipboardContent: .bool(true), .keyboardOpacity: .int(90),
            .onscreenKeyboardHeight: .int(200), .onscreenKeyboardWidth: .int(1000), .onscreenKeyboardAlignMode: .text("center"),
            .enableStickyModifierKeyVirtualKeyboard: .bool(true), .oscOpacity: .int(90),
            .statsPosition: .text("TOP_LEFT"), .freeAnalogStickOpacity: .int(20),
        ]
        for (key, value) in defaults { #expect(key.defaultValue == value, "\(key.rawValue)") }
        #expect(SettingKey.deadzone.range == -20...20)
        #expect(SettingKey.resolutionScaleFactor.range == 20...200)
        #expect(SettingKey.meteredBitrate.range == 0...1_000_000)
    }

    @Test func tabsAreAndroidsAndTheDisplayTabHasHDR() {
        #expect(SettingsTab.allCases == [.stream, .display, .audio, .controls, .appearance, .covers, .devices, .about])
        #expect(SettingsCatalog.all.first { $0.id == "checkbox_enable_hdr" }?.tab == .display)
        let display = SettingsCatalog.all.filter { $0.tab == .display }.map(\.id)
        #expect(display == [
            "checkbox_sgsr", "list_sgsr_quality", "seekbar_sgsr_sharpness", "list_sgsr_supersampling_level",
            "checkbox_use_virtual_display",
            "checkbox_enable_view_top_center", "seekbar_resolution_scale_factor", "list_video_scale_mode", "list_vrr",
            "checkbox_enforce_display_mode", "checkbox_enable_hdr", "checkbox_enable_fullexdisplay",
            "checkbox_enable_perf_overlay", "checkbox_enable_perf_overlay_lite", "checkbox_reduce_refresh_rate", "checkbox_full_range",
        ])
    }

    @Test func everyRowHasATitleAndATextThatExists() {
        let rumble: Set = ["checkbox_enable_rumble", "list_rumble_feel", "checkbox_vibrate_fallback", "checkbox_enable_device_rumble",
                           "seekbar_vibrate_fallback_strength"]
        for spec in SettingsCatalog.all where !rumble.contains(spec.id) {
            #expect(!spec.label.isEmpty && !spec.label.hasPrefix("title_"), "\(spec.id)")
            #expect(!spec.section.hasPrefix("category_"), "\(spec.id)")
            #expect(spec.help.map { !$0.hasPrefix("help_") && !$0.contains("Android") } ?? true, "\(spec.id)")
        }
        // The rows whose Android help and summary both name Android have none
        #expect(SettingsCatalog.all.filter { $0.help == nil && !rumble.contains($0.id) }.map(\.id).sorted()
            == ["checkbox_gamepad_motion_fallback", "checkbox_gamepad_motion_sensors", "checkbox_mouse_local_cursor"])
    }

    @Test func storedValuesAreReadLeniently() throws {
        let json = #"{"values":{"seekbar_deadzone":{"int":{"_0":99}},"list_vrr":{"text":{"_0":"sometimes"}},"unknown":{"bool":{"_0":true}},"checkbox_unlock_fps":{"bool":{"_0":true}}},"codec":"pyrowave"}"#
        let s = try JSONDecoder().decode(StreamSettings.self, from: Data(json.utf8))
        #expect(s.int(.deadzone) == 20)
        #expect(s.text(.vrr) == "auto")
        #expect(s.bool(.unlockFps))
        #expect(s.values.count == 2)
        #expect(s.codec == .pyroWave)
        var round = StreamSettings()
        round.set(.vrr, .text("on"))
        round.set(.vrr, .bool(true))
        #expect(try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(round)).text(.vrr) == "on")
    }

    @Test func pyroWaveRecommendsVibepollosBitrate() {
        #expect(PyroWaveBitrate.recommendedKbps(width: 1920, height: 1080, fps: 60, hdr: false) == 225_000)
        #expect(PyroWaveBitrate.recommendedKbps(width: 1280, height: 720, fps: 60, hdr: false) == 140_000)
        #expect(PyroWaveBitrate.recommendedKbps(width: 1920, height: 1080, fps: 60, hdr: true) == 265_000)
    }

    @Test func eachCodecKeepsItsBitrate() {
        let display = StreamResolution(width: 1920, height: 1080)
        var s = StreamSettings(resolution: display, fps: 60, bitrateKbps: 50_000)
        s.changeCodec(to: .hevc, displayResolution: display)
        #expect(s.bitrateKbps == 50_000 && s.codecBitrates["auto"] == 50_000)
        s.bitrateKbps = 80_000
        s.changeCodec(to: .pyroWave, displayResolution: display)
        #expect(s.bitrateKbps == 225_000 && s.codecBitrates["forceh265"] == 80_000)
        s.changeCodec(to: .hevc, displayResolution: display)
        #expect(s.bitrateKbps == 80_000)
        s.changeCodec(to: .automatic, displayResolution: display)
        #expect(s.bitrateKbps == 50_000)
    }
}

@Suite struct SettingsCatalogFormTests {
    let phone = StreamDevice(
        pixelWidth: 2796, pixelHeight: 1290, maxFramesPerSecond: 120, decodable: [.h264, .hevc], safePixelWidth: 2556,
        safePixelHeight: 1290, touchscreen: true, deviceMotion: true, haptics: true, pictureInPicture: true)
    let mac = StreamDevice(pixelWidth: 3024, pixelHeight: 1964, maxFramesPerSecond: 120, decodable: [.h264, .hevc])

    @Test func theStreamTabFollowsAndroid() {
        let form = StreamSettingsForm(settings: StreamSettings(), device: phone)
        #expect(form.rows(.stream).map(\.id) == [
            "list_resolution", "list_fps", "seekbar_bitrate_kbps", "seekbar_metered_bitrate_kbps", "frame_pacing",
            "checkbox_async_decode", "edit_diy_w_h", "edit_diy_bitrate",
            "custom_refresh_rate", "video_format", "checkbox_unlock_fps", "checkbox_prevent_packet_loss",
        ])
        #expect(form.rows(.stream).first { $0.id == "edit_diy_w_h" }?.value == .text("1920x1080"))
    }

    @Test func hardwareHidesItsRows() {
        let phoneIDs = Set(StreamSettingsForm(settings: StreamSettings(), device: phone).rows(.controls).map(\.id))
        let macIDs = Set(StreamSettingsForm(settings: StreamSettings(), device: mac).rows(.controls).map(\.id))
        #expect(phoneIDs.isSuperset(of: ["checkbox_gamepad_motion_fallback", "seekbar_osc_opacity", "checkbox_vibrate_keyboard"]))
        #expect(macIDs.isDisjoint(with: ["checkbox_gamepad_motion_fallback", "checkbox_force_device_motion", "seekbar_osc_opacity",
                                         "checkbox_vibrate_keyboard", "checkbox_enable_clear_default_special_button"]))
        // Phone-only rows never show
        #expect(phoneIDs.isDisjoint(with: ["mouse_mode_list", "checkbox_show_onscreen_controls", "checkbox_absolute_mouse_mode"]))
        #expect(macIDs.contains("seekbar_gyro_smoothing") && macIDs.contains("checkbox_gamepad_motion_sensors"))
    }

    @Test func dependenciesDimTheirRows() {
        var settings = StreamSettings()
        func enabled(_ id: String, _ settings: StreamSettings) -> Bool? {
            StreamSettingsForm(settings: settings, device: phone).catalogRow(id)?.enabled
        }
        #expect(enabled("analog_scrolling", settings) == true)
        settings.set(.mouseEmulation, .bool(false))
        #expect(enabled("analog_scrolling", settings) == false)
        #expect(enabled("list_sgsr_quality", settings) == false)
        settings.set(.upscaler, .bool(true))
        #expect(enabled("list_sgsr_quality", settings) == true)
        settings.set(.upscalerMode, .text("sharpen"))
        #expect(enabled("list_sgsr_supersampling_level", settings) == false)
        settings.set(.gamepadMotionSensors, .bool(false))
        #expect(enabled("seekbar_gyro_smoothing", settings) == false)
    }

    @Test func theTextRowsCheckWhatIsTyped() {
        var form = StreamSettingsForm(settings: StreamSettings(), device: phone)
        #expect(form.setText("edit_diy_w_h", "19x") == "Use width x height, for example 1920x1080")
        #expect(form.setText("edit_diy_w_h", " 3000X1500 ") == nil)
        #expect(form.resolutionOptions.last?.label == "Custom (3000x1500)")
        #expect(form.setText("custom_refresh_rate", "0") == "Enter a frame rate above 0 and up to 1000")
        #expect(form.setText("custom_refresh_rate", "47.950") == nil)
        #expect(form.settings.text(.customRefreshRate) == "47.95")
        #expect(form.frameRateOptions.last?.label == "Custom (47.95 FPS)")
        #expect(form.setText("edit_diy_bitrate", "12.5") == nil)
        #expect(form.settings.bitrateKbps == 12_500)
    }

    @Test func unlockingTheFrameRateOffersEveryPreset() {
        let slow = StreamDevice(pixelWidth: 1920, pixelHeight: 1080, maxFramesPerSecond: 60, decodable: .h264)
        var form = StreamSettingsForm(settings: StreamSettings(), device: slow)
        #expect(!form.frameRateOptions.map(\.value.fps).contains(120))
        form.step("checkbox_unlock_fps", by: 1)
        #expect(form.frameRateOptions.map(\.value.fps).contains(120))
    }

    @Test func theFramePacingIsAndroidsWithoutFastVSync() {
        var settings = StreamSettings()
        #expect(StreamSettingsForm(settings: settings, device: phone).framePacingOptions.map(\.value)
            == [.warp2, .warp, .phaseLock, .balanced, .capFPS, .smoothness])
        // Without a PyroWave decoder the codec is not offered and a stored one goes back to Automatic
        settings.codec = .pyroWave
        #expect(StreamSettingsForm(settings: settings, device: phone).settings.codec == .automatic)
    }

    @Test func aFractionalCustomRateIsItsOwnChoiceAndLaunchesExactly() throws {
        var form = StreamSettingsForm(settings: StreamSettings(), device: phone)
        #expect(form.setText("custom_refresh_rate", "59.94") == nil)
        let labels = form.frameRateOptions.map(\.label)
        let custom = try #require(labels.firstIndex(of: "Custom (59.94 FPS)"))
        let preset = try #require(form.frameRateOptions.firstIndex { $0.value == .preset(60) })
        form.pick("list_fps", option: custom)
        #expect(form.settings.fps == 60 && form.settings.customFrameRateChosen)
        #expect(form.catalogRow("list_fps")?.value == .choice(label: "Custom (59.94 FPS)", options: labels, selected: custom))
        #expect(form.settings.launchFrameRate(refreshRate: 120) == 59.94)
        form.pick("list_fps", option: preset)
        #expect(form.settings.fps == 60 && !form.settings.customFrameRateChosen)
        #expect(form.settings.launchFrameRate(refreshRate: 120) == 60)
        // A whole custom rate is the preset it equals, not a second choice
        #expect(form.setText("custom_refresh_rate", "60") == nil)
        #expect(form.frameRateOptions.filter { $0.value.fps == 60 }.count == 1)
    }

    @Test func theNotchGivesFullscreenResolutions() {
        let labels = StreamSettingsForm(settings: StreamSettings(), device: phone).resolutionOptions.map(\.label)
        #expect(labels.contains("Native (2556x1290)"))
        #expect(labels.contains("Native fullscreen (2796x1290)"))
    }

    @Test func theStatisticsOverlayIsTwoSwitches() {
        var form = StreamSettingsForm(settings: StreamSettings(), device: mac)
        #expect(form.catalogRow("checkbox_enable_perf_overlay_lite")?.enabled == false)
        form.step("checkbox_enable_perf_overlay", by: 1)
        #expect(form.settings.statisticsOverlay == .full)
        form.step("checkbox_enable_perf_overlay_lite", by: 1)
        #expect(form.settings.statisticsOverlay == .compact)
        form.step("ui_stats_position", by: 1)
        #expect(form.settings.statsPosition == .topRight)
    }

    @Test func upscalerRowsCarryImpactChips() {
        let form = StreamSettingsForm(settings: StreamSettings(), device: phone)
        #expect(form.catalogRow("checkbox_sgsr")?.impact == .quiet)
    }

    @Test func gyroSmoothingSaysOffAtZero() {
        #expect(StreamSettingsForm(settings: StreamSettings(), device: phone).catalogRow("seekbar_gyro_smoothing")?.sliderMinText == "0 % (off)")
    }
}

@Suite struct SettingsShellRowsTests {
    @Test func theDefaultPCAndSkippingTheStartScreen() {
        var setting = StartupSetting(startup: Startup(), pcs: [("b", "Beta"), ("a", "alpha")])
        let rows = setting.rows(.devices)
        #expect(rows.map(\.id) == ["ui_default_pc", "ui_skip_start"])
        #expect(rows[0].value == .choice(label: "None", options: ["None", "alpha", "Beta"], selected: 0))
        #expect(!rows[1].enabled)
        #expect(setting.steppedDefault(by: 1) == "a")
        setting.startup = Startup(defaultPC: "a", skipStart: true)
        #expect(setting.rows(.devices)[1].enabled)
        var startup = setting.startup
        startup.defaultPC = nil
        #expect(!startup.skipStart)
        #expect(!StartupSetting(startup: Startup(), pcs: []).rows(.devices)[0].enabled)
    }

    @Test func aboutStartsWithTheVersion() {
        let rows = AboutSetting.rows(.about, version: "1.2.0")
        #expect(rows.map(\.id) == ["about_version", "about_based", "about_welcome", "about_diag_logs"])
        #expect(rows[0].value == .info("1.2.0") && rows[0].help == "DELOS 1.2.0")
    }

    @Test func rowsAreGroupedBySection() {
        func row(_ id: String, _ section: String) -> SettingRow {
            SettingRow(id: id, tab: .stream, section: section, icon: "", label: id, value: .toggle(true), help: "")
        }
        #expect([row("a", "1"), row("b", "2"), row("c", "1")].groupedBySection().map(\.id) == ["a", "c", "b"])
    }

    @Test func materialYouFollowsTheSystemColor() {
        let form = AppearanceForm(appearance: Appearance(), offersMaterialYou: true, systemHue: 210)
        #expect(form.rows(.appearance).map(\.id).prefix(3) == ["ui_dark", "ui_material_you", "ui_palette"])
        var on = Appearance()
        on.materialYou = true
        let rows = AppearanceForm(appearance: on, offersMaterialYou: true, systemHue: 210).rows(.appearance)
        #expect(rows.first { $0.id == "ui_palette" }?.enabled == false)
        #expect(rows.first { $0.id == "ui_match_game_colors" }?.enabled == false)
        let colors = DelosColors(palette: .delos, dark: true, materialYou: true, systemHue: 210)
        #expect(colors.accentHue == 210 && colors.accent2Hue == 262 && colors.accent == hsl(210, 78, 72))
        #expect(DelosColors(palette: .delos, dark: true, materialYou: true).accentHue == 150)
        #expect(AppearanceForm(appearance: Appearance()).rows(.appearance).map(\.id).contains("ui_material_you") == false)
    }

    @Test func customKeysNeedTheirData() throws {
        let suite = "delos.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let keys = CustomSpecialKeys(suiteName: suite)
        #expect(throws: CustomSpecialKeys.ImportError.noShortcutData) { try keys.importFile(Data(#"{"x":1}"#.utf8), profile: "p") }
        #expect(throws: CustomSpecialKeys.ImportError.invalid) { try keys.importFile(Data("no".utf8), profile: "p") }
        #expect(throws: CustomSpecialKeys.ImportError.tooLarge) { try keys.importFile(Data(count: 1_048_577), profile: "p") }
        try keys.importFile(Data(#"{"data":[]}"#.utf8), profile: "p")
        #expect(keys.load(profile: "p") == #"{"data":[]}"#)
    }
}
