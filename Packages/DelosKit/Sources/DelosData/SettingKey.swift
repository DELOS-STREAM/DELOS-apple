import Foundation

// Generated from DELOS for Android's res/xml/preferences.xml (1.2.0): every stored setting of the catalog that is not one of
// the typed fields of ``StreamSettings``, with Android's key, default and allowed values. Engines read them through
// ``StreamSettings/bool(_:)``, ``StreamSettings/int(_:)`` and ``StreamSettings/text(_:)``.

/// A stored value of a catalog setting (Android keeps the same key with a Boolean, an Int or a String).
public enum StoredSetting: Codable, Equatable, Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    case text(String)

    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var int: Int? { if case .int(let v) = self { v } else { nil } }
    public var text: String? { if case .text(let v) = self { v } else { nil } }
}

/// A setting of Settings that DELOS for Android stores under [rawValue] in the profile's preferences.
public enum SettingKey: String, CaseIterable, Codable, Sendable {
    case meteredBitrate = "seekbar_metered_bitrate_kbps"
    case asyncDecode = "checkbox_async_decode"
    case upscaler = "checkbox_sgsr"
    case upscalerMode = "list_sgsr_quality"
    case upscalerSharpness = "seekbar_sgsr_sharpness"
    case upscalerSupersampling = "list_sgsr_supersampling_level"
    case useVirtualDisplay = "checkbox_use_virtual_display"
    case enableViewTopCenter = "checkbox_enable_view_top_center"
    case resolutionScaleFactor = "seekbar_resolution_scale_factor"
    case videoScaleMode = "list_video_scale_mode"
    case vrr = "list_vrr"
    case customResolution = "edit_diy_w_h"
    case customBitrate = "edit_diy_bitrate"
    case customRefreshRate = "custom_refresh_rate"
    case enforceDisplayMode = "checkbox_enforce_display_mode"
    case externalDisplayFullscreen = "checkbox_enable_fullexdisplay"
    case audioConfiguration = "list_audio_config"
    case deadzone = "seekbar_deadzone"
    case multiController = "checkbox_multi_controller"
    case mouseEmulation = "checkbox_mouse_emulation"
    case analogScrolling = "analog_scrolling"
    case flipFaceButtons = "checkbox_flip_face_buttons"
    case gamepadTouchpadAsMouse = "checkbox_gamepad_touchpad_as_mouse"
    case gamepadMotionSensors = "checkbox_gamepad_motion_sensors"
    case gamepadMotionFallback = "checkbox_gamepad_motion_fallback"
    case forceDeviceMotion = "checkbox_force_device_motion"
    case gyroSmoothing = "seekbar_gyro_smoothing"
    case gamepadEnableBatteryReport = "checkbox_gamepad_enable_battery_report"
    case touchMode = "mouse_mode_list"
    case rememberMouseMode = "checkbox_remember_mouse_mode"
    case mouseLocalCursor = "checkbox_mouse_local_cursor"
    case multiTouchGestures = "checkbox_multi_touch_gestures"
    case mouseNavButtons = "checkbox_mouse_nav_buttons"
    case absoluteMouseMode = "checkbox_absolute_mouse_mode"
    case trackpadSensitivityX = "seekbar_trackpad_sensitivity_x"
    case trackpadSensitivityY = "seekbar_trackpad_sensitivity_y"
    case trackpadSwapAxis = "checkbox_trackpad_swap_axis"
    case rightAltAsMeta = "checkbox_right_alt_as_meta"
    case enableCommitText = "checkbox_enable_commit_text"
    case smartClipboardSync = "checkbox_smart_clipboard_sync"
    case smartClipboardSyncToast = "checkbox_smart_clipboard_sync_toast"
    case hideClipboardContent = "checkbox_hide_clipboard_content"
    case keyboardOpacity = "seekbar_keyboard_axi_opacity"
    case onscreenKeyboardAutofit = "onscreen_keyboard_autofit"
    case onscreenKeyboardHeight = "seekbar_onscreen_keyboard_height"
    case onscreenKeyboardWidth = "seekbar_onscreen_keyboard_width"
    case onscreenKeyboardAlignMode = "list_onscreen_keyboard_align_mode"
    case enableStickyModifierKeyVirtualKeyboard = "checkbox_enable_sticky_modifier_key_virtual_keyboard"
    case disableWarnings = "checkbox_disable_warnings"
    case rememberZoomPan = "checkbox_remember_zoom_pan"
    case enablePip = "checkbox_enable_pip"
    case showOnscreenControls = "checkbox_show_onscreen_controls"
    case hideOscWhenHasGamepad = "checkbox_hide_osc_when_has_gamepad"
    case vibrateOsc = "checkbox_vibrate_osc"
    case onlyShowL3R3 = "checkbox_only_show_L3R3"
    case showGuideButton = "checkbox_show_guide_button"
    case oscOpacity = "seekbar_osc_opacity"
    case freeAnalogStick = "checkbox_enable_analog_stick_new"
    case freeAnalogStickOpacity = "seekbar_osc_free_analog_stick_opacity"
    case enableClearDefaultSpecialButton = "checkbox_enable_clear_default_special_button"
    case vibrateKeyboard = "checkbox_vibrate_keyboard"
    case enableTouchSensitivity = "checkbox_enable_touch_sensitivity"
    case enableGlobalTouchSensitivity = "checkbox_enable_global_touch_sensitivity"
    case enableTouchSensitivityRotationAuto = "checkbox_enable_touch_sensitivity_rotation_auto"
    case touchSensitivityOpacityX = "seekbar_touch_sensitivity_opacity_x"
    case touchSensitivityOpacityY = "seekbar_touch_sensitivity_opacity_y"
    case touchpadSensitivityOpacity = "seekbar_touchpad_sensitivity_opacity"
    case touchpadSensitivityYOpacity = "seekbar_touchpad_sensitivity_y_opacity"
    case unlockFps = "checkbox_unlock_fps"
    case reduceRefreshRate = "checkbox_reduce_refresh_rate"
    case fullRange = "checkbox_full_range"
    case preventPacketLoss = "checkbox_prevent_packet_loss"
    /// Settings → Display → Statistics: the corner of the full statistics panel (`ui_stats_position`).
    case statsPosition = "ui_stats_position"

