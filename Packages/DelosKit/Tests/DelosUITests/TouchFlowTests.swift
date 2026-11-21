import CoreGraphics
import DelosHost
import DelosInput
import Testing
@testable import DelosUI

/// The dashboard's touch path around game info (#25), as sequences of a finger's steps run through the real rules: the
/// first tap that focuses (``ItemTouch``), the press squeeze (``TouchPress``), the cover's swipe (``OverviewLauncher``,
/// the recognizer's axis rule ``CoverDragDirection``), the flight's start and landing (``OverviewMotion``). Each step
/// checks what the finger sees; the matrix runs the owner's sequences, repeated.
@MainActor
@Suite struct TouchFlowTests {
    func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9 && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    /// The dashboard under a finger: a row of covers at rest, the focus, the overview's flight when one is open.
    @MainActor final class Dashboard {
        struct Opened {
            let app: Int
            let source: CGRect
            let back: CGRect
            let fromOpacity: Double
            let velocity: Double
        }

        static let slot = CGRect(x: 150, y: 150, width: 340, height: 510)
        static let cap = 56.0, threshold = 72.0, slop = 10.0, arc = 30.0
        let launcher = OverviewLauncher()
        let apps = (1...6).map { HostApp(id: $0, title: "Game \($0)") }
        var focused = 1
        var rest: [Int: CGRect] = [:]
        var press = TouchPress()
        var opened: Opened?
        var activated: [Int] = []

        init() {
            for app in apps {
                rest[app.id] = CGRect(x: 150 + Double(app.id - 1) * 360, y: 560, width: 316, height: 474)
            }
            launcher.canOpen = { _ in true }
            launcher.isFocused = { [unowned self] in $0.id == self.focused }
            launcher.open = { [unowned self] app, release in self.open(app.id, release) }
        }

        private func open(_ id: Int, _ release: OverviewSwipeRelease?) {
            guard opened == nil, let frame = rest[id] else { return }
            let source = OverviewMotion.cardFrame(rest: frame, lift: release?.offset ?? 0, scale: release?.scale ?? 1)
            opened = Opened(app: id, source: source, back: OverviewMotion.cardFrame(rest: frame), fromOpacity: release?.opacity ?? 1,
                            velocity: release.map { OverviewMotion.openVelocity(velocityY: $0.velocityY, from: source, to: Self.slot, lift: Self.arc) } ?? 0)
        }

        private func squeezes(_ id: Int) -> Bool {
            TouchPress.squeezes(ItemTouch.of(focused: focused == id, kind: .touch, ownTap: false, firstTapFocuses: true))
        }

        /// A tap on [id]'s cover: a first tap only focuses it (no squeeze), a tap on the focused one starts it.
        @discardableResult func tap(_ id: Int) -> (squeezed: Bool, touch: ItemTouch) {
            let touch = ItemTouch.of(focused: focused == id, kind: .touch, ownTap: false, firstTapFocuses: true)
            press.began(at: .zero, squeezes: squeezes(id))
            let squeezed = press.pressed
            press.ended()
            focused = id
            if touch == .activate { activated.append(id) }
            return (squeezed, touch)
        }

        /// A finger held on [id]'s cover: whether it squeezes while down, and whether it let go when the finger lifted.
        func hold(_ id: Int) -> (down: Bool, after: Bool) {
            press.began(at: .zero, squeezes: squeezes(id))
            let down = press.pressed
            press.ended()
            return (down, press.pressed)
        }

