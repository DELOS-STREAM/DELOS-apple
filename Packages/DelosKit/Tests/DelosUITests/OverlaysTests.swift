import CoreGraphics
import DelosInput
import Testing
@testable import DelosUI

/// The context menu's placement and submenus (`ContextMenuPlacementTest` of DELOS for Android).
@Suite struct ContextMenuPlacementTests {
    typealias L = ContextMenuLayout
    let reach = ContextMenuLayout.tipGap + ContextMenuLayout.caretDepth
    let stageW = 1920.0, stageH = 1080.0

    @Test func aTileOnTheLeftGetsTheCardOnItsRightWithTheCaretOnTheCardsLeftPointingAtIt() {
        let tile = CGRect(x: 125, y: 300, width: 300, height: 450)
        let p = placeContextMenu(anchor: tile, w: 560, h: 400, below: false, stageW: stageW, stageH: stageH)
        #expect(p.side == .left)
        #expect(p.x == tile.maxX + reach)
        #expect(p.y == Double(tile.midY) - 200)
        #expect(p.caret == 200)
        #expect(p.tipX == p.x - L.caretDepth)
        #expect(p.tipY == Double(tile.midY))
    }

    @Test func aTileTooFarRightFlipsTheCardToItsLeft() {
        let tile = CGRect(x: 1500, y: 300, width: 300, height: 450)
        let p = placeContextMenu(anchor: tile, w: 600, h: 400, below: false, stageW: stageW, stageH: stageH)
        #expect(p.side == .right)
        #expect(p.x == tile.minX - reach - 600)
        #expect(p.tipX == p.x + 600 + L.caretDepth)
    }

    @Test func theCardStaysInsideTheVerticalMarginsAndTheCaretKeepsPointingAtTheTile() {
        let high = placeContextMenu(anchor: CGRect(x: 125, y: 0, width: 300, height: 100), w: 560, h: 400, below: false, stageW: stageW, stageH: stageH)
        #expect(high.y == L.marginY)
        #expect(high.caret == L.caretInset)
        let low = placeContextMenu(anchor: CGRect(x: 125, y: 900, width: 300, height: 150), w: 560, h: 400, below: false, stageW: stageW, stageH: stageH)
        #expect(low.y == 1080 - L.marginY - 400)
        #expect(low.caret == 400 - L.caretInset)
    }

    @Test func theCaretNeverLeavesTheCardsCorners() {
        #expect(caretAlong(-50, length: 400) == L.caretInset)
        #expect(caretAlong(900, length: 400) == 400 - L.caretInset)
        #expect(caretAlong(250, length: 400) == 250)
        // A card shorter than both insets keeps the caret at the first inset instead of inverting the range
        #expect(caretAlong(10, length: 100) == L.caretInset)
    }

    @Test func aMenuThatBelongsToAnElementOpensBelowItCenteredWithTheCaretOnTop() {
        let pc = CGRect(x: 800, y: 300, width: 200, height: 200)
        let p = placeContextMenu(anchor: pc, w: 500, h: 300, below: true, stageW: stageW, stageH: stageH)
        #expect(p.side == .top)
        #expect(p.x == Double(pc.midX) - 250)
        #expect(p.y == pc.maxY + reach)
        #expect(p.caret == 250)
        #expect(p.tipX == Double(pc.midX))
        #expect(p.tipY == p.y - L.caretDepth)
    }

    @Test func aBelowCardIsKeptInsideTheSideMarginsWhileItsCaretStillPointsAtTheElement() {
        let p = placeContextMenu(anchor: CGRect(x: 1750, y: 300, width: 150, height: 200), w: 600, h: 300, below: true, stageW: stageW, stageH: stageH)
        #expect(p.x == 1920 - L.marginX - 600)
        #expect(p.caret == 600 - L.caretInset)
        let left = placeContextMenu(anchor: CGRect(x: 0, y: 300, width: 100, height: 200), w: 600, h: 300, below: true, stageW: stageW, stageH: stageH)
        #expect(left.x == L.marginX)
        #expect(left.caret == L.caretInset)
    }

