#if os(macOS)
import CoreGraphics
import DelosInput
import Testing
@testable import DelosUI

/// A tap or a click on an item and what the iPad's window probe makes of it (#15, #16): a finger's first tap on a cover only
/// focuses it, a finger's tap never opens a context menu, the pointer's click activates at once.
@MainActor
@Suite struct ItemTouchTests {
    private let circle = CGRect(x: 600, y: 400, width: 300, height: 300)

    /// A tap as the window's probe sees it (`InputKindProbe`): the touch begins (``TouchKindRecognizer`` notes a finger or
    /// the pointer), then the tap recognizer of the secondary button recognizes it when it may take the touch and the
    /// button matches. UIKit checks that button mask on indirect input only (UITapGestureRecognizer.h): a finger's tap
    /// always matches. Returns the kind the item's tap then reads, and whether the secondary click fired (it notes the
    /// pointer too).
    private func probe(_ kinds: inout InputKindState, indirect: Bool, secondaryButton: Bool = false) -> (kind: InputKind, secondaryClick: Bool) {
        kinds.used(indirect ? .pointer : .touch)
        let secondaryClick = ItemTouch.takesSecondaryClick(indirect: indirect) && (!indirect || secondaryButton)
        if secondaryClick { kinds.used(.pointer) }
        return (kinds.kind(), secondaryClick)
    }

    @Test func aFingersFirstTapOnACoverOnlyFocusesItTheSecondStartsIt() {
        var kinds = InputKindState()
        // The trackpad was used before: a finger's tap is still a touch when it lands (the secondary click took it and
        // noted the pointer, so the first tap started the game)
        kinds.used(.pointer)
        let first = probe(&kinds, indirect: false)
        #expect(first.kind == .touch)
        #expect(ItemTouch.of(focused: false, kind: first.kind, ownTap: false, firstTapFocuses: true) == .focusOnly)
        let second = probe(&kinds, indirect: false)
        #expect(ItemTouch.of(focused: true, kind: second.kind, ownTap: false, firstTapFocuses: true) == .activate)
        // A settings row's own tap is told the same; an item without the rule (a PC's circle, the top navigation) acts at once
        #expect(ItemTouch.of(focused: false, kind: .touch, ownTap: true, firstTapFocuses: false) == .own(wasFocused: false))
        #expect(ItemTouch.of(focused: true, kind: .touch, ownTap: true, firstTapFocuses: false) == .own(wasFocused: true))
        #expect(ItemTouch.of(focused: false, kind: .touch, ownTap: false, firstTapFocuses: false) == .activate)
    }

    @Test func thePointersClickStillActivatesAtOnce() {
        var kinds = InputKindState()
        kinds.used(.touch)
        let click = probe(&kinds, indirect: true)
        #expect(!click.secondaryClick)
        #expect(click.kind == .pointer)
        // Its hover focused the item; a click is never only the first tap that focuses, even where the hover did not land
        #expect(ItemTouch.of(focused: false, kind: click.kind, ownTap: false, firstTapFocuses: true) == .activate)
        #expect(ItemTouch.of(focused: true, kind: click.kind, ownTap: false, firstTapFocuses: true) == .activate)
        #expect(ItemTouch.of(focused: false, kind: click.kind, ownTap: true, firstTapFocuses: false) == .own(wasFocused: true))
    }

    @Test func aTouchNeverOpensTheContextMenuOnlyALongPressOrASecondaryClickDoes() async {
        let fx = ShellFixtureLite()
        let focus = fx.navigator.focus
        let menu = ContextMenu(title: "Meiton-PC", items: [MenuItem(icon: "a", label: "Rename") {}])
        focus.register("pc", frame: circle, menu: { menu }) {}
        focus.register("pair", frame: circle.offsetBy(dx: 400, dy: 0)) {}
        focus.focus("pair")
        var kinds = InputKindState()
        // Finger taps on the PC's circle: none is a secondary click, so none reaches the router's context menu
        for _ in 0..<3 {
            let tap = probe(&kinds, indirect: false)
            #expect(!tap.secondaryClick)
            #expect(tap.kind == .touch)
        }
        #expect(!fx.layers.isOpen)
        // The pointer's primary click neither
        #expect(!probe(&kinds, indirect: true).secondaryClick)
        // A right click or the trackpad's two-finger click (the secondary button of an indirect pointer) opens it
        let secondary = probe(&kinds, indirect: true, secondaryButton: true)
        #expect(secondary.secondaryClick)
        #expect(await fx.router.secondaryClick(at: CGPoint(x: circle.midX, y: circle.midY)))
        #expect(focus.focused == AnyHashable("pc"))
        #expect(fx.layers.isOpen)
        // A finger opens it only by holding the item, far longer than a tap
        #expect(ItemTouch.menuHold >= 0.5)
    }
}
#endif
