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
    case dpad, guide
}

/// What a glyph shows.
public enum GlyphMark: Sendable, Hashable {
    case letter(String)
    case cross, circle, square, triangle
    /// Two overlapping windows: the Xbox View button (`Glyph.MENU_LEFT` of Android).
    case view
    /// Three lines: the Xbox Menu button (`Glyph.MENU_RIGHT` of Android).
    case menu
    /// The PlayStation Create (DualSense) or Share (DualShock) button.
    case create
    /// The PlayStation Options button.
    case options
    case touchpad
    case dpad, guide

    /// The mark as text, for a sentence ("B cancels"); nil for the icons.
    public var text: String? {
        switch self {
        case .letter(let text): text
        case .cross: "\u{2715}"
        case .circle: "\u{25CB}"
        case .square: "\u{25A1}"
        case .triangle: "\u{25B3}"
        case .view, .menu, .create, .options, .touchpad, .dpad, .guide: nil
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
        case .menuLeft:
            switch self {
            case .nintendo: .letter("\u{2212}")
            case .dualSense, .dualShock: .create
            case .generic, .xbox: .view
            }
        case .menuRight:
            switch self {
            case .nintendo: .letter("+")
            case .dualSense, .dualShock: .options
            case .generic, .xbox: .menu
            }
        case .touchpad: .touchpad
        case .dpad: .dpad
        case .guide: .guide
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

/// The kind of input the player used last: what the hints are drawn for.
public enum InputKind: Sendable, Hashable, CaseIterable {
    case controller, keyboard, pointer, touch

    /// What a device without any input yet is taken to use: touch on iPhone and iPad, the pointer on a Mac, the controller
    /// (the Siri Remote has the same buttons) on Apple TV.
    public static var platformDefault: InputKind {
        #if os(tvOS)
        .controller
        #elseif os(macOS)
        .pointer
        #else
        .touch
        #endif
    }

    /// The kind the hints are drawn for. [last]: the kind of the last input (nil: none yet); [lastOther]: the kind of the
    /// last input that was not a controller's (what comes back when the controller goes away); [hasController]: a gamepad
    /// is connected. The last input wins, except that a controller that is gone cannot be the answer.
    public static func resolve(last: InputKind?, lastOther: InputKind?, hasController: Bool, fallback: InputKind = platformDefault) -> InputKind {
        switch last {
        case .controller?, nil:
            if hasController { return .controller }
            return lastOther ?? fallback
        case let kind?: return kind
        }
    }
}

/// What the input kind is made of: the last deliberate input and whether a gamepad is connected. Only a deliberate input
/// changes the last one (``used(_:)``: a touch begins, a button is pressed, the stick passes ``MenuInput``'s threshold, a
/// key is pressed, the pointer moves or clicks). A controller connecting, disconnecting or becoming the system's current
/// one is no input (``controllersChanged(hasGamepad:)``): the system posts those on its own (the app becoming active, a
/// pad waking up), and a touch followed by one of them must still be a touch.
public struct InputKindState: Sendable, Equatable {
    /// The kind of the last deliberate input; nil: none yet.
    public private(set) var last: InputKind?
    /// The kind of the last deliberate input that was not a controller's.
    public private(set) var lastOther: InputKind?
    /// A gamepad is connected.
    public private(set) var hasController = false

    public init() {}

    /// The player used [input] on purpose.
    public mutating func used(_ input: InputKind) {
        last = input
        if input != .controller { lastOther = input }
    }

    /// The controllers that are connected changed, or the system made another one the current one.
    public mutating func controllersChanged(hasGamepad: Bool) {
        hasController = hasGamepad
    }

    /// The kind the hints are drawn for (``InputKind/resolve(last:lastOther:hasController:fallback:)``).
    public func kind(fallback: InputKind = .platformDefault) -> InputKind {
        InputKind.resolve(last: last, lastOther: lastOther, hasController: hasController, fallback: fallback)
    }
}

/// The glyph source of the interface: the kind of input used last (``InputKind``, kept by ``InputKindState``) and, for a
/// controller, the glyph family (``PadFamily``) of the controller used last, else the first one connected, else
/// ``PadFamily/generic``. The family is evaluated again when a controller connects, disconnects or becomes the current one
/// (the system moves `GCController.current` to whichever was used last); the kind changes only when the interface notes a
/// deliberate input (``note(_:)``: a touch, a key, the pointer, a controller's button or stick), or when the last
/// controller goes away. Every hint of the interface reads it, so one change redraws them all.
@MainActor
@Observable
public final class ControllerGlyphs {
    public static let shared = ControllerGlyphs()

    public private(set) var family = PadFamily.generic
    public private(set) var kind = InputKind.platformDefault
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var state = InputKindState()
    #if DEBUG
    /// The demo harness pretends a gamepad is connected (`-DelosDemoInput controller`).
    @ObservationIgnored private var debugPad = false
    #endif

    init() {}

    /// The family for the controller used last ([current]) and the ones connected, in the order the system lists them.
    nonisolated public static func choose(current: PadDescriptor?, connected: [PadDescriptor]) -> PadFamily {
        choosePad(current: current, connected: connected)?.family ?? .generic
    }

    nonisolated static func choosePad(current: PadDescriptor?, connected: [PadDescriptor]) -> PadDescriptor? {
        if let current, current.isGamepad { return current }
        return connected.first(where: \.isGamepad)
    }

    /// Starts following the controllers; calling it again does nothing.
    public func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // Only the family and whether a pad is there: none of these is an input. The system posts them on its own (a
        // pad that wakes up or reconnects, the app becoming active), and a touch they follow must stay a touch
        let names: [Notification.Name] = [
            .GCControllerDidConnect, .GCControllerDidBecomeCurrent, .GCControllerDidDisconnect, .GCControllerDidStopBeingCurrent,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    #if DEBUG
    /// The demo harness (`-DelosDemoInput`): [kind] is the input from now on, and for a controller a gamepad counts as
    /// connected (the simulator has none), so a later touch or key still switches away from it.
    public func debugForce(_ kind: InputKind) {
        debugPad = kind == .controller
        state.controllersChanged(hasGamepad: debugPad || state.hasController)
        state.used(kind)
        evaluate()
    }
    #endif

    /// The player used [input] on purpose: the hints show it from now on.
    public func note(_ input: InputKind) {
        state.used(input)
        evaluate()
    }

    private func refresh() {
        let connected = GCController.controllers().filter { $0.extendedGamepad != nil }.map(PadDescriptor.init)
        let pad = Self.choosePad(current: GCController.current.map(PadDescriptor.init), connected: connected)
        #if DEBUG
        let hasGamepad = pad != nil || debugPad
        #else
        let hasGamepad = pad != nil
        #endif
        state.controllersChanged(hasGamepad: hasGamepad)
        let next = pad?.family ?? .generic
        if next != family { family = next }
        evaluate()
    }

    private func evaluate() {
        let next = state.kind()
        if next != kind { kind = next }
    }

    public func mark(_ role: GlyphRole) -> GlyphMark { family.mark(role) }
}
