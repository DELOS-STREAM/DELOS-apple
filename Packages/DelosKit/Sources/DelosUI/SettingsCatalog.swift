import DelosData
import Foundation

// Generated from DELOS for Android's res/xml/preferences.xml (1.2.0) and `SettingsCatalog.tabFor` / `settingIcon`: every
// row of Android's preference catalog in its order, with its tab, section, icon, title, help, kind, choices and dependency.
// Left out, with their reason in docs (N/A): checkbox_enable_audiofx, checkbox_usb_driver, checkbox_usb_bind_all,
// checkbox_enable_joyconfix, checkbox_ignore_synth_events; pref_debug_info is built by `DebugInfoSetting` (after the language row).
// A help text that names Android's own platform is replaced by the row's summary, as Android does for a row without help;
// a row whose summary names it too has no help text of its own here. The rumble rows keep their place, icon and
// dependency here; their titles and help come with the rumble settings, which build them.

/// A value of a list (`SettingChoice`): what is stored, its label and what it means (`help_<key>_<value>`).
struct CatalogChoice: Equatable, Sendable {
    let value: String
    let label: String
    var help: String? = nil
}

/// One row of the preference catalog (`SettingSpec` of DELOS for Android).
struct CatalogSpec: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A row with its own field in ``StreamSettings`` and its own builder (resolution, frame rate, bitrate, codec, ...).
        case typed
        case toggle
        case choice([CatalogChoice])
        case slider(range: ClosedRange<Int>, step: Int, divisor: Int, unit: String)
        /// A value typed into a dialog (`EditTextPreference`).
        case text
        /// Runs something; [url] opens a web page.
        case action(url: URL?)
    }

    let id: String
    let tab: SettingsTab
    /// Android's category key (`category_*`), which the touchscreen-only rule looks at.
    let category: String
    let section: String
    let icon: String
    let label: String
    let help: String?
    let kind: Kind
    /// The row whose value must be on (or not empty) for this one to be available (`android:dependency`).
    var dependency: String? = nil
    /// Hidden from Settings and its search, as Android's `PhoneOnlySettings` (the stored value still applies).
    var phoneOnly = false

    /// A slider's unit as Android writes it after the number: a word gets a space before it, a sign does not.
    static func unit(_ text: String) -> String { text.count > 1 && !text.hasPrefix(" ") ? " " + text : text }

    /// The stored setting behind the row, nil for a typed row or an action.
    var key: SettingKey? { SettingKey(rawValue: id) }
}

