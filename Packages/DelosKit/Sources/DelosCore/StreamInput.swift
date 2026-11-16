// Input sent to the host and statistics read from the core. The core queues input on its own thread, so these
// calls are cheap and safe from any thread.
import CDelosCommon

/// Why the core did not send an input event.
public enum InputError: Error, Sendable, Equatable {
    /// No stream is running.
    case notConnected
    /// The host does not support the event (for example touch on a host without the Sunshine extension).
    case unsupportedByHost
    case failed(code: Int32)

    init?(code: Int32) {
        switch code {
        case 0: return nil
        case -2: self = .notConnected
        case LI_ERR_UNSUPPORTED: self = .unsupportedByHost
        default: self = .failed(code: code)
        }
    }
}

/// Buttons of a game controller (`*_FLAG` of Limelight.h).
public struct ControllerButtons: OptionSet, Sendable, Hashable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let a = ControllerButtons(rawValue: A_FLAG)
    public static let b = ControllerButtons(rawValue: B_FLAG)
    public static let x = ControllerButtons(rawValue: X_FLAG)
    public static let y = ControllerButtons(rawValue: Y_FLAG)
    public static let up = ControllerButtons(rawValue: UP_FLAG)
    public static let down = ControllerButtons(rawValue: DOWN_FLAG)
    public static let left = ControllerButtons(rawValue: LEFT_FLAG)
    public static let right = ControllerButtons(rawValue: RIGHT_FLAG)
    public static let leftShoulder = ControllerButtons(rawValue: LB_FLAG)
    public static let rightShoulder = ControllerButtons(rawValue: RB_FLAG)
    public static let play = ControllerButtons(rawValue: PLAY_FLAG)
    public static let back = ControllerButtons(rawValue: BACK_FLAG)
    public static let leftStick = ControllerButtons(rawValue: LS_CLK_FLAG)
    public static let rightStick = ControllerButtons(rawValue: RS_CLK_FLAG)
    public static let special = ControllerButtons(rawValue: SPECIAL_FLAG)
    public static let paddle1 = ControllerButtons(rawValue: PADDLE1_FLAG)
    public static let paddle2 = ControllerButtons(rawValue: PADDLE2_FLAG)
    public static let paddle3 = ControllerButtons(rawValue: PADDLE3_FLAG)
    public static let paddle4 = ControllerButtons(rawValue: PADDLE4_FLAG)
    public static let touchpad = ControllerButtons(rawValue: TOUCHPAD_FLAG)
    public static let misc = ControllerButtons(rawValue: MISC_FLAG)
}

/// The family of a game controller, so the host can emulate a matching one (`LI_CTYPE_*`).
public enum ControllerType: UInt8, Sendable, CaseIterable {
    case unknown = 0x00
    case xbox = 0x01
    case playStation = 0x02
    case nintendo = 0x03
    case steam = 0x04
}

/// What a game controller can do (`LI_CCAP_*`).
public struct ControllerCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let analogTriggers = ControllerCapabilities(rawValue: UInt16(LI_CCAP_ANALOG_TRIGGERS))
    public static let rumble = ControllerCapabilities(rawValue: UInt16(LI_CCAP_RUMBLE))
    public static let triggerRumble = ControllerCapabilities(rawValue: UInt16(LI_CCAP_TRIGGER_RUMBLE))
    public static let touchpad = ControllerCapabilities(rawValue: UInt16(LI_CCAP_TOUCHPAD))
    public static let accelerometer = ControllerCapabilities(rawValue: UInt16(LI_CCAP_ACCEL))
    public static let gyroscope = ControllerCapabilities(rawValue: UInt16(LI_CCAP_GYRO))
    public static let batteryState = ControllerCapabilities(rawValue: UInt16(LI_CCAP_BATTERY_STATE))
    public static let rgbLED = ControllerCapabilities(rawValue: UInt16(LI_CCAP_RGB_LED))
    public static let dualTouchpad = ControllerCapabilities(rawValue: UInt16(LI_CCAP_DUAL_TOUCHPAD))
}