    @Test func aBelowCardThatDoesNotFitUnderTheElementGoesAboveItWithTheCaretOnTheBottom() {
        let pc = CGRect(x: 800, y: 700, width: 200, height: 200)
        let p = placeContextMenu(anchor: pc, w: 500, h: 300, below: true, stageW: stageW, stageH: stageH)
        #expect(p.side == .bottom)
        #expect(p.y == pc.minY - reach - 300)
        #expect(p.tipY == p.y + 300 + L.caretDepth)
    }

    @Test func aBelowCardThatFitsNeitherWayIsPulledIntoTheMarginsUnderTheElement() {
        let p = placeContextMenu(anchor: CGRect(x: 800, y: 150, width: 200, height: 800), w: 500, h: 700, below: true, stageW: stageW, stageH: stageH)
        #expect(p.side == .top)
        #expect(p.y == 1080 - L.marginY - 700)
    }

    @Test func aCrampedBelowCardGoesBesideItsElementWhenAsked() {
        // A circle on a short compact stage: a card fits neither under nor above it
        let circle = CGRect(x: 116, y: 420, width: 214, height: 214)
        let p = placeContextMenu(
            anchor: circle, w: 470, h: 374, below: true, stageW: 1051, stageH: 1051, marginX: 48, marginY: 48, marginBottom: 200,
            besideWhenCramped: true)
        #expect(p.side == .left)
        #expect(abs(p.x - (circle.maxX + reach)) < 0.01)
        #expect(abs(p.y + p.caret - circle.midY) < 0.01)
        let old = placeContextMenu(anchor: circle, w: 470, h: 374, below: true, stageW: 1051, stageH: 1051, marginX: 48, marginY: 48, marginBottom: 200)
        #expect(old.side == .top)
    }

    @Test func withoutAnAnchorTheCardHasNoCaret() {
        let p = placeContextMenu(anchor: nil, w: 500, h: 300, below: false, stageW: stageW, stageH: stageH)
        #expect(p.side == .none)
        #expect(p.x == L.fallbackX)
        #expect(p.y == L.fallbackY)
    }

    @Test func theTallestCardFillsTheSpaceBetweenTheMargins() {
        #expect(L.maxHeight(stageHeight: 1080) == 840)
        let p = placeContextMenu(anchor: CGRect(x: 125, y: 400, width: 300, height: 200), w: 560, h: L.maxHeight(stageHeight: 1080), below: false, stageW: stageW, stageH: stageH)
        #expect(p.y == L.marginY)
    }

    private let leaf = MenuItem(icon: "a", label: "Leaf")
    private let deeper = MenuItem(icon: "b", label: "Deeper", children: [MenuItem(icon: "c", label: "First"), MenuItem(icon: "d", label: "Second")])
    private var root: [MenuItem] { [leaf, deeper] }

    @Test func theRootPathShowsTheMenuItself() {
        #expect(MenuPath.items(root, []).map(\.label) == ["Leaf", "Deeper"])
        #expect(MenuPath.parent(root, []) == nil)
    }

    @Test func choosingAnItemWithChildrenOpensThemAndAnActionDoesNot() {
        #expect(MenuPath.open(root, [], 1) == [1])
        #expect(MenuPath.open(root, [], 0) == nil)
        #expect(MenuPath.open(root, [], 7) == nil)
        #expect(MenuPath.items(root, [1]).map(\.label) == ["First", "Second"])
        #expect(MenuPath.parent(root, [1])?.label == "Deeper")
        #expect(MenuPath.open(root, [1], 0) == nil)
    }

    @Test func backGoesUpOneLevelAndStopsAtTheRoot() {
        #expect(MenuPath.back([1]) == [])
        #expect(MenuPath.back([1, 0]) == [1])
        #expect(MenuPath.back([]) == [])
    }

    @Test func aPathThatNoLongerFitsTheItemsResolvesAsFarAsItGoes() {
        #expect(MenuPath.items(root, [5]).count == 2)
        #expect(MenuPath.items(root, [0]).count == 2)
        #expect(MenuPath.items(root, [1, 0]).map(\.label) == ["First", "Second"])
        #expect(MenuPath.parent(root, [5]) == nil)
    }
}