enum SettingsCatalog {
    /// Every row, in Android's order, in the app's language (built once: the app language does not change while it runs).
    static let all: [CatalogSpec] = [
            CatalogSpec(
                id: "list_resolution", tab: .stream, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.resolution,
                label: L("title_resolution_list"), help: L("help_list_resolution"), kind: .typed),
            CatalogSpec(
                id: "list_fps", tab: .stream, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.frameRate,
                label: L("title_fps_list"), help: L("help_list_fps"), kind: .typed),
            CatalogSpec(
                id: "seekbar_bitrate_kbps", tab: .stream, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.networkCheck,
                label: L("title_seekbar_bitrate"), help: L("help_seekbar_bitrate_kbps"), kind: .typed),
            CatalogSpec(
                id: "seekbar_metered_bitrate_kbps", tab: .stream, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.meteredNetwork,
                label: L("title_seekbar_metered_bitrate"), help: L("help_seekbar_metered_bitrate_kbps"), kind: .slider(range: 0...1000000, step: 1000, divisor: 1000, unit: CatalogSpec.unit(L("suffix_seekbar_bitrate_mbps")))),
            CatalogSpec(
                id: "frame_pacing", tab: .stream, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.framePacing,
                label: L("title_frame_pacing"), help: L("help_frame_pacing"), kind: .typed),
            CatalogSpec(
                id: "checkbox_async_decode", tab: .stream, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.asyncDecode,
                label: L("title_async_decode"), help: L("help_checkbox_async_decode"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_sgsr", tab: .display, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.upscaler,
                label: L("title_upscaler"), help: L("help_checkbox_sgsr"), kind: .toggle),
            CatalogSpec(
                id: "list_sgsr_quality", tab: .display, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.upscalerMode,
                label: L("title_sgsr_quality"), help: L("help_list_sgsr_quality"), kind: .choice([
                CatalogChoice(value: "standard", label: L("upscaler_mode_metalfx_spatial"), help: L("help_upscaler_mode_metalfx_spatial")),
                CatalogChoice(value: "temporal", label: L("upscaler_mode_metalfx_temporal"), help: L("help_upscaler_mode_metalfx_temporal")),
                CatalogChoice(value: "sharpen", label: L("sgsr_quality_sharpen"), help: L("help_list_sgsr_quality_sharpen")),
            ]), dependency: "checkbox_sgsr"),
            CatalogSpec(
                id: "seekbar_sgsr_sharpness", tab: .display, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.sharpness,
                label: L("title_sgsr_sharpness"), help: L("help_upscaler_sharpness"), kind: .slider(range: 0...100, step: 5, divisor: 1, unit: " %"), dependency: "checkbox_sgsr"),
            CatalogSpec(
                id: "list_sgsr_supersampling_level", tab: .display, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.highQuality,
                label: L("title_sgsr_supersampling_level"), help: L("help_list_sgsr_supersampling_level"), kind: .choice([
                CatalogChoice(value: "1", label: L("sgsr_supersampling_level_1"), help: L("help_list_sgsr_supersampling_level_1")),
                CatalogChoice(value: "2", label: L("sgsr_supersampling_level_2"), help: L("help_list_sgsr_supersampling_level_2")),
            ]), dependency: "checkbox_sgsr"),
            CatalogSpec(
                id: "pref_low_latency_frame_balance", tab: .stream, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.frameBalance,
                label: L("title_low_latency_frame_balance"), help: L("help_pref_low_latency_frame_balance"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_ultra_low_latency", tab: .stream, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.timer,
                label: L("title_checkbox_ultra_low_latency"), help: L("help_checkbox_ultra_low_latency"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_use_virtual_display", tab: .display, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.screenShare,
                label: L("title_checkbox_use_virtual_display"), help: L("help_checkbox_use_virtual_display"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_auto_orientation", tab: .display, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.screenRotation,
                label: L("title_auto_orientation"), help: L("help_checkbox_auto_orientation"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_auto_invert_video_resolution", tab: .display, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.axisSwap,
                label: L("title_checkbox_auto_invert_video_resolution"), help: L("help_checkbox_auto_invert_video_resolution"), kind: .toggle, dependency: "checkbox_auto_orientation"),
            CatalogSpec(
                id: "checkbox_enable_view_top_center", tab: .display, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.displayTop,
                label: L("title_top_center_display"), help: L("help_checkbox_enable_view_top_center"), kind: .toggle),
            CatalogSpec(
                id: "seekbar_resolution_scale_factor", tab: .display, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.scale,
                label: L("title_resolution_scale_factor"), help: L("help_seekbar_resolution_scale_factor"), kind: .slider(range: 20...200, step: 1, divisor: 1, unit: "%")),
            CatalogSpec(
                id: "list_video_scale_mode", tab: .display, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.scaleMode,
                label: L("title_video_scale_mode"), help: L("help_list_video_scale_mode"), kind: .choice([
                CatalogChoice(value: "fit", label: L("video_scale_mode_fit"), help: L("help_list_video_scale_mode_fit")),
                CatalogChoice(value: "fill", label: L("video_scale_mode_fill"), help: L("help_list_video_scale_mode_fill")),
                CatalogChoice(value: "stretch", label: L("video_scale_mode_stretch"), help: L("help_list_video_scale_mode_stretch")),
            ])),
            CatalogSpec(
                id: "list_vrr", tab: .display, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.customRefresh,
                label: L("title_vrr"), help: L("summary_vrr"), kind: .choice([
                CatalogChoice(value: "auto", label: L("vrr_auto"), help: L("help_list_vrr_auto")),
                CatalogChoice(value: "on", label: L("vrr_on"), help: L("help_list_vrr_on")),
                CatalogChoice(value: "off", label: L("vrr_off"), help: L("help_list_vrr_off")),
            ])),
            CatalogSpec(
                id: "edit_diy_w_h", tab: .stream, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.customResolution,
                label: L("title_custom_resolution"), help: L("help_edit_diy_w_h"), kind: .text),
            CatalogSpec(
                id: "edit_diy_bitrate", tab: .stream, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.manualBitrate,
                label: L("title_manual_enter_bitrate"), help: L("help_edit_diy_bitrate"), kind: .text),
            CatalogSpec(
                id: "custom_refresh_rate", tab: .stream, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.customRefresh,
                label: L("title_custom_refresh_rate"), help: L("help_custom_refresh_rate"), kind: .text),
            CatalogSpec(
                id: "checkbox_enforce_display_mode", tab: .display, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.displayMode,
                label: L("title_checkbox_enforce_display_mode"), help: L("summary_checkbox_enforce_display_mode"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_enable_hdr", tab: .display, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.hdrOn,
                label: L("title_enable_hdr"), help: L("help_checkbox_enable_hdr"), kind: .typed),
            CatalogSpec(
                id: "checkbox_enable_fullexdisplay", tab: .display, category: "category_video_settings", section: L("category_video_settings"), icon: Symbols.externalDisplay,
                label: L("title_fullexdisplay_mode"), help: L("help_checkbox_enable_fullexdisplay"), kind: .toggle),
            CatalogSpec(
                id: "list_audio_config", tab: .audio, category: "category_audio_settings", section: L("category_audio_settings"), icon: Symbols.surroundSound,
                label: L("title_audio_config_list"), help: L("help_list_audio_config"), kind: .choice([
                CatalogChoice(value: "2", label: L("audioconf_stereo"), help: L("help_list_audio_config_2")),
                CatalogChoice(value: "51", label: L("audioconf_51surround"), help: L("help_list_audio_config_51")),
                CatalogChoice(value: "71", label: L("audioconf_71surround"), help: L("help_list_audio_config_71")),
            ])),
            CatalogSpec(
                id: "seekbar_deadzone", tab: .controls, category: "category_gamepad_settings", section: L("category_gamepad_settings"), icon: Symbols.stickDeadzone,
                label: L("title_seekbar_deadzone"), help: L("help_seekbar_deadzone"), kind: .slider(range: -20...20, step: 1, divisor: 1, unit: CatalogSpec.unit(L("suffix_seekbar_deadzone")))),
            CatalogSpec(
                id: "checkbox_multi_controller", tab: .controls, category: "category_gamepad_settings", section: L("category_gamepad_settings"), icon: Symbols.gamepadDetect,
                label: L("title_checkbox_multi_controller"), help: L("help_checkbox_multi_controller"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_mouse_emulation", tab: .controls, category: "category_gamepad_settings", section: L("category_gamepad_settings"), icon: Symbols.mouse,
                label: L("title_checkbox_mouse_emulation"), help: L("help_checkbox_mouse_emulation"), kind: .toggle),
            CatalogSpec(
                id: "analog_scrolling", tab: .controls, category: "category_gamepad_settings", section: L("category_gamepad_settings"), icon: Symbols.analogScroll,
                label: L("title_analog_scrolling"), help: L("help_analog_scrolling"), kind: .choice([
                CatalogChoice(value: "none", label: L("analogscroll_none"), help: L("help_analog_scrolling_none")),
                CatalogChoice(value: "right", label: L("analogscroll_right"), help: L("help_analog_scrolling_right")),
                CatalogChoice(value: "left", label: L("analogscroll_left"), help: L("help_analog_scrolling_left")),
            ]), dependency: "checkbox_mouse_emulation"),
            CatalogSpec(
                id: "checkbox_flip_face_buttons", tab: .controls, category: "category_gamepad_settings", section: L("category_gamepad_settings"), icon: Symbols.gamepadButtons,
                label: L("title_checkbox_flip_face_buttons"), help: L("help_checkbox_flip_face_buttons"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_gamepad_touchpad_as_mouse", tab: .controls, category: "category_gamepad_settings", section: L("category_gamepad_settings"), icon: Symbols.touchpad,
                label: L("title_checkbox_gamepad_touchpad_as_mouse"), help: L("help_checkbox_gamepad_touchpad_as_mouse"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_gamepad_motion_sensors", tab: .controls, category: "category_gamepad_settings", section: L("category_gamepad_settings"), icon: Symbols.motionSensors,
                label: L("title_checkbox_gamepad_motion_sensors"), help: nil, kind: .toggle),
            CatalogSpec(
                id: "checkbox_gamepad_motion_fallback", tab: .controls, category: "category_gamepad_settings", section: L("category_gamepad_settings"), icon: Symbols.motionFallback,
                label: L("title_checkbox_gamepad_motion_fallback"), help: nil, kind: .toggle),
            CatalogSpec(
                id: "checkbox_force_device_motion", tab: .controls, category: "category_gamepad_settings", section: L("category_gamepad_settings"), icon: Symbols.deviceMotion,
                label: L("title_checkbox_force_device_motion"), help: L("help_checkbox_force_device_motion"), kind: .toggle, dependency: "checkbox_gamepad_motion_fallback"),
            CatalogSpec(
                id: "seekbar_gyro_smoothing", tab: .controls, category: "category_gamepad_settings", section: L("category_gamepad_settings"), icon: Symbols.smoothing,
                label: L("title_seekbar_gyro_smoothing"), help: L("help_seekbar_gyro_smoothing"), kind: .slider(range: 0...100, step: 5, divisor: 1, unit: CatalogSpec.unit(L("suffix_seekbar_gyro_smoothing")))),
            CatalogSpec(
                id: "checkbox_gamepad_enable_battery_report", tab: .controls, category: "category_gamepad_settings", section: L("category_gamepad_settings"), icon: Symbols.batteryFull,
                label: L("title_checkbox_gamepad_enable_battery_report"), help: L("help_checkbox_gamepad_enable_battery_report"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_enable_rumble", tab: .controls, category: "category_gamepad_settings", section: L("category_gamepad_settings"), icon: Symbols.vibration,
                label: "", help: nil, kind: .typed),
            CatalogSpec(
                id: "list_rumble_feel", tab: .controls, category: "category_gamepad_settings", section: L("category_gamepad_settings"), icon: Symbols.preset,
                label: "", help: nil, kind: .typed, dependency: "checkbox_enable_rumble"),
            CatalogSpec(
                id: "checkbox_vibrate_fallback", tab: .controls, category: "category_gamepad_settings", section: L("category_gamepad_settings"), icon: Symbols.deviceVibration,
                label: "", help: nil, kind: .typed, dependency: "checkbox_enable_rumble"),
            CatalogSpec(
                id: "checkbox_enable_device_rumble", tab: .controls, category: "category_gamepad_settings", section: L("category_gamepad_settings"), icon: Symbols.deviceForce,
                label: "", help: nil, kind: .typed, dependency: "checkbox_vibrate_fallback"),
            CatalogSpec(
                id: "seekbar_vibrate_fallback_strength", tab: .controls, category: "category_gamepad_settings", section: L("category_gamepad_settings"), icon: Symbols.strength,
                label: "", help: nil, kind: .typed, dependency: "checkbox_vibrate_fallback"),
            CatalogSpec(
                id: "mouse_mode_list", tab: .controls, category: "category_input_settings", section: L("category_input_settings"), icon: Symbols.touchApp,
                label: L("title_touchscreen_mode"), help: L("help_mouse_mode_list"), kind: .choice([
                CatalogChoice(value: "0", label: L("mouse_mode_multi_touch"), help: L("help_mouse_mode_list_0")),
                CatalogChoice(value: "1", label: L("mouse_mode_absolute_touch"), help: L("help_mouse_mode_list_1")),
                CatalogChoice(value: "2", label: L("mouse_mode_track_pad_natural"), help: L("help_mouse_mode_list_2")),
                CatalogChoice(value: "3", label: L("mouse_mode_track_pad_gaming"), help: L("help_mouse_mode_list_3")),
                CatalogChoice(value: "4", label: L("mouse_mode_disabled"), help: L("help_mouse_mode_list_4")),
                CatalogChoice(value: "5", label: L("mouse_mode_absolute_touch_swapped"), help: L("help_mouse_mode_list_5")),
            ]), phoneOnly: true),
            CatalogSpec(
                id: "checkbox_remember_mouse_mode", tab: .controls, category: "category_input_settings", section: L("category_input_settings"), icon: Symbols.remember,
                label: L("title_checkbox_remember_mouse_mode"), help: L("help_checkbox_remember_mouse_mode"), kind: .toggle, dependency: "checkbox_mouse_emulation", phoneOnly: true),
            CatalogSpec(
                id: "checkbox_mouse_local_cursor", tab: .controls, category: "category_input_settings", section: L("category_input_settings"), icon: Symbols.cursor,
                label: L("title_checkbox_mouse_local_cursor"), help: nil, kind: .toggle),
            CatalogSpec(
                id: "checkbox_multi_touch_gestures", tab: .controls, category: "category_input_settings", section: L("category_input_settings"), icon: Symbols.touchGestures,
                label: L("title_checkbox_multi_touch_gestures"), help: L("help_checkbox_multi_touch_gestures"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_mouse_nav_buttons", tab: .controls, category: "category_input_settings", section: L("category_input_settings"), icon: Symbols.mouseNavButtons,
                label: L("title_checkbox_mouse_nav_buttons"), help: L("help_checkbox_mouse_nav_buttons"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_absolute_mouse_mode", tab: .controls, category: "category_input_settings", section: L("category_input_settings"), icon: Symbols.absoluteMouse,
                label: L("title_checkbox_absolute_mouse_mode"), help: L("help_checkbox_absolute_mouse_mode"), kind: .toggle, phoneOnly: true),
            CatalogSpec(
                id: "seekbar_trackpad_sensitivity_x", tab: .controls, category: "category_input_settings", section: L("category_input_settings"), icon: Symbols.axisX,
                label: L("title_trackpad_sensitivity_x"), help: L("help_seekbar_trackpad_sensitivity_x"), kind: .slider(range: -200...200, step: 10, divisor: 1, unit: "%"), phoneOnly: true),
            CatalogSpec(
                id: "seekbar_trackpad_sensitivity_y", tab: .controls, category: "category_input_settings", section: L("category_input_settings"), icon: Symbols.axisY,
                label: L("title_trackpad_sensitivity_y"), help: L("help_seekbar_trackpad_sensitivity_y"), kind: .slider(range: -200...200, step: 10, divisor: 1, unit: "%"), phoneOnly: true),
            CatalogSpec(
                id: "checkbox_trackpad_drag_drop_vibration", tab: .controls, category: "category_input_settings", section: L("category_input_settings"), icon: Symbols.dragDrop,
                label: L("title_trackpad_drag_drop_vibration"), help: L("help_checkbox_trackpad_drag_drop_vibration"), kind: .toggle, phoneOnly: true),
            CatalogSpec(
                id: "seekbar_trackpad_drag_drop_threshold", tab: .controls, category: "category_input_settings", section: L("category_input_settings"), icon: Symbols.holdDuration,
                label: L("title_trackpad_drag_drop_threshold"), help: L("help_seekbar_trackpad_drag_drop_threshold"), kind: .slider(range: 0...2000, step: 1, divisor: 1, unit: " ms"), phoneOnly: true),
            CatalogSpec(
                id: "checkbox_trackpad_swap_axis", tab: .controls, category: "category_input_settings", section: L("category_input_settings"), icon: Symbols.axisSwap,
                label: L("title_trackpad_swap_axis"), help: L("help_checkbox_trackpad_swap_axis"), kind: .toggle, phoneOnly: true),
            CatalogSpec(
                id: "checkbox_force_qwerty", tab: .controls, category: "category_input_settings", section: L("category_input_settings"), icon: Symbols.forceQwerty,
                label: L("title_checkbox_force_qwerty"), help: L("help_checkbox_force_qwerty"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_right_alt_as_meta", tab: .controls, category: "category_input_settings", section: L("category_input_settings"), icon: Symbols.keyboardCommandKey,
                label: L("title_checkbox_right_alt_as_meta"), help: L("help_checkbox_right_alt_as_meta"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_enable_commit_text", tab: .controls, category: "category_input_settings", section: L("category_input_settings"), icon: Symbols.textInput,
                label: L("title_enable_commit_text"), help: L("help_checkbox_enable_commit_text"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_host_audio", tab: .audio, category: "category_host_settings", section: L("category_host_settings"), icon: Symbols.speaker,
                label: L("title_checkbox_host_audio"), help: L("help_checkbox_host_audio"), kind: .typed),
            CatalogSpec(
                id: "checkbox_smart_clipboard_sync", tab: .controls, category: "category_general_settings", section: L("category_general_settings"), icon: Symbols.clipboardSync,
                label: L("title_smart_clipboard_sync"), help: L("help_checkbox_smart_clipboard_sync"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_smart_clipboard_sync_toast", tab: .controls, category: "category_general_settings", section: L("category_general_settings"), icon: Symbols.notifications,
                label: L("title_smart_clipboard_sync_toast"), help: L("help_checkbox_smart_clipboard_sync_toast"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_hide_clipboard_content", tab: .controls, category: "category_general_settings", section: L("category_general_settings"), icon: Symbols.clipboardPrivacy,
                label: L("title_hide_clipboard_content"), help: L("summary_hide_clipboard_content"), kind: .toggle),
            CatalogSpec(
                id: "seekbar_keyboard_axi_opacity", tab: .controls, category: "category_ui_settings", section: L("category_ui_settings"), icon: Symbols.opacity,
                label: L("title_keyboard_opacity"), help: L("help_seekbar_keyboard_axi_opacity"), kind: .slider(range: 0...100, step: 1, divisor: 1, unit: "%")),
            CatalogSpec(
                id: "onscreen_keyboard_autofit", tab: .controls, category: "category_ui_settings", section: L("category_ui_settings"), icon: Symbols.fitScreen,
                label: L("title_onscreen_keyboard_autofit"), help: L("help_onscreen_keyboard_autofit"), kind: .toggle),
            CatalogSpec(
                id: "seekbar_onscreen_keyboard_height", tab: .controls, category: "category_ui_settings", section: L("category_ui_settings"), icon: Symbols.height,
                label: L("title_onscreen_keyboard_height"), help: L("help_seekbar_onscreen_keyboard_height"), kind: .slider(range: 150...400, step: 10, divisor: 1, unit: " dp"), dependency: "onscreen_keyboard_autofit"),
            CatalogSpec(
                id: "seekbar_onscreen_keyboard_width", tab: .controls, category: "category_ui_settings", section: L("category_ui_settings"), icon: Symbols.width,
                label: L("title_onscreen_keyboard_width"), help: L("help_seekbar_onscreen_keyboard_width"), kind: .slider(range: 150...1000, step: 10, divisor: 1, unit: " dp"), dependency: "onscreen_keyboard_autofit"),
            CatalogSpec(
                id: "list_onscreen_keyboard_align_mode", tab: .controls, category: "category_ui_settings", section: L("category_ui_settings"), icon: Symbols.alignment,
                label: L("title_onscreen_keyboard_align_mode"), help: L("help_list_onscreen_keyboard_align_mode"), kind: .choice([
                CatalogChoice(value: "left", label: L("align_left"), help: L("help_list_onscreen_keyboard_align_mode_left")),
                CatalogChoice(value: "center", label: L("align_center"), help: L("help_list_onscreen_keyboard_align_mode_center")),
                CatalogChoice(value: "right", label: L("align_right"), help: L("help_list_onscreen_keyboard_align_mode_right")),
            ])),
            CatalogSpec(
                id: "checkbox_enable_sticky_modifier_key_virtual_keyboard", tab: .controls, category: "category_ui_settings", section: L("category_ui_settings"), icon: Symbols.stickyKeys,
                label: L("title_checkbox_enable_sticky_modifier_key_virtual_keyboard"), help: L("help_checkbox_enable_sticky_modifier_key_virtual_keyboard"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_disable_warnings", tab: .appearance, category: "category_ui_settings", section: L("category_ui_settings"), icon: Symbols.warning,
                label: L("title_checkbox_disable_warnings"), help: L("help_checkbox_disable_warnings"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_remember_zoom_pan", tab: .appearance, category: "category_ui_settings", section: L("category_ui_settings"), icon: Symbols.remember,
                label: L("title_checkbox_remember_zoom_pan"), help: L("help_checkbox_remember_zoom_pan"), kind: .toggle, phoneOnly: true),
            CatalogSpec(
                id: "checkbox_enable_pip", tab: .appearance, category: "category_ui_settings", section: L("category_ui_settings"), icon: Symbols.pictureInPicture,
                label: L("title_checkbox_enable_pip"), help: L("help_checkbox_enable_pip"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_show_onscreen_controls", tab: .controls, category: "category_onscreen_controls", section: L("category_on_screen_controls_settings"), icon: Symbols.joystick,
                label: L("title_checkbox_show_onscreen_controls"), help: L("help_checkbox_show_onscreen_controls"), kind: .toggle, phoneOnly: true),
            CatalogSpec(
                id: "checkbox_hide_osc_when_has_gamepad", tab: .controls, category: "category_onscreen_controls", section: L("category_on_screen_controls_settings"), icon: Symbols.visibilityOff,
                label: L("title_hide_osc_when_has_gamepad"), help: L("summary_hide_osc_when_has_gamepad"), kind: .toggle, dependency: "checkbox_show_onscreen_controls", phoneOnly: true),
            CatalogSpec(
                id: "checkbox_vibrate_osc", tab: .controls, category: "category_onscreen_controls", section: L("category_on_screen_controls_settings"), icon: Symbols.oscHaptics,
                label: L("title_checkbox_vibrate_osc"), help: L("help_checkbox_vibrate_osc"), kind: .toggle, dependency: "checkbox_show_onscreen_controls", phoneOnly: true),
            CatalogSpec(
                id: "checkbox_only_show_L3R3", tab: .controls, category: "category_onscreen_controls", section: L("category_on_screen_controls_settings"), icon: Symbols.buttonL3r3,
                label: L("title_only_l3r3"), help: L("help_checkbox_only_show_L3R3"), kind: .toggle, dependency: "checkbox_show_onscreen_controls", phoneOnly: true),
            CatalogSpec(
                id: "checkbox_show_guide_button", tab: .controls, category: "category_onscreen_controls", section: L("category_on_screen_controls_settings"), icon: Symbols.guideButton,
                label: L("title_show_guide_button"), help: L("help_checkbox_show_guide_button"), kind: .toggle, dependency: "checkbox_show_onscreen_controls", phoneOnly: true),
            CatalogSpec(
                id: "seekbar_osc_opacity", tab: .controls, category: "category_onscreen_controls", section: L("category_on_screen_controls_settings"), icon: Symbols.opacity,
                label: L("dialog_title_osc_opacity"), help: L("help_seekbar_osc_opacity"), kind: .slider(range: 0...100, step: 1, divisor: 1, unit: CatalogSpec.unit(L("suffix_osc_opacity"))), dependency: "checkbox_show_onscreen_controls", phoneOnly: true),
            CatalogSpec(
                id: "checkbox_enable_analog_stick_new", tab: .controls, category: "category_onscreen_controls", section: L("category_on_screen_controls_settings"), icon: Symbols.freeStick,
                label: L("title_free_analog_stick"), help: L("help_checkbox_enable_analog_stick_new"), kind: .toggle, dependency: "checkbox_show_onscreen_controls", phoneOnly: true),
            CatalogSpec(
                id: "seekbar_osc_free_analog_stick_opacity", tab: .controls, category: "category_onscreen_controls", section: L("category_on_screen_controls_settings"), icon: Symbols.opacity,
                label: L("title_free_analog_stick_opacity"), help: L("help_seekbar_osc_free_analog_stick_opacity"), kind: .slider(range: 0...100, step: 1, divisor: 1, unit: CatalogSpec.unit(L("suffix_osc_opacity"))), dependency: "checkbox_enable_analog_stick_new", phoneOnly: true),
            CatalogSpec(
                id: "option_reset_osc_preference", tab: .controls, category: "category_onscreen_controls", section: L("category_on_screen_controls_settings"), icon: Symbols.reset,
                label: L("title_reset_osc"), help: L("help_option_reset_osc_preference"), kind: .action(url: nil), phoneOnly: true),
            CatalogSpec(
                id: "checkbox_enable_keyboard", tab: .controls, category: "category_special_key_layout", section: L("title_special_key_layout"), icon: Symbols.keyboard,
                label: L("title_show_virtual_key"), help: L("help_checkbox_enable_keyboard"), kind: .toggle, phoneOnly: true),
            CatalogSpec(
                id: "checkbox_enable_clear_default_special_button", tab: .controls, category: "category_special_key_layout", section: L("title_special_key_layout"), icon: Symbols.clearDefaults,
                label: L("title_clear_default_special_button"), help: L("help_checkbox_enable_clear_default_special_button"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_vibrate_keyboard", tab: .controls, category: "category_special_key_layout", section: L("title_special_key_layout"), icon: Symbols.keyboardHaptics,
                label: L("title_checkbox_vibrate_osc"), help: L("help_checkbox_vibrate_keyboard"), kind: .toggle),
            CatalogSpec(
                id: "keyboard_axi_list", tab: .controls, category: "category_special_key_layout", section: L("title_special_key_layout"), icon: Symbols.keyLayout,
                label: L("title_default_layout_scheme"), help: L("help_keyboard_axi_list"), kind: .choice([
                CatalogChoice(value: "OSC_Keyboard", label: L("keyboard_layout_set_1")),
                CatalogChoice(value: "OSC_Keyboard_2", label: L("keyboard_layout_set_1")),
                CatalogChoice(value: "OSC_Keyboard_3", label: L("keyboard_layout_set_1")),
                CatalogChoice(value: "OSC_Keyboard_4", label: L("keyboard_layout_set_1")),
                CatalogChoice(value: "OSC_Keyboard_5", label: L("keyboard_layout_set_1")),
            ]), dependency: "checkbox_enable_keyboard", phoneOnly: true),
            CatalogSpec(
                id: "checkbox_enable_keyboard_square", tab: .controls, category: "category_special_key_layout", section: L("title_special_key_layout"), icon: Symbols.squareButtons,
                label: L("title_square_buttons"), help: L("help_checkbox_enable_keyboard_square"), kind: .toggle, dependency: "checkbox_enable_keyboard", phoneOnly: true),
            CatalogSpec(
                id: "option_reset_osc", tab: .controls, category: "category_special_key_layout", section: L("title_special_key_layout"), icon: Symbols.reset,
                label: L("title_reset_keyboard_layout"), help: L("help_option_reset_osc"), kind: .action(url: nil), dependency: "checkbox_enable_keyboard", phoneOnly: true),
            CatalogSpec(
                id: "import_keyboard_file", tab: .controls, category: "category_special_key_layout", section: L("title_special_key_layout"), icon: Symbols.`import`,
                label: L("title_import_keyboard_layout"), help: L("summary_import_keyboard_layout"), kind: .action(url: nil), phoneOnly: true),
            CatalogSpec(
                id: "export_keyboard_file", tab: .controls, category: "category_special_key_layout", section: L("title_special_key_layout"), icon: Symbols.export,
                label: L("title_export_keyboard_layout"), help: L("help_export_keyboard_file"), kind: .action(url: nil), phoneOnly: true),
            CatalogSpec(
                id: "checkbox_enable_touch_sensitivity", tab: .controls, category: "category_virtual_trackpad_settings", section: L("title_virtual_trackpad_settings"), icon: Symbols.touchSensitivity,
                label: L("title_touch_sensitivity"), help: L("help_checkbox_enable_touch_sensitivity"), kind: .toggle, phoneOnly: true),
            CatalogSpec(
                id: "checkbox_enable_global_touch_sensitivity", tab: .controls, category: "category_virtual_trackpad_settings", section: L("title_virtual_trackpad_settings"), icon: Symbols.`public`,
                label: L("title_global_touch_sensitivity"), help: L("help_checkbox_enable_global_touch_sensitivity"), kind: .toggle, dependency: "checkbox_enable_touch_sensitivity", phoneOnly: true),
            CatalogSpec(
                id: "checkbox_enable_touch_sensitivity_rotation_auto", tab: .controls, category: "category_virtual_trackpad_settings", section: L("title_virtual_trackpad_settings"), icon: Symbols.autoSensitivity,
                label: L("title_auto_touch_sensitivity"), help: L("help_checkbox_enable_touch_sensitivity_rotation_auto"), kind: .toggle, dependency: "checkbox_enable_touch_sensitivity", phoneOnly: true),
            CatalogSpec(
                id: "seekbar_touch_sensitivity_opacity_x", tab: .controls, category: "category_virtual_trackpad_settings", section: L("title_virtual_trackpad_settings"), icon: Symbols.touchAxisX,
                label: L("title_touch_sensitivity_x"), help: L("help_seekbar_touch_sensitivity_opacity_x"), kind: .slider(range: 10...300, step: 10, divisor: 1, unit: "%"), dependency: "checkbox_enable_touch_sensitivity", phoneOnly: true),
            CatalogSpec(
                id: "seekbar_touch_sensitivity_opacity_y", tab: .controls, category: "category_virtual_trackpad_settings", section: L("title_virtual_trackpad_settings"), icon: Symbols.touchAxisY,
                label: L("title_touch_sensitivity_y"), help: L("help_seekbar_touch_sensitivity_opacity_y"), kind: .slider(range: 10...300, step: 10, divisor: 1, unit: "%"), dependency: "checkbox_enable_touch_sensitivity", phoneOnly: true),
            CatalogSpec(
                id: "seekbar_touchpad_sensitivity_opacity", tab: .controls, category: "category_virtual_trackpad_settings", section: L("title_virtual_trackpad_settings"), icon: Symbols.touchpadAxisX,
                label: L("title_touchpad_sensitivity_x"), help: L("help_seekbar_touchpad_sensitivity_opacity"), kind: .slider(range: 10...300, step: 10, divisor: 1, unit: "%"), phoneOnly: true),
            CatalogSpec(
                id: "seekbar_touchpad_sensitivity_y_opacity", tab: .controls, category: "category_virtual_trackpad_settings", section: L("title_virtual_trackpad_settings"), icon: Symbols.touchpadAxisY,
                label: L("title_touchpad_sensitivity_y"), help: L("help_seekbar_touchpad_sensitivity_y_opacity"), kind: .slider(range: 10...300, step: 10, divisor: 1, unit: "%"), phoneOnly: true),
            CatalogSpec(
                id: "checkbox_enable_perf_overlay", tab: .display, category: "category_perf_monitor_settings", section: L("category_perf_monitor_settings"), icon: Symbols.overlay,
                label: L("title_enable_perf_overlay"), help: L("help_checkbox_enable_perf_overlay"), kind: .typed),
            CatalogSpec(
                id: "checkbox_enable_perf_overlay_lite", tab: .display, category: "category_perf_monitor_settings", section: L("category_perf_monitor_settings"), icon: Symbols.overlayCompact,
                label: L("title_checkbox_enable_perf_overlay_lite"), help: L("help_checkbox_enable_perf_overlay_lite"), kind: .typed, dependency: "checkbox_enable_perf_overlay"),
            CatalogSpec(
                id: "video_format", tab: .stream, category: "category_advanced_settings", section: L("category_advanced_settings"), icon: Symbols.codec,
                label: L("title_video_format"), help: L("help_video_format"), kind: .typed),
            CatalogSpec(
                id: "list_pyrowave_chroma", tab: .stream, category: "category_advanced_settings", section: L("category_advanced_settings"), icon: Symbols.chroma,
                label: L("title_pyrowave_chroma"), help: L("help_list_pyrowave_chroma"), kind: .choice([
                CatalogChoice(value: "420", label: L("pyrowave_chroma_420"), help: L("help_list_pyrowave_chroma_420")),
                CatalogChoice(value: "444", label: L("pyrowave_chroma_444"), help: L("help_list_pyrowave_chroma_444")),
            ])),
            CatalogSpec(
                id: "checkbox_unlock_fps", tab: .stream, category: "category_advanced_settings", section: L("category_advanced_settings"), icon: Symbols.unlockFps,
                label: L("title_unlock_fps"), help: L("help_checkbox_unlock_fps"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_reduce_refresh_rate", tab: .display, category: "category_advanced_settings", section: L("category_advanced_settings"), icon: Symbols.reduceRefresh,
                label: L("title_checkbox_reduce_refresh_rate"), help: L("summary_checkbox_reduce_refresh_rate"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_full_range", tab: .display, category: "category_advanced_settings", section: L("category_advanced_settings"), icon: Symbols.fullRange,
                label: L("title_full_range"), help: L("help_checkbox_full_range"), kind: .toggle),
            CatalogSpec(
                id: "checkbox_prevent_packet_loss", tab: .stream, category: "category_advanced_settings", section: L("category_advanced_settings"), icon: Symbols.wifiKeepalive,
                label: L("title_prevent_packet_loss"), help: L("help_checkbox_prevent_packet_loss"), kind: .toggle),
            CatalogSpec(
                id: "list_languages", tab: .about, category: "category_settings_misc", section: L("title_settings_misc"), icon: Symbols.language,
                label: L("title_language_list"), help: L("help_list_languages"), kind: .typed),
            CatalogSpec(
                id: "import_special_button_file", tab: .controls, category: "category_settings_misc", section: L("title_settings_misc"), icon: Symbols.`import`,
                label: L("title_import_special_button"), help: L("help_import_special_button_file"), kind: .action(url: nil)),
            CatalogSpec(
                id: "option_help_custom_keys", tab: .controls, category: "category_settings_misc", section: L("title_settings_misc"), icon: Symbols.help,
                label: L("title_special_key_help"), help: L("help_option_help_custom_keys"), kind: .action(url: URL(string: "https://github.com/ClassicOldSong/moonlight-android/wiki/Custom-Special-Keys"))),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// The row with Android's key [id].
    static func spec(_ id: String) -> CatalogSpec? { byID[id] }
}
