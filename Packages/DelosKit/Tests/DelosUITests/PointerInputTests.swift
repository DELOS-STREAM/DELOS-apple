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
        #expect(fx.router.pointerTarget(at: center(cover)) == cover)
        fx.layers.openDialog(DialogSpec(title: "t", note: "n", fields: [], confirm: "ok") { _ in true })
        #expect(fx.router.pointerFocus === fx.layers.focus)
        // The pointer shows over the screen's cover behind the dialog: it is no item of the dialog's
        #expect(fx.router.pointerTarget(at: center(cover)) == nil)
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
        #expect(fx.router.pointerTarget(at: center(cover)) == nil)
        #expect(!(await fx.router.secondaryClick(at: center(cover))))
        #expect(!fx.layers.isOpen)
    }

    @Test func thePressSqueezesTo096AndPulsesTheGlow() {
        #expect(Motion.pressScale == 0.96)
        #expect(focusGlow(50, pressed: false) == 50)
        #expect(focusGlow(50, pressed: true) == 50 * Motion.pressGlow)
        #expect(Motion.pressGlow > 1)
    }
}
#endif
