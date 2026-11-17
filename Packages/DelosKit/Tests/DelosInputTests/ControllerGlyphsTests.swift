import GameController
import Testing
@testable import DelosInput

@Suite struct ControllerGlyphsTests {
    private func pad(_ profile: PadDescriptor.Profile, _ category: String = "", _ vendor: String? = nil) -> PadDescriptor {
        PadDescriptor(profile: profile, productCategory: category, vendorName: vendor)
    }

    @Test func theGamepadClassDecidesFirst() {
        #expect(pad(.dualSense, "DualSense", "DualSense Wireless Controller").family == .dualSense)
        #expect(pad(.dualShock, "DualShock 4", "DUALSHOCK 4 Wireless Controller").family == .dualShock)
        #expect(pad(.xbox, "Xbox One", "Xbox Wireless Controller").family == .xbox)
        // A class beats a misleading name
        #expect(pad(.xbox, "HID", "Nintendo Switch Pro Controller").family == .xbox)
    }

    @Test func nintendoPadsAreFoundByName() {
        #expect(pad(.other, "HID", "Pro Controller").family == .nintendo)
        #expect(pad(.other, "HID", "Joy-Con (L/R)").family == .nintendo)
        #expect(pad(.other, "HID", "Nintendo Switch Pro Controller").family == .nintendo)
        #expect(pad(.other, "Nintendo Switch", nil).family == .nintendo)
    }

    @Test func padsWithoutAClassAreFoundByName() {
        #expect(pad(.other, "HID", "Wireless Controller DualSense").family == .dualSense)
        #expect(pad(.other, "HID", "DUALSHOCK 4").family == .dualShock)
        #expect(pad(.other, "HID", "Xbox Elite Wireless Controller").family == .xbox)
    }

    @Test func anUnknownPadIsGeneric() {
        #expect(pad(.other, "MFi", "Some Pad").family == .generic)
        #expect(pad(.other, "HID", nil).family == .generic)
    }

    @Test func theControllerUsedLastWinsOverTheFirstConnected() {
        let ps = pad(.dualSense), xbox = pad(.xbox), nintendo = pad(.other, "HID", "Pro Controller")
        #expect(ControllerGlyphs.choose(current: nil, connected: [ps, xbox]) == .dualSense)
        #expect(ControllerGlyphs.choose(current: xbox, connected: [ps, xbox]) == .xbox)
        #expect(ControllerGlyphs.choose(current: nintendo, connected: [ps, nintendo]) == .nintendo)
    }

    @Test func noControllerOrOnlyARemoteIsGeneric() {
        #expect(ControllerGlyphs.choose(current: nil, connected: []) == .generic)
        let remote = pad(.none, "Siri Remote")
        #expect(ControllerGlyphs.choose(current: remote, connected: [remote]) == .generic)
        // A remote that is current does not hide a pad
        #expect(ControllerGlyphs.choose(current: remote, connected: [remote, pad(.dualShock)]) == .dualShock)
    }

    @Test func faceButtonsFollowThePosition() {
        // The south button confirms on every layout (A = cross = B of a Nintendo pad), the east one goes back
        #expect(PadFamily.xbox.mark(.south) == .letter("A"))
        #expect(PadFamily.generic.mark(.east) == .letter("B"))
        #expect(PadFamily.dualSense.mark(.south) == .cross)
        #expect(PadFamily.dualSense.mark(.east) == .circle)
        #expect(PadFamily.dualShock.mark(.west) == .square)
        #expect(PadFamily.dualShock.mark(.north) == .triangle)
        #expect(PadFamily.nintendo.mark(.south) == .letter("B"))
        #expect(PadFamily.nintendo.mark(.east) == .letter("A"))
        #expect(PadFamily.nintendo.mark(.west) == .letter("Y"))
        #expect(PadFamily.nintendo.mark(.north) == .letter("X"))
    }

    @Test func shouldersAndMenuButtonsFollowTheFamily() {
        #expect(PadFamily.generic.mark(.leftShoulder) == .letter("L1"))
        #expect(PadFamily.dualSense.mark(.rightTrigger) == .letter("R2"))
        #expect(PadFamily.xbox.mark(.leftShoulder) == .letter("LB"))
        #expect(PadFamily.xbox.mark(.rightTrigger) == .letter("RT"))
        #expect(PadFamily.nintendo.mark(.rightShoulder) == .letter("R"))
        #expect(PadFamily.nintendo.mark(.leftTrigger) == .letter("ZL"))
        #expect(PadFamily.nintendo.mark(.menuLeft) == .letter("\u{2212}"))
        #expect(PadFamily.nintendo.mark(.menuRight) == .letter("+"))
        #expect(PadFamily.xbox.mark(.menuLeft) == .view)
        #expect(PadFamily.generic.mark(.menuRight) == .menu)
        #expect(PadFamily.dualSense.mark(.menuLeft) == .create)
        #expect(PadFamily.dualShock.mark(.menuLeft) == .create)
        #expect(PadFamily.dualSense.mark(.menuRight) == .options)
        #expect(PadFamily.dualSense.mark(.touchpad) == .touchpad)
    }

    @Test func everyFamilyMarksEveryRole() {
        for family in PadFamily.allCases {
            for role in GlyphRole.allCases { _ = family.mark(role) }
        }
        #expect(GlyphMark.cross.text == "\u{2715}")
        #expect(GlyphMark.view.text == nil)
    }