/// The state of one game controller for `sendController`.
public struct ControllerState: Sendable, Equatable {
    public var buttons: ControllerButtons
    public var leftTrigger: UInt8
    public var rightTrigger: UInt8
    public var leftStickX: Int16
    public var leftStickY: Int16
    public var rightStickX: Int16
    public var rightStickY: Int16

    public init(
        buttons: ControllerButtons = [], leftTrigger: UInt8 = 0, rightTrigger: UInt8 = 0,
        leftStickX: Int16 = 0, leftStickY: Int16 = 0, rightStickX: Int16 = 0, rightStickY: Int16 = 0
    ) {
        self.buttons = buttons
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.leftStickX = leftStickX
        self.leftStickY = leftStickY
        self.rightStickX = rightStickX
        self.rightStickY = rightStickY
    }
}

public enum MouseButton: Int32, Sendable, CaseIterable {
    case left = 0x01  // BUTTON_LEFT
    case middle = 0x02
    case right = 0x03
    case x1 = 0x04
    case x2 = 0x05
}

/// Modifier keys held with a key event (`MODIFIER_*`).
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int8
    public init(rawValue: Int8) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: Int8(MODIFIER_SHIFT))
    public static let control = KeyModifiers(rawValue: Int8(MODIFIER_CTRL))
    public static let alt = KeyModifiers(rawValue: Int8(MODIFIER_ALT))
    public static let meta = KeyModifiers(rawValue: Int8(MODIFIER_META))
}

/// The phase of a touch (`LI_TOUCH_EVENT_*`).
public enum TouchEventType: UInt8, Sendable, CaseIterable {
    case hover = 0x00
    case down = 0x01
    case up = 0x02
    case move = 0x03
    case cancel = 0x04
    case buttonOnly = 0x05
    case hoverLeave = 0x06
    case cancelAll = 0x07
}

/// Packet counters of a received RTP stream since the connection started.
public struct RTPStatistics: Sendable, Equatable {
    public var packets: UInt32
    public var fecPackets: UInt32
    public var fecRecovered: UInt32
    public var fecFailed: UInt32
    public var outOfSequence: UInt32
    public var invalid: UInt32
    public var fecInvalid: UInt32
}

extension StreamSession {
    private nonisolated func check(_ code: Int32) throws(InputError) {
        if let error = InputError(code: code) { throw error }
    }

    /// Announces a controller, so the host can create a matching virtual one; send before its first state.
    public nonisolated func sendControllerArrival(
        number: UInt8, activeGamepadMask: UInt16, type: ControllerType, supportedButtons: ControllerButtons,
        capabilities: ControllerCapabilities
    ) throws(InputError) {
        try check(
            LiSendControllerArrivalEvent(
                number, activeGamepadMask, type.rawValue, UInt32(bitPattern: supportedButtons.rawValue),
                capabilities.rawValue))
    }

    /// The full state of controller `number`; `activeGamepadMask` has a bit for every connected controller.
    public nonisolated func sendController(
        number: UInt8, activeGamepadMask: UInt16, state: ControllerState
    ) throws(InputError) {
        try check(
            LiSendMultiControllerEvent(
                number, activeGamepadMask, state.buttons.rawValue, state.leftTrigger, state.rightTrigger,
                state.leftStickX, state.leftStickY, state.rightStickX, state.rightStickY))
    }

    public nonisolated func sendMouseMove(deltaX: Int16, deltaY: Int16) throws(InputError) {
        try check(LiSendMouseMoveEvent(deltaX, deltaY))
    }

    /// An absolute pointer position within a reference area of `referenceWidth` × `referenceHeight`.
    public nonisolated func sendMousePosition(
        x: Int16, y: Int16, referenceWidth: Int16, referenceHeight: Int16
    ) throws(InputError) {
        try check(LiSendMousePositionEvent(x, y, referenceWidth, referenceHeight))
    }

    public nonisolated func sendMouseButton(_ button: MouseButton, pressed: Bool) throws(InputError) {
        let action = CChar(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE)
        try check(LiSendMouseButtonEvent(action, button.rawValue))
    }