/// The toast's kinds, timing and replace rule (`ToastLogicTest` of DELOS for Android).
@Suite struct ToastLogicTests {
    @Test func theKindIsReadFromTheIconWhenTheCallerSaysNothing() {
        #expect(ToastKind.of(explicit: nil, icon: Symbols.error, hasAction: false) == .error)
        #expect(ToastKind.of(explicit: nil, icon: Symbols.wifiOff, hasAction: false) == .error)
        #expect(ToastKind.of(explicit: nil, icon: Symbols.linkOff, hasAction: false) == .error)
        #expect(ToastKind.of(explicit: nil, icon: Symbols.checkCircle, hasAction: false) == .success)
        #expect(ToastKind.of(explicit: nil, icon: Symbols.check, hasAction: false) == .success)
        #expect(ToastKind.of(explicit: nil, icon: Symbols.warning, hasAction: false) == .warning)
        #expect(ToastKind.of(explicit: nil, icon: Symbols.search, hasAction: false) == .info)
        #expect(ToastKind.of(explicit: nil, icon: nil, hasAction: false) == .info)
    }

    @Test func anExplicitKindBeatsTheIconAndAnActionAlwaysWins() {
        #expect(ToastKind.of(explicit: .success, icon: Symbols.linkOff, hasAction: false) == .success)
        #expect(ToastKind.of(explicit: nil, icon: Symbols.delete, hasAction: true) == .action)
        #expect(ToastKind.of(explicit: .error, icon: Symbols.error, hasAction: true) == .action)
    }

    @Test func everyKindHasItsOwnWordAndIcon() {
        #expect(Set(ToastKind.allCases.map(\.word)).count == ToastKind.allCases.count)
        #expect(Set(ToastKind.allCases.map(\.defaultIcon)).count == ToastKind.allCases.count)
    }

    @Test func theTimerLineDrawsInAndThenDrainsOverTheHoldTime() {
        #expect(ToastTiming.timerFraction(age: 0, holdMs: 2000) == 0)
        #expect(ToastTiming.timerFraction(age: ToastTiming.lineAt, holdMs: 2000) == 0)
        let drawing = ToastTiming.timerFraction(age: ToastTiming.lineAt + 100, holdMs: 2000)
        #expect(drawing > 0 && drawing < 0.9)
        #expect(abs(ToastTiming.timerFraction(age: 1000, holdMs: 2000) - 0.5) < 1e-4)
        #expect(abs(ToastTiming.timerFraction(age: 7500, holdMs: 10_000) - 0.25) < 1e-4)
        #expect(ToastTiming.timerFraction(age: 2000, holdMs: 2000) == 0)
        #expect(ToastTiming.timerFraction(age: 5000, holdMs: 2000) == 0)
    }

    @Test func theLifetimesAreNamedInOnePlace() {
        #expect(ToastTiming.shellMs == 4500)
        #expect(ToastTiming.actionMs == 10_000)
    }

    @Test func theEnterSpringOvershootsOnceAndSettles() {
        #expect(ToastTiming.springStep(0) == 0)
        var landed = 0.0
        while ToastTiming.springStep(landed) < 1 { landed += 1 }
        #expect(abs(landed - ToastTiming.landingMs) <= 8)
        let peak = (0...1500).map { ToastTiming.springStep(Double($0)) }.max() ?? 0
        #expect(abs(peak - 1.084) < 0.01)
        #expect(abs(ToastTiming.springStep(650) - 1) < 0.015)
        #expect(abs(ToastTiming.springStep(1500) - 1) < 0.001)
        let low = (400...1500).map { ToastTiming.springStep(Double($0)) }.min() ?? 0
        #expect(low > 0.99)
    }

    @Test func aToastLeavesAtItsHoldTimeAndIsGoneAfterTheExit() {
        let logic = ToastStageLogic<String>()
        let slot = logic.show("A", holdMs: 2000, now: 1000)
        #expect(slot.startMs == 1000)
        #expect(slot.exitMs == 3000)
        #expect(slot.goneMs == 3000 + Motion.exit)
        var exited: [String] = []
        #expect(!logic.advance(now: 2999) { exited.append($0.payload) })
        #expect(exited.isEmpty)
        #expect(!logic.advance(now: 3000) { exited.append($0.payload) })
        #expect(exited == ["A"])
        #expect(!logic.advance(now: 3000 + Motion.exit - 1) { exited.append($0.payload) })
        #expect(logic.advance(now: 3000 + Motion.exit) { exited.append($0.payload) })
        // Told once
        #expect(exited == ["A"])
        #expect(logic.isEmpty)
    }