        /// A finger dragging [id]'s cover by [dx], [dy] points in 2-point steps, lifting at [velocityY] points per
        /// second, through the recognizer's rule: the axis decides at the slop, an upward drag begins only on a cover
        /// that may swipe. Returns whether the press let go before the finger lifted and the largest lift and fade seen.
        @discardableResult
        func drag(_ id: Int, dx: Double = 0, dy: Double, velocityY: Double = 0) -> (pressReleased: Bool, lift: Double, opacity: Double) {
            let app = apps[id - 1]
            press.began(at: .zero, squeezes: squeezes(id))
            var began = false, failed = false, releasedEarly = false, lift = 0.0, opacity = 1.0
            let steps = Int(max(abs(dx), abs(dy)) / 2)
            for step in 1...max(steps, 1) {
                let t = Double(step) / Double(max(steps, 1))
                let translation = CGSize(width: dx * t, height: dy * t)
                press.moved(to: CGPoint(x: translation.width, y: translation.height))
                if !press.pressed { releasedEarly = true }
                if !began, !failed {
                    switch CoverDragDirection.of(translation: translation, minimumDistance: Self.slop) {
                    case .undecided: break
                    case .horizontalScroll: failed = true
                    case .verticalSwipe: if translation.height < 0, launcher.canSwipe(app) { began = true } else { failed = true }
                    }
                }
                if began {
                    launcher.drag(app, translation: translation, slop: Self.slop, cap: Self.cap, threshold: Self.threshold)
                    let follow = launcher.follow(id)
                    lift = min(lift, follow.offset)
                    opacity = min(opacity, OverviewMotion.swipeOpacity(follow.share))
                }
            }
            if began { launcher.end(app, translation: CGSize(width: dx, height: dy), velocityY: velocityY, threshold: Self.threshold) }
            if failed, abs(dx) > abs(dy) {
                // The row scrolled: every cover's resting frame moved with it
                for key in rest.keys { rest[key] = rest[key]?.offsetBy(dx: dx, dy: 0) }
            }
            press.ended()
            return (releasedEarly, lift, opacity)
        }

        /// The overview closes from the open page (Back, or a pull of [pull] points let go at [speed] points per
        /// second): where the flight starts and where it lands.
        func close(pull: Double = 0, speed: Double = 0) -> (start: CGRect, landing: CGRect, velocity: Double)? {
            guard let opened else { return nil }
            let handoff = OverviewMotion.pullHandoff(slot: Self.slot, pull: pull, scale: OverviewMotion.pullScale(pull), speed: speed, card: opened.back)
            let start = OverviewMotion.flightFrame(from: opened.back, to: handoff.frame, progress: 1, lift: Self.arc, cap: 40)
            let landing = OverviewMotion.flightFrame(
                from: OverviewMotion.closingFrom(progress: 0, start: 1, from: opened.back, back: opened.back), to: handoff.frame,
                progress: 0, lift: Self.arc, cap: 40)
            self.opened = nil
            launcher.reset()
            return (start, landing, handoff.velocity)
        }
    }

    /// The owner's whole sequence, three times over: tap another cover, swipe it up past the threshold (it opens from
    /// where the finger left it), pull the page down (it lands exactly on the card at rest), scroll the row.
    @Test(arguments: [2, 3, 4])
    func tapSwipePullScrollRepeats(first: Int) {
        let home = Dashboard()
        var target = first
        for round in 0..<3 {
            // A first tap on another cover only focuses it: no squeeze, no start
            let tapped = home.tap(target)
            #expect(tapped.touch == .focusOnly && !tapped.squeezed && home.focused == target && home.activated.isEmpty)
            // The focused cover squeezes under a resting finger, and lets go when it lifts
            let hold = home.hold(target)
            #expect(hold.down && !hold.after)
            // Swiped up past the threshold: the press lets go once the drag takes over; the cover lifted on its band
            // (at most its cap) and faded near its top; the flight starts from there, faded, at the finger's speed
            let swipe = home.drag(target, dy: -260, velocityY: -1200)
            #expect(swipe.pressReleased && swipe.lift < 0 && swipe.lift > -Dashboard.cap && swipe.opacity < 0.85)
            let opened = try! #require(home.opened)
            #expect(opened.app == target && opened.source.minY < opened.back.minY && opened.fromOpacity < 0.85 && opened.velocity > 0)
            #expect(abs(OverviewMotion.flightOpacity(progress: 0, from: opened.fromOpacity) - opened.fromOpacity) < 1e-12)
            #expect(OverviewMotion.flightOpacity(progress: 0.3, from: opened.fromOpacity) == 1)
            // Pulled down and let go: the flight starts at the pulled cover with the finger's speed and lands exactly on
            // the card at rest (never on the lifted frame it left from)
            let close = try! #require(home.close(pull: 180, speed: 900))
            #expect(close.start.minY > Dashboard.slot.minY && close.velocity > 0)
            #expect(near(close.landing, opened.back) && !near(close.landing, opened.source))
            #expect(home.launcher.follow(target).offset == 0 && home.launcher.dragApp == nil)
            // The row scrolls sideways under a finger: no swipe, no squeeze left behind
            let scroll = home.drag(target, dx: round.isMultiple(of: 2) ? -300 : 300, dy: 4)
            #expect(scroll.pressReleased && scroll.lift == 0 && home.opened == nil)
            target = target % 5 + 1
        }
    }

