// The pointer input of the touch modes, the Apple Pencil and the local cursor: pen events and the relative motion that the
// core turns into absolute positions (`absoluteMouseMode`). Queued by the core like the rest of the input.
import CDelosCommon

/// The tool of a pen event (`LI_TOOL_TYPE_*`).
public enum PenTool: UInt8, Sendable, CaseIterable {
    case unknown = 0x00
    case pen = 0x01
    case eraser = 0x02
}

/// The buttons of a pen (`LI_PEN_BUTTON_*`).
public struct PenButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let primary = PenButtons(rawValue: UInt8(LI_PEN_BUTTON_PRIMARY))
    public static let secondary = PenButtons(rawValue: UInt8(LI_PEN_BUTTON_SECONDARY))
    public static let tertiary = PenButtons(rawValue: UInt8(LI_PEN_BUTTON_TERTIARY))
}

extension StreamSession {
    /// A pen on the stream (`LiSendPenEvent`), `x` and `y` normalized to 0…1 of the video, `pressureOrDistance` 0…1 (the
    /// distance for hover events). `rotation` in degrees (nil: unknown), `tilt` in degrees from vertical 0…90 (nil:
    /// unknown). Throws ``InputError/unsupportedByHost`` when the host takes no pen events.
    public nonisolated func sendPen(
        _ type: TouchEventType, tool: PenTool, buttons: PenButtons, x: Float, y: Float, pressureOrDistance: Float,
        contactAreaMajor: Float, contactAreaMinor: Float, rotation: UInt16?, tilt: UInt8?
    ) throws(InputError) {
        let code = LiSendPenEvent(
            type.rawValue, tool.rawValue, buttons.rawValue, x, y, pressureOrDistance, contactAreaMajor, contactAreaMinor,
            rotation ?? UInt16(LI_ROT_UNKNOWN), tilt ?? UInt8(LI_TILT_UNKNOWN))
        if let error = InputError(code: code) { throw error }
    }

    /// Relative mouse motion that the core adds to the position it keeps and sends as an absolute position within a
    /// reference area of `referenceWidth` × `referenceHeight` (`LiSendMouseMoveAsMousePositionEvent`).
    public nonisolated func sendMouseMoveAsMousePosition(
        deltaX: Int16, deltaY: Int16, referenceWidth: Int16, referenceHeight: Int16
    ) throws(InputError) {
        if let error = InputError(code: LiSendMouseMoveAsMousePositionEvent(deltaX, deltaY, referenceWidth, referenceHeight)) {
            throw error
        }
    }
}
