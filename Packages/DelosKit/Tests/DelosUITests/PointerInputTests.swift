#if os(macOS)
import DelosInput
import Foundation
import Testing
@testable import DelosUI

/// The pointer (Magic Keyboard's trackpad, a mouse) in the shell (#16): the item under it, the hover that focuses, the right
/// click that opens the item's context menu, and who has the pointer while a layer, the portal or a stream is up.
@MainActor
@Suite struct PointerInputTests {
    private let menu = ContextMenu(title: "Hades", items: [MenuItem(icon: "a", label: "Settings") {}])
    private let cover = CGRect(x: 100, y: 400, width: 200, height: 300)
    private let tab = CGRect(x: 100, y: 40, width: 120, height: 50)

    private func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    @Test func thePointerHitsTheSmallestItemUnderIt() {
        let frames = ["row": CGRect(x: 0, y: 0, width: 400, height: 100), "chip": CGRect(x: 10, y: 10, width: 50, height: 30)]
        #expect(FocusGeometry.item(at: CGPoint(x: 20, y: 20), candidates: frames) == "chip")
        #expect(FocusGeometry.item(at: CGPoint(x: 200, y: 50), candidates: frames) == "row")
        #expect(FocusGeometry.item(at: CGPoint(x: 500, y: 50), candidates: frames) == nil)
        // Two of the same size: the smaller id, whatever order the dictionary hands them out
        let twins = ["b": CGRect(x: 0, y: 0, width: 10, height: 10), "a": CGRect(x: 0, y: 0, width: 10, height: 10)]
        #expect(FocusGeometry.item(at: CGPoint(x: 5, y: 5), candidates: twins) == "a")
    }

    @Test func theModelTellsTheItemUnderThePointerAndWhetherItHasAMenu() {
        let model = FocusModel(initial: "tab")
        model.register("tab", frame: tab) {}
        model.register("cover", frame: cover, menu: { menu }) {}
        #expect(model.item(at: center(cover))?.id == AnyHashable("cover"))
        #expect(model.item(at: center(cover))?.frame == cover)
        #expect(model.item(at: .zero) == nil)
        #expect(model.hasMenu("cover"))
        #expect(!model.hasMenu("tab"))
    }

    @Test func onlyAMoveOfThePointerFocusesNotContentScrollingUnderIt() {
        let hover = PointerHover()
        #expect(hover.moved(to: CGPoint(x: 10, y: 10)))
        // The row glided under the pointer at rest: the next item reports the same point
        #expect(!hover.moved(to: CGPoint(x: 10, y: 10)))
        #expect(!hover.moved(to: CGPoint(x: 10.2, y: 10)))
        #expect(hover.moved(to: CGPoint(x: 14, y: 10)))
    }

    @Test func aSweepOverTheCoversPlaysAFewMoveCuesNotAStorm() {
        let hover = PointerHover()
        let start = Date()
        #expect(hover.cues(at: start))
        #expect(!hover.cues(at: start + PointerHover.cueGap / 2))
        #expect(hover.cues(at: start + PointerHover.cueGap))
    }

    @Test func aSecondaryClickFocusesTheItemUnderThePointerAndOpensItsMenu() async {
        let fx = ShellFixtureLite()
        let focus = fx.navigator.focus
        focus.register("tab", frame: tab) {}
        focus.register("cover", frame: cover, menu: { menu }) {}
        focus.focus("tab")
        #expect(await fx.router.secondaryClick(at: center(cover)))
        #expect(focus.focused == AnyHashable("cover"))
        // The cover is under the pointer: the menu opens at once, and nothing scrolls the cover away first
        #expect(focus.pointerMoved)
        #expect(fx.layers.isOpen)
        // Beside the open menu's rows, a secondary click is the button that opened it: it closes
        #expect(await fx.router.secondaryClick(at: CGPoint(x: 5000, y: 5000)))
        #expect(!fx.layers.isOpen)
    }

    @Test func aSecondaryClickOnAnItemWithoutAMenuOnlyFocusesIt() async {
        let fx = ShellFixtureLite()
        let focus = fx.navigator.focus
        focus.register("tab", frame: tab) {}
        focus.register("cover", frame: cover, menu: { menu }) {}
        focus.focus("cover")
        #expect(await fx.router.secondaryClick(at: center(tab)))
        #expect(focus.focused == AnyHashable("tab"))
        #expect(!fx.layers.isOpen)
        // Over nothing, with nothing open: nothing happens
        #expect(!(await fx.router.secondaryClick(at: CGPoint(x: 5000, y: 5000))))
        #expect(focus.focused == AnyHashable("tab"))
    }