    /// Android's default (`android:defaultValue`; a slider without one starts at its minimum).
    public var defaultValue: StoredSetting {
        switch self {
        case .meteredBitrate: .int(0)
        case .asyncDecode: .bool(false)
        case .upscaler: .bool(false)
        case .upscalerMode: .text("standard")
        case .upscalerSharpness: .int(50)
        case .upscalerSupersampling: .text("1")
        case .useVirtualDisplay: .bool(false)
        case .enableViewTopCenter: .bool(false)
        case .resolutionScaleFactor: .int(100)
        case .videoScaleMode: .text("fit")
        case .vrr: .text("auto")
        case .customResolution: .text("1920x1080")
        case .customBitrate: .text("20")
        case .customRefreshRate: .text("59.94")
        case .enforceDisplayMode: .bool(false)
        case .externalDisplayFullscreen: .bool(false)
        case .audioConfiguration: .text("2")
        case .deadzone: .int(5)
        case .multiController: .bool(true)
        case .mouseEmulation: .bool(true)
        case .analogScrolling: .text("right")
        case .flipFaceButtons: .bool(false)
        case .gamepadTouchpadAsMouse: .bool(false)
        case .gamepadMotionSensors: .bool(true)
        case .gamepadMotionFallback: .bool(false)
        case .forceDeviceMotion: .bool(false)
        case .gyroSmoothing: .int(0)
        case .gamepadEnableBatteryReport: .bool(true)
        case .touchMode: .text("0")
        case .rememberMouseMode: .bool(false)
        case .mouseLocalCursor: .bool(false)
        case .multiTouchGestures: .bool(false)
        case .mouseNavButtons: .bool(false)
        case .absoluteMouseMode: .bool(false)
        case .trackpadSensitivityX: .int(100)
        case .trackpadSensitivityY: .int(100)
        case .trackpadSwapAxis: .bool(false)
        case .rightAltAsMeta: .bool(false)
        case .enableCommitText: .bool(false)
        case .smartClipboardSync: .bool(false)
        case .smartClipboardSyncToast: .bool(true)
        case .hideClipboardContent: .bool(true)
        case .keyboardOpacity: .int(90)
        case .onscreenKeyboardAutofit: .bool(false)
        case .onscreenKeyboardHeight: .int(200)
        case .onscreenKeyboardWidth: .int(1000)
        case .onscreenKeyboardAlignMode: .text("center")
        case .enableStickyModifierKeyVirtualKeyboard: .bool(true)
        case .disableWarnings: .bool(false)
        case .rememberZoomPan: .bool(false)
        case .enablePip: .bool(false)
        case .showOnscreenControls: .bool(false)
        case .hideOscWhenHasGamepad: .bool(true)
        case .vibrateOsc: .bool(true)
        case .onlyShowL3R3: .bool(false)
        case .showGuideButton: .bool(true)
        case .oscOpacity: .int(90)
        case .freeAnalogStick: .bool(false)
        case .freeAnalogStickOpacity: .int(20)
        case .enableClearDefaultSpecialButton: .bool(false)
        case .vibrateKeyboard: .bool(false)
        case .enableTouchSensitivity: .bool(false)
        case .enableGlobalTouchSensitivity: .bool(false)
        case .enableTouchSensitivityRotationAuto: .bool(true)
        case .touchSensitivityOpacityX: .int(100)
        case .touchSensitivityOpacityY: .int(100)
        case .touchpadSensitivityOpacity: .int(100)
        case .touchpadSensitivityYOpacity: .int(100)
        case .unlockFps: .bool(false)
        case .reduceRefreshRate: .bool(false)
        case .fullRange: .bool(false)
        case .preventPacketLoss: .bool(false)
        case .statsPosition: .text("TOP_LEFT")
        }
    }