    @Test func aNewToastSendsTheOldOneAwayAtOnceAndEntersTheRowDelayLater() {
        let logic = ToastStageLogic<String>()
        let first = logic.show("A", holdMs: 2000, now: 0)
        let second = logic.show("B", holdMs: 3500, now: 500)
        #expect(first.exitMs == 500)
        #expect(first.goneMs == 500 + Motion.exit)
        #expect(second.startMs == 500 + Motion.rowDelay)
        #expect(second.exitMs == 500 + Motion.rowDelay + 3500)
        #expect(logic.latestLive(now: 520) === second)
    }

    @Test func aToastInTheGapReplacesTheOneThatIsStillWaitingAndNothingQueues() {
        let logic = ToastStageLogic<String>()
        logic.show("A", holdMs: 2000, now: 0)
        let waiting = logic.show("B", holdMs: 2000, now: 500)
        let third = logic.show("C", holdMs: 2000, now: 560)
        #expect(waiting.exitMs == 560)
        // It never shows
        #expect(waiting.exitMs < waiting.startMs)
        #expect(third.startMs == 560 + Motion.rowDelay)
        #expect(logic.latestLive(now: 570) === third)
        #expect(logic.slots.count == 3)
        logic.advance(now: 560 + Motion.exit + 1) { _ in }
        #expect(logic.slots.map(\.payload) == ["C"])
    }

    @Test func aToastThatArrivesAfterTheOldOneLeftEntersAtOnce() {
        let logic = ToastStageLogic<String>()
        let first = logic.show("A", holdMs: 2000, now: 0)
        let second = logic.show("B", holdMs: 2000, now: 2100)
        #expect(first.exitMs == 2000)
        #expect(second.startMs == 2100)
    }

    @Test func dismissingAndPressingActOnTheLiveToastOnly() {
        let logic = ToastStageLogic<String>()
        let slot = logic.show("A", holdMs: 10_000, now: 0)
        logic.press(now: 4000)
        #expect(slot.pressMs == 4000)
        logic.dismiss(now: 4100)
        #expect(slot.exitMs == 4100)
        // Nothing live any more
        logic.press(now: 4200)
        #expect(slot.pressMs == 4000)
        #expect(logic.latestLive(now: 4200) == nil)
        #expect(!logic.slots.isEmpty)
    }

    @Test func theChipSqueezesWhenPressedAndSpringsBack() {
        #expect(ToastTiming.pressScale(sinceMs: -1) == 1)
        #expect(abs(ToastTiming.pressScale(sinceMs: 0) - 1) < 1e-4)
        #expect(abs(ToastTiming.pressScale(sinceMs: Motion.press - 1) - Motion.pressScale) < 0.02)
        #expect(abs(ToastTiming.pressScale(sinceMs: Motion.pressHold + Motion.press + 1) - 1) < 1e-4)
    }

    @Test func theTextIsCappedAtTwoLinesAndByTheWidthOfTheScreen() {
        #expect(toastMaxLines == 2)
        #expect(toastTextMaxWidth(stageWidth: 1920) == 560)
        #expect(abs(toastTextMaxWidth(stageWidth: 1920, scale: 1.3) - 728) < 0.01)
        #expect(abs(toastTextMaxWidth(stageWidth: 1440, scale: 1.3) - 728) < 0.01)
        #expect(toastTextMaxWidth(stageWidth: 800) == 440)
    }

    @Test func theEasingsMatchCSS() {
        #expect(Motion.ease(0) == 0 && Motion.ease(1) == 1)
        // cubic-bezier(.25, .1, .25, 1) at half time is about 80 % of the way
        #expect(abs(Motion.ease(0.5) - 0.8024) < 0.002)
        // The spring overshoots
        #expect((1...99).map { Motion.easeSpring(Double($0) / 100) }.max()! > 1)
    }
}