    /// A key by its Windows virtual-key code. `nonNormalized` sends the code as is, without the host mapping it to
    /// the US layout.
    public nonisolated func sendKey(
        code: Int16, pressed: Bool, modifiers: KeyModifiers, nonNormalized: Bool = false
    ) throws(InputError) {
        let action = CChar(pressed ? KEY_ACTION_DOWN : KEY_ACTION_UP)
        let flags = CChar(nonNormalized ? SS_KBE_FLAG_NON_NORMALIZED : 0)
        try check(LiSendKeyboardEvent2(code, action, modifiers.rawValue, flags))
    }

    /// Text typed at once (for example from the on-screen keyboard), as UTF-8.
    public nonisolated func sendText(_ text: String) throws(InputError) {
        var text = text
        let code = text.withUTF8 { bytes in
            bytes.withMemoryRebound(to: CChar.self) { LiSendUtf8TextEvent($0.baseAddress, UInt32(bytes.count)) }
        }
        try check(code)
    }

    /// Vertical scroll in wheel notches; positive scrolls up.
    public nonisolated func sendScroll(clicks: Int8) throws(InputError) {
        try check(LiSendScrollEvent(clicks))
    }

    /// Vertical scroll in 1/120 of a notch (`WHEEL_DELTA`), for touchpads.
    public nonisolated func sendHighResolutionScroll(amount: Int16) throws(InputError) {
        try check(LiSendHighResScrollEvent(amount))
    }

    /// Horizontal scroll in wheel notches; positive scrolls right.
    public nonisolated func sendHorizontalScroll(clicks: Int8) throws(InputError) {
        try check(LiSendHScrollEvent(clicks))
    }

    public nonisolated func sendHighResolutionHorizontalScroll(amount: Int16) throws(InputError) {
        try check(LiSendHighResHScrollEvent(amount))
    }

    /// A touch on the stream, `x` and `y` normalized to 0…1 of the video. `rotation` in degrees, nil when unknown.
    public nonisolated func sendTouch(
        _ type: TouchEventType, pointerID: UInt32, x: Float, y: Float, pressureOrDistance: Float,
        contactAreaMajor: Float = 0, contactAreaMinor: Float = 0, rotation: UInt16? = nil
    ) throws(InputError) {
        try check(
            LiSendTouchEvent(
                type.rawValue, pointerID, x, y, pressureOrDistance, contactAreaMajor, contactAreaMinor,
                rotation ?? UInt16(LI_ROT_UNKNOWN)))
    }

    /// Video packet counters of the running stream.
    public nonisolated func videoStatistics() -> RTPStatistics {
        var stats = RTP_VIDEO_STATS()
        LiGetRTPVideoStats(&stats)
        return RTPStatistics(
            packets: stats.packetCountVideo, fecPackets: stats.packetCountFec,
            fecRecovered: stats.packetCountFecRecovered, fecFailed: stats.packetCountFecFailed,
            outOfSequence: stats.packetCountOOS, invalid: stats.packetCountInvalid,
            fecInvalid: stats.packetCountFecInvalid)
    }

    /// Audio packet counters of the running stream.
    public nonisolated func audioStatistics() -> RTPStatistics {
        var stats = RTP_AUDIO_STATS()
        LiGetRTPAudioStats(&stats)
        return RTPStatistics(
            packets: stats.packetCountAudio, fecPackets: stats.packetCountFec,
            fecRecovered: stats.packetCountFecRecovered, fecFailed: stats.packetCountFecFailed,
            outOfSequence: stats.packetCountOOS, invalid: stats.packetCountInvalid,
            fecInvalid: stats.packetCountFecInvalid)
    }

    /// The round-trip time to the host and its variance as the control stream measures them; nil before the
    /// first measurement.
    public nonisolated func estimatedRoundTrip() -> (rtt: Duration, variance: Duration)? {
        var rtt: UInt32 = 0
        var variance: UInt32 = 0
        guard LiGetEstimatedRttInfo(&rtt, &variance) else { return nil }
        return (.milliseconds(rtt), .milliseconds(variance))
    }
}