    /// A slider's range (`seekbar:min`, `android:max`); nil for a setting that is not a slider.
    public var range: ClosedRange<Int>? {
        switch self {
        case .meteredBitrate: 0...1000000
        case .upscalerSharpness: 0...100
        case .resolutionScaleFactor: 20...200
        case .deadzone: -20...20
        case .gyroSmoothing: 0...100
        case .trackpadSensitivityX: -200...200
        case .trackpadSensitivityY: -200...200
        case .keyboardOpacity: 0...100
        case .onscreenKeyboardHeight: 150...400
        case .onscreenKeyboardWidth: 150...1000
        case .oscOpacity: 0...100
        case .freeAnalogStickOpacity: 0...100
        case .touchSensitivityOpacityX: 10...300
        case .touchSensitivityOpacityY: 10...300
        case .touchpadSensitivityOpacity: 10...300
        case .touchpadSensitivityYOpacity: 10...300
        default: nil
        }
    }

    /// The stored values a choice may have (`android:entryValues`); nil for a setting that is not a list.
    public var choices: [String]? {
        switch self {
        case .upscalerMode: ["standard", "temporal", "sharpen"]
        case .upscalerSupersampling: ["1", "2"]
        case .videoScaleMode: ["fit", "fill", "stretch"]
        case .vrr: ["auto", "on", "off"]
        case .audioConfiguration: ["2", "51", "71"]
        case .analogScrolling: ["none", "right", "left"]
        case .touchMode: ["0", "1", "2", "3", "4", "5"]
        case .onscreenKeyboardAlignMode: ["left", "center", "right"]
        case .statsPosition: ["TOP_LEFT", "TOP_RIGHT", "BOTTOM_LEFT", "BOTTOM_RIGHT"]
        default: nil
        }
    }

    /// Whether [value] may be stored for this key: the right type, a slider's value in range, a list's value among its
    /// choices.
    public func accepts(_ value: StoredSetting) -> Bool {
        switch (defaultValue, value) {
        case (.bool, .bool): return true
        case (.int, .int(let v)): return range?.contains(v) ?? true
        case (.text, .text(let v)):
            guard let choices else { return true }
            return choices.contains(v)
        default: return false
        }
    }

    /// A value of an earlier build in this build's terms: the upscaler's two retired modes become their successors
    /// (`high` MetalFX Spatial's `standard`, `temporal-quality` MetalFX Temporal's `temporal`).
    public func migrated(_ value: StoredSetting) -> StoredSetting {
        guard self == .upscalerMode, case .text(let text) = value else { return value }
        switch text {
        case "high": return .text("standard")
        case "temporal-quality": return .text("temporal")
        default: return value
        }
    }
}