/// The toasts of the interface and the layers (`ShellState` of DELOS for Android).
@MainActor
@Suite struct ToastsAndLayersTests {
    @Test func aToastWithAnActionIsTheUndoKindAndRunsOnce() {
        let toasts = Toasts()
        var undone = 0
        toasts.show("Deleted", icon: Symbols.delete, action: ToastAction(label: "Undo") { undone += 1 })
        #expect(toasts.current?.kind == .action)
        #expect(toasts.current?.durationMs == ToastTiming.actionMs)
        #expect(toasts.runAction())
        #expect(undone == 1)
        #expect(toasts.current == nil)
        #expect(toasts.actionPresses == 1)
        #expect(!toasts.runAction())
        #expect(undone == 1)
    }

    @Test func aNewToastReplacesTheOldOneAndHidingAnOldOneDoesNothing() {
        let toasts = Toasts()
        toasts.show("One", icon: Symbols.error)
        let first = toasts.current?.id
        #expect(toasts.current?.kind == .error)
        #expect(toasts.current?.durationMs == ToastTiming.shellMs)
        toasts.show("Two", kind: .warning)
        #expect(toasts.current?.text == "Two")
        #expect(toasts.current?.kind == .warning)
        toasts.hide(first ?? 0)
        #expect(toasts.current?.text == "Two")
        // A toast without an action has nothing to run
        #expect(!toasts.runAction())
    }

    @Test func theFocusedItemsMenuOpensAtItsFrame() {
        let model = FocusModel(initial: "a")
        model.register("a", frame: CGRect(x: 10, y: 20, width: 30, height: 40), menu: { ContextMenu(title: "A", items: []) }) {}
        model.register("b", frame: CGRect(x: 100, y: 20, width: 30, height: 40)) {}
        #expect(model.contextMenu()?.0.title == "A")
        #expect(model.contextMenu()?.1 == CGRect(x: 10, y: 20, width: 30, height: 40))
        model.focus("b")
        #expect(model.contextMenu() == nil)
        let layers = Layers()
        #expect(!layers.openContextMenu(of: model))
        #expect(!layers.isOpen)
        // The options button does not move the focus
        #expect(!model.handle(.options))
    }

    @Test func aRowRunsItsActionAndClosesTheMenuASubmenuOpensInPlaceAndBGoesBack() {
        var chosen: [String] = []
        let menu = ContextMenu(title: "Menu", items: [
            MenuItem(icon: "a", label: "Leaf") { chosen.append("leaf") },
            MenuItem(icon: "b", label: "Deeper", children: [MenuItem(icon: "c", label: "First") { chosen.append("first") }]),
        ])
        let model = FocusModel(initial: "item")
        model.register("item", frame: CGRect(x: 0, y: 0, width: 10, height: 10), menu: { menu }) {}
        let layers = Layers()
        #expect(layers.openContextMenu(of: model))
        #expect(layers.focus.focused == Layers.rowID(0))
        layers.choose(1)
        #expect(layers.menuPath == [1])
        #expect(layers.isOpen)
        #expect(layers.focus.focused == Layers.rowID(0))
        // B goes back to the row that opened the submenu
        layers.handle(.back)
        #expect(layers.menuPath == [])
        #expect(layers.focus.focused == Layers.rowID(1))
        layers.choose(0)
        #expect(chosen == ["leaf"])
        #expect(!layers.isOpen)
        // The options button closes the whole menu, submenus and all
        layers.openContextMenu(of: model)
        layers.choose(1)
        layers.handle(.options)
        #expect(!layers.isOpen)
    }

    @Test func aDialogStartsOnItsFirstFieldAndBClosesIt() {
        let layers = Layers()
        layers.openDialog(DialogSpec(title: "T", note: "N", fields: [DialogField(icon: "e")], confirm: "Save") { _ in true })
        #expect(layers.focus.focused == DialogLayer.fieldID(0))
        layers.handle(.back)
        #expect(!layers.isOpen)
        // A question without fields starts on its button
        layers.openDialog(DialogSpec(title: "T", note: "N", fields: [], confirm: "OK") { _ in true })
        #expect(layers.focus.focused == DialogLayer.confirmID)
    }
}
