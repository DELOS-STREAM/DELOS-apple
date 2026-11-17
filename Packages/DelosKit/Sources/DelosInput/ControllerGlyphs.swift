import Foundation
import GameController
import Observation

/// The family of face-button labels a controller shows: what its hints are drawn with. DELOS for Android labels every pad
/// like an Xbox pad (`Glyph.A`, `Glyph.B`, ... in `shell/ui/Bars.kt`); Apple's controllers are told apart by
/// ``PadDescriptor``, and ``generic`` (no controller, or an unknown one) is Android's set.
public enum PadFamily: Sendable, Hashable, CaseIterable {
    case generic, xbox, dualSense, dualShock, nintendo
}

/// A button's place on a pad, named by its position, not its label: the same action sits at the same place on every
/// layout (confirm is always the south button, `KEYCODE_BUTTON_A` of Android and `buttonA` of GameController), and only
/// the glyph drawn for the place changes.
public enum GlyphRole: Sendable, Hashable, CaseIterable {
    /// A, cross, B of a Nintendo pad: confirm.
    case south
    /// B, circle, A of a Nintendo pad: back.
    case east
    /// X, square, Y of a Nintendo pad: the context menu.
    case west
    /// Y, triangle, X of a Nintendo pad: the toast's action, the filters.
    case north
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case leftStick, rightStick
    /// The left menu button: View, Create, Share, -.
    case menuLeft
    /// The right menu button: Menu, Options, +.
    case menuRight
    case touchpad
}

/// What a glyph shows.
public enum GlyphMark: Sendable, Hashable {
    case letter(String)
    case cross, circle, square, triangle
    /// Two overlapping windows: View, Create, Share (`Glyph.MENU_LEFT` of Android).
    case view
    /// Three lines: Menu, Options (`Glyph.MENU_RIGHT` of Android).
    case menu
    case touchpad

    /// The mark as text, for a sentence ("B cancels"); nil for the icons.
    public var text: String? {
        switch self {
        case .letter(let text): text
        case .cross: "\u{2715}"
        case .circle: "\u{25CB}"
        case .square: "\u{25A1}"
        case .triangle: "\u{25B3}"
        case .view, .menu, .touchpad: nil
        }
    }
}

extension PadFamily {
    /// The mark of the button at [role] on this family's pads.
    public func mark(_ role: GlyphRole) -> GlyphMark {
        switch role {
        case .south: face(xbox: "A", playStation: .cross, nintendo: "B")
        case .east: face(xbox: "B", playStation: .circle, nintendo: "A")
        case .west: face(xbox: "X", playStation: .square, nintendo: "Y")
        case .north: face(xbox: "Y", playStation: .triangle, nintendo: "X")
        case .leftShoulder: shoulder(xbox: "LB", nintendo: "L", "L1")
        case .rightShoulder: shoulder(xbox: "RB", nintendo: "R", "R1")
        case .leftTrigger: shoulder(xbox: "LT", nintendo: "ZL", "L2")
        case .rightTrigger: shoulder(xbox: "RT", nintendo: "ZR", "R2")
        case .leftStick: .letter("L3")
        case .rightStick: .letter("R3")
        case .menuLeft: self == .nintendo ? .letter("\u{2212}") : .view
        case .menuRight: self == .nintendo ? .letter("+") : .menu
        case .touchpad: .touchpad
        }
    }

    private func face(xbox: String, playStation: GlyphMark, nintendo: String) -> GlyphMark {
        switch self {
        case .generic, .xbox: .letter(xbox)
        case .dualSense, .dualShock: playStation
        case .nintendo: .letter(nintendo)
        }
    }

    private func shoulder(xbox: String, nintendo: String, _ other: String) -> GlyphMark {
        switch self {
        case .xbox: .letter(xbox)
        case .nintendo: .letter(nintendo)
        case .generic, .dualSense, .dualShock: .letter(other)
        }
    }
}

/// What GameController says about a controller, as far as the glyphs need it (a value, so tests can fake controllers).
public struct PadDescriptor: Sendable, Hashable {
    /// The class of the controller's extended gamepad.
    public enum Profile: Sendable, Hashable { case dualSense, dualShock, xbox, other, none }

    public var profile: Profile
    public var productCategory: String
    public var vendorName: String?

    public init(profile: Profile, productCategory: String = "", vendorName: String? = nil) {
        self.profile = profile
        self.productCategory = productCategory
        self.vendorName = vendorName
    }

    public init(_ controller: GCController) {
        let profile: Profile = switch controller.extendedGamepad {
        case is GCDualSenseGamepad: .dualSense
        case is GCDualShockGamepad: .dualShock
        case is GCXboxGamepad: .xbox
        case .some: .other
        case .none: .none
        }
        self.init(profile: profile, productCategory: controller.productCategory, vendorName: controller.vendorName)
    }

    /// The glyph family: the class of the gamepad first (the system knows DualSense, DualShock and Xbox pads by it), then
    /// the product category and vendor name (a Switch Pro or Joy-Con is an HID pad with a name; a PlayStation or Xbox pad
    /// through a driver that gives no class too).
    public var family: PadFamily {
        switch profile {
        case .dualSense: return .dualSense
        case .dualShock: return .dualShock
        case .xbox: return .xbox
        case .other, .none: break
        }
        let name = "\(productCategory) \(vendorName ?? "")".lowercased()
        func has(_ words: [String]) -> Bool { words.contains { name.contains($0) } }
        if has(["dualsense"]) { return .dualSense }
        if has(["dualshock", "ds4", "playstation"]) { return .dualShock }
        if has(["nintendo", "switch", "joy-con", "joycon", "pro controller"]) { return .nintendo }
        if has(["xbox"]) { return .xbox }
        return .generic
    }

    /// Whether this is a pad with face buttons to press (not a remote, a keyboard or a mouse).
    var isGamepad: Bool { profile != .none }
}

/// The glyph family in use: the controller used last, else the first one connected, else ``PadFamily/generic``. It is
/// evaluated again when a controller connects or disconnects and when another one becomes the current one (the system
/// moves `GCController.current` to whichever was used last). Every hint of the interface reads it, so one change redraws
/// them all.
@MainActor
@Observable
public final class ControllerGlyphs {
    public static let shared = ControllerGlyphs()

    public private(set) var family = PadFamily.generic
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {}

    /// The family for the controller used last ([current]) and the ones connected, in the order the system lists them.
    nonisolated public static func choose(current: PadDescriptor?, connected: [PadDescriptor]) -> PadFamily {
        if let current, current.isGamepad { return current.family }
        return connected.first(where: \.isGamepad)?.family ?? .generic
    }

    /// Starts following the controllers; calling it again does nothing.
    public func start() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [
            .GCControllerDidConnect, .GCControllerDidDisconnect, .GCControllerDidBecomeCurrent, .GCControllerDidStopBeingCurrent,
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    private func refresh() {
        let connected = GCController.controllers().filter { $0.extendedGamepad != nil }.map(PadDescriptor.init)
        let next = Self.choose(current: GCController.current.map(PadDescriptor.init), connected: connected)
        if next != family { family = next }
    }

    public func mark(_ role: GlyphRole) -> GlyphMark { family.mark(role) }
}