    /// Regression: a cover focused by a tap (or a controller, or the pointer) swipes at once; before, only the cover
    /// focused when the row was last drawn did, so a swipe on a newly tapped cover did nothing.
    @Test func newlyFocusedCoverSwipesAtOnce() {
        let home = Dashboard()
        // Not focused: the upward drag is the row's, nothing lifts or opens
        let before = home.drag(3, dy: -200)
        #expect(before.lift == 0 && home.opened == nil)
        home.tap(3)
        home.drag(3, dy: -200)
        #expect(home.opened?.app == 3)
        _ = home.close()
        // A controller moves the focus: the newly focused cover swipes too, the old one no longer does
        home.focused = 5
        home.drag(3, dy: -200)
        #expect(home.opened == nil)
        home.drag(5, dy: -200)
        #expect(home.opened?.app == 5)
    }

    /// Let go short of the threshold, the cover springs back and nothing opens; a second swipe opens it.
    @Test func earlyReleaseSpringsBackThenOpens() {
        let home = Dashboard()
        let early = home.drag(1, dy: -50)
        #expect(early.lift < 0 && home.opened == nil && home.launcher.follow(1).offset == 0 && home.launcher.dragApp == nil)
        home.drag(1, dy: -120)
        #expect(home.opened?.app == 1)
    }

    /// The press: a focused item squeezes from its touch down, an item a first tap only focuses does not; a drag past
    /// the slop lets go, as do the finger lifting and a cancelled touch.
    @Test func pressFollowsTheFinger() {
        var press = TouchPress()
        press.began(at: .zero, squeezes: TouchPress.squeezes(.activate))
        #expect(press.pressed)
        press.moved(to: CGPoint(x: 6, y: 6))
        #expect(press.pressed)
        press.moved(to: CGPoint(x: 0, y: -12))
        #expect(!press.pressed)
        press.began(at: .zero, squeezes: TouchPress.squeezes(.focusOnly))
        #expect(!press.pressed)
        press.began(at: .zero, squeezes: TouchPress.squeezes(.own(wasFocused: false)))
        #expect(press.pressed)
        press.ended()
        #expect(!press.pressed)
    }

    /// Back while the opening still flies: the flight turns around from where it is drawn (no jump) and lands exactly on
    /// the card at rest, even when a finger had lifted the card it left from.
    @Test(arguments: [0.2, 0.5, 0.9])
    func backMidOpeningLandsOnTheCard(at progress: Double) {
        let rest = CGRect(x: 150, y: 560, width: 316, height: 474)
        let back = OverviewMotion.cardFrame(rest: rest), lifted = OverviewMotion.cardFrame(rest: rest, lift: -40, scale: 1.02)
        let slot = Dashboard.slot
        let drawn = OverviewMotion.flightFrame(from: lifted, to: slot, progress: progress, lift: 30)
        let turned = OverviewMotion.flightFrame(from: OverviewMotion.closingFrom(progress: progress, start: progress, from: lifted, back: back),
                                                to: slot, progress: progress, lift: 30)
        #expect(abs(drawn.minY - turned.minY) < 1e-9 && abs(drawn.minX - turned.minX) < 1e-9 && abs(drawn.width - turned.width) < 1e-9)
        let landing = OverviewMotion.flightFrame(from: OverviewMotion.closingFrom(progress: 0, start: progress, from: lifted, back: back),
                                                 to: slot, progress: 0, lift: 30)
        #expect(near(landing, back))
    }

    /// The finger's speed as it lifts: the last tenth of a second of its moves; a finger that rested before lifting has
    /// none.
    @Test func swipeVelocityReadsTheLastMoves() {
        var tracker = SwipeVelocity()
        for step in 0...10 { tracker.add(y: 500 - Double(step) * 12, at: Double(step) * 0.01) }
        #expect(abs(tracker.velocity(at: 0.1) + 1200) < 1)
        var rested = SwipeVelocity()
        rested.add(y: 500, at: 0)
        rested.add(y: 400, at: 0.05)
        #expect(rested.velocity(at: 0.4) == 0)
    }
}
