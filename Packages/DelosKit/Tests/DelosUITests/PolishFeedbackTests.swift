import SwiftUI
import Testing
@testable import DelosUI

@MainActor
@Suite struct PolishFeedbackTests {
    @Test func activationPlaysItsCueOnce() {
        let feedback = Feedback()
        feedback.soundsEnabled = false
        var ran = 0
        #expect(feedback.activate(.select) { ran += 1; return true })
        #expect(ran == 1)
        #expect(feedback.activate(.select) { false } == false)
    }

    @Test func aCueOfTheActionReplacesTheActivationsCue() {
        let feedback = Feedback()
        feedback.soundsEnabled = false
        // The action plays BACK itself: the activation adds nothing (Cancel is BACK only)
        feedback.activate(.select) { feedback.play(.back); return true }
        // Counting through a probe: the next activation still plays its own
        var plays = 0
        let before = feedback.playedCount
        feedback.activate(.select) { true }
        plays = feedback.playedCount - before
        #expect(plays == 1)
        let beforeAction = feedback.playedCount
        feedback.activate(.select) { feedback.play(.back); return true }
        #expect(feedback.playedCount - beforeAction == 1)
    }

    @Test func aSilentItemPlaysNothing() {
        let feedback = Feedback()
        feedback.soundsEnabled = false
        let before = feedback.playedCount
        feedback.activate(nil) { true }
        #expect(feedback.playedCount == before)
    }

    @Test func acceptCueIsTheItemsOrSelect() {
        let model = FocusModel()
        model.register("a", frame: .zero, cue: .back) {}
        model.register("b", frame: .zero, cue: nil) {}
        model.register("c", frame: .zero) {}
        model.focus("a")
        #expect(model.acceptCue == .back)
        model.focus("b")
        #expect(model.acceptCue == nil)
        model.focus("c")
        #expect(model.acceptCue == .select)
    }

    @Test func pressIsAbsoluteBelowEveryFocusScale() {
        // The element's lift drops while pressed; FocusItem's shared pressLook takes it to 0.96 of its size at rest
        #expect(focusScale(focused: true, pressed: true, focus: 1.16) * Motion.pressScale == Motion.pressScale)
        #expect(focusScale(focused: true, pressed: false, focus: 1.16) == 1.16)
        #expect(focusScale(focused: false, pressed: false, focus: 1.16) == 1)
    }

    @Test func choiceDirectionFollowsTheStepAndTheWrap() {
        #expect(ChoiceValue<EmptyView>.direction(from: 1, to: 2, count: 4) == 1)
        #expect(ChoiceValue<EmptyView>.direction(from: 2, to: 1, count: 4) == -1)
        #expect(ChoiceValue<EmptyView>.direction(from: 3, to: 0, count: 4) == 1)
        #expect(ChoiceValue<EmptyView>.direction(from: 0, to: 3, count: 4) == -1)
        #expect(ChoiceValue<EmptyView>.direction(from: 0, to: 1, count: 2) == 1)
        #expect(ChoiceValue<EmptyView>.direction(from: 1, to: 1, count: 4) == 0)
    }

    @Test func dockGeometryAndTimeline() {
        typealias D = StreamDockLayout
        #expect(D.rowWidth(count: 4) == 732)
        #expect(D.ringLeft(0) == -18)
        #expect(D.tileLeft(2) == 388)
        #expect(D.gap >= FocusSpacing.gap(reach: (D.ring - D.tile) / 2))
        #expect(D.tileDelay(0) == 100 && D.tileDelay(3) == 226)
        #expect(D.labelDelay(1) == 282)
        #expect(D.ringDelay(3) == 486)
        #expect(D.exitDelay(3, count: 4) == 0 && D.exitDelay(0, count: 4) == 24)
        #expect(D.enterTotal(count: 4) == 486 + 620)
        #expect(D.exitTotal(count: 4) == 24 + 240)
        #expect(D.closeTotal(count: 4) == 344)
    }
}