    @Test func theLastInputDecidesTheKind() {
        // Nothing used yet: the platform's default, or the controller that is connected
        #expect(InputKind.resolve(last: nil, lastOther: nil, hasController: false, fallback: .touch) == .touch)
        #expect(InputKind.resolve(last: nil, lastOther: nil, hasController: true, fallback: .touch) == .controller)
        // A touch, a key or the pointer wins over a connected controller until the controller is used again
        for kind in [InputKind.touch, .keyboard, .pointer] {
            #expect(InputKind.resolve(last: kind, lastOther: kind, hasController: true, fallback: .pointer) == kind)
        }
        #expect(InputKind.resolve(last: .controller, lastOther: .touch, hasController: true, fallback: .pointer) == .controller)
        // The controller went away: back to what was used before it, else the default
        #expect(InputKind.resolve(last: .controller, lastOther: .keyboard, hasController: false, fallback: .touch) == .keyboard)
        #expect(InputKind.resolve(last: .controller, lastOther: nil, hasController: false, fallback: .touch) == .touch)
    }

    /// What reaches ``InputKindState`` on the device, in order: the deliberate inputs and the system's notifications.
    private enum Event {
        case touch, click, key, button
        /// The left stick at (x, y), through ``MenuInput``'s threshold: only a push past it is a press.
        case stick(Float, Float)
        /// A pad connects, the system makes it the current one again, or it goes away.
        case connect, becameCurrent, disconnect
    }

    /// Plays [events] as ``ControllerGlyphs`` and ``MenuInput`` see them and returns the kind after each.
    private func kinds(_ events: [Event], padAtStart: Bool = false) -> [InputKind] {
        var state = InputKindState()
        state.controllersChanged(hasGamepad: padAtStart)
        var pad = padAtStart
        var stick: MenuCommand?
        return events.map { event in
            switch event {
            case .touch: state.used(.touch)
            case .click: state.used(.pointer)
            case .key: state.used(.keyboard)
            case .button: state.used(.controller)
            case .stick(let x, let y):
                let next = MenuInput.stickCommand(x: x, y: y, previous: stick)
                if let next, next != stick { state.used(.controller) }
                stick = next
            case .connect, .becameCurrent:
                pad = true
                state.controllersChanged(hasGamepad: pad)
            case .disconnect:
                pad = false
                state.controllersChanged(hasGamepad: pad)
            }
            return state.kind(fallback: .touch)
        }
    }

    @Test func aTouchWithAPadConnectedIsTouchUntilThePadIsUsed() {
        // R2-12: a DualSense connected, the player taps the screen; the system then says the pad is current again
        #expect(kinds([.touch, .becameCurrent, .connect], padAtStart: true) == [.touch, .touch, .touch])
        #expect(kinds([.touch, .button], padAtStart: true) == [.touch, .controller])
        #expect(kinds([.touch, .stick(0.6, 0)], padAtStart: true) == [.touch, .controller])
    }

    @Test func stickNoiseIsNoInput() {
        let noise: [Event] = [.stick(0.05, -0.02), .stick(-0.12, 0.08), .stick(0.3, 0.2), .stick(0.45, 0), .stick(0, 0)]
        #expect(kinds([.touch] + noise, padAtStart: true).allSatisfy { $0 == .touch })
        // Held past the threshold, then wobbling above the release point: one press
        #expect(kinds([.touch, .stick(0.7, 0), .touch, .stick(0.4, 0)], padAtStart: true) == [.touch, .controller, .touch, .touch])
    }

    @Test func theLastDeliberateInputWins() {
        #expect(kinds([.button, .key, .click, .touch, .button], padAtStart: true) == [.controller, .keyboard, .pointer, .touch, .controller])
    }

    @Test func aPadConnectingIsNoInputButAPadAtStartIsTheController() {
        #expect(kinds([], padAtStart: true).isEmpty)
        #expect(InputKindState().kind(fallback: .touch) == .touch)
        #expect(kinds([.connect]) == [.controller], "nothing used yet: the connected pad")
        #expect(kinds([.touch, .connect]) == [.touch, .touch])
        #expect(kinds([.key, .connect, .becameCurrent]) == [.keyboard, .keyboard, .keyboard])
    }

    @Test func thePadGoingAwayBringsBackWhatWasUsedBeforeIt() {
        #expect(kinds([.key, .button, .disconnect], padAtStart: true) == [.keyboard, .controller, .keyboard])
        #expect(kinds([.button, .disconnect], padAtStart: true) == [.controller, .touch])
        // The pad was the last input: plugged in again, it is the controller again
        #expect(kinds([.button, .disconnect, .connect], padAtStart: true) == [.controller, .touch, .controller])
    }

    @MainActor @Test func notedInputsChangeTheKindLive() {
        let glyphs = ControllerGlyphs()
        let start = glyphs.kind
        glyphs.note(.keyboard)
        #expect(glyphs.kind == .keyboard)
        glyphs.note(.touch)
        #expect(glyphs.kind == .touch)
        // A controller input with no controller connected (the test machine has none) is not a kind to show
        glyphs.note(.controller)
        #expect(glyphs.kind == (GCController.controllers().contains { $0.extendedGamepad != nil } ? .controller : .touch))
        _ = start
    }

    @Test func theSystemNamesTheMenuButtons() {
        let pad = PadDescriptor(profile: .dualSense, menuLeftSymbol: "square.and.arrow.up", menuRightSymbol: "line.3.horizontal")
        #expect(pad.menuLeftSymbol == "square.and.arrow.up")
        #expect(ControllerGlyphs.choosePad(current: nil, connected: [pad])?.menuRightSymbol == "line.3.horizontal")
    }
}