    @Test func anOpenLayerOrTheSideMenuHasThePointerNotTheScreenBehind() {
        let fx = ShellFixtureLite()
        let screen = fx.navigator.focus
        screen.register("cover", frame: cover, menu: { menu }) {}
        #expect(fx.router.pointerFocus === screen)
        #expect(fx.router.pointerFocus?.item(at: center(cover))?.frame == cover)
        fx.layers.openDialog(DialogSpec(title: "t", note: "n", fields: [], confirm: "ok") { _ in true })
        #expect(fx.router.pointerFocus === fx.layers.focus)
        // The pointer shows over the screen's cover behind the dialog: it is no item of the dialog's
        #expect(fx.router.pointerFocus?.item(at: center(cover)) == nil)
        fx.layers.close()
        fx.router.openSideMenu()
        #expect(fx.router.pointerFocus === fx.router.sideMenu)
    }

    @Test func theStreamKeepsThePointerAsThePCsMouse() async {
        let fx = ShellFixtureLite()
        fx.navigator.reset(to: .stream(hostID: ShellFixture.hostID, appID: 10))
        let focus = fx.navigator.focus
        focus.register("cover", frame: cover, menu: { menu }) {}
        #expect(fx.router.pointerFocus == nil)
        #expect(!(await fx.router.secondaryClick(at: center(cover))))
        #expect(!fx.layers.isOpen)
    }

    // MARK: Hover focus never requests a scroll

    @Test func theHoversFocusAsksNoScrollViewToFollowIt() {
        let model = FocusModel(initial: "a")
        model.register("a", frame: CGRect(x: 0, y: 0, width: 80, height: 100)) {}
        model.register("b", frame: CGRect(x: 100, y: 0, width: 80, height: 100)) {}
        #expect(!model.pointerMoved)
        model.point(to: "b")
        #expect(model.focused == AnyHashable("b"))
        #expect(model.pointerMoved)
        // The pointer over the item that has the focus moves nothing: the last move stays the pointer's
        model.point(to: "b")
        #expect(model.pointerMoved)
        // An arrow or a screen's own move of the focus is followed again
        model.handle(.left)
        #expect(model.focused == AnyHashable("a"))
        #expect(!model.pointerMoved)
        model.point(to: "b")
        model.focus("a")
        #expect(!model.pointerMoved)
    }

    @Test func theLibraryRowStaysWhereItIsForEveryHover() {
        let row = LibraryRow(count: 8)
        // A sweep of the pointer over the covers, then over the last and back to the first (the arrows' wrap)
        for index in [1, 2, 3, 7, 0] {
            row.point(at: index)
        }
        #expect(row.targets == Array(repeating: .stay, count: 5))
        // The next arrow is followed from the hovered cover
        row.handle(.right)
        #expect(row.targets.last == .follow(to: 1))
    }

    @Test func noStepOfThePointerScrollsTheRowEvenAtItsEnds() {
        for (old, new) in [(0, 7), (7, 0), (3, 4), (nil, 5)] as [(Int?, Int)] {
            #expect(LibraryScroll.step(from: old, to: new, count: 8, byPointer: true) == .stay)
        }
        #expect(LibraryScroll.step(from: 0, to: 7, count: 8, byPointer: false) == .wrap)
        #expect(LibraryScroll.step(from: 3, to: 4, count: 8, byPointer: false) == .follow(to: 4))
    }

    @Test func thePlayersOwnScrollStopsTheGlideTheProgramsDoesNot() {
        #expect(ScrollGlide.isPlayers(.tracking))
        #expect(ScrollGlide.isPlayers(.interacting))
        #expect(ScrollGlide.isPlayers(.decelerating))
        #expect(!ScrollGlide.isPlayers(.animating))
        #expect(!ScrollGlide.isPlayers(.idle))
    }

    @Test func thePressSqueezesTo096AndPulsesTheGlow() {
        #expect(Motion.pressScale == 0.96)
        #expect(focusGlow(50, pressed: false) == 50)
        #expect(focusGlow(50, pressed: true) == 50 * Motion.pressGlow)
        #expect(Motion.pressGlow > 1)
        // The press is the shared one (`pressLook`, 0.96) around every item; an element's own look drops its focus lift
        // meanwhile, so a pressed element stands at 0.96 of its size at rest, below every focus scale
        #expect(focusScale(focused: true, pressed: false, focus: 1.055) == 1.055)
        #expect(focusScale(focused: true, pressed: true, focus: 1.055) == 1)
        #expect(focusScale(focused: false, pressed: false, focus: 1.055) == 1)
        // Seen in full: squeezed in, held, and only then the action of a tap or a click
        #expect(Motion.press == 120)
        #expect(Motion.pressHold == 130)
    }

    @Test func theLightHoverIsSubtlerThanAnyFocus() {
        // Tier 2 (no ring): a soft brighten and a slight lift, below every focus scale of the interface (the chips' 1.05)
        #expect(Motion.hoverTint == 0.08)
        #expect(Motion.hoverScale == 1.03)
        #expect(Motion.hoverScale > 1 && Motion.hoverScale < 1.05)
        #expect(Motion.ringIn == 140 && Motion.ringOut == 110)
    }
}
#endif
