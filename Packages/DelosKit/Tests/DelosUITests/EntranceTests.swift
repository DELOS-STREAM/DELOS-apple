import Testing
@testable import DelosUI

@MainActor @Suite struct EntranceStaggerTests {
    /// A clock the test moves.
    final class Clock {
        var now = 1000.0
    }

    @Test func placesAreHandedOutInOrderUpToTheCap() {
        let clock = Clock()
        let stagger = EntranceStagger(cap: 3, lateAfterMs: 700) { clock.now }
        #expect((0..<6).map { _ in stagger.take() } == [0, 1, 2, 3, 3, 3])
    }

    @Test func anElementThatAppearsLateIsNotPartOfTheEntrance() {
        let clock = Clock()
        let stagger = EntranceStagger(cap: 8, lateAfterMs: 700) { clock.now }
        #expect(stagger.take() == 0)
        clock.now += 700
        #expect(stagger.isEarly)
        #expect(stagger.take() == 1)
        clock.now += 1
        #expect(!stagger.isEarly)
        #expect(stagger.take() == nil)
        // A late element does not use up a place
        clock.now -= 1
        #expect(stagger.take() == 2)
    }

    @Test func theDefaultsAreTheSharedContract() {
        #expect(Motion.rowDelay == 120 && Motion.staggerRow == 46 && Motion.rowIn == 420 && Motion.rise == 18)
        #expect(Motion.staggerCap == 8 && Motion.staggerWindow == 700)
        // The first element waits 120 ms, each one after it 46 ms more; a menu starts sooner
        #expect(Motion.staggerDelay(0) == 120)
        #expect(Motion.staggerDelay(3) == 120 + 3 * 46)
        #expect(Motion.staggerDelay(8, base: Motion.menuDelay) == 60 + 8 * 46)
        #expect(Motion.staggerDelay(-1) == 120)
    }
}

@Suite struct EntranceLookTests {
    @Test func anElementRisesWhileItFadesIn() {
        let start = EntranceLook(progress: 0, distance: 18, reduced: false)
        #expect(start.opacity == 0 && start.offset == 18)
        let middle = EntranceLook(progress: 0.5, distance: 18, reduced: false)
        #expect(middle.opacity == 0.5 && middle.offset == 9)
        let end = EntranceLook(progress: 1, distance: 18, reduced: false)
        #expect(end.opacity == 1 && end.offset == 0)
    }

    @Test func reducedMotionOnlyFades() {
        let look = EntranceLook(progress: 0.25, distance: 18, reduced: true)
        #expect(look.opacity == 0.25 && look.offset == 0)
    }

    @Test func anOvershootingProgressDoesNotMakeItMoreThanOpaque() {
        #expect(EntranceLook(progress: 1.2, distance: 18, reduced: false).opacity == 1)
        #expect(EntranceLook(progress: -0.2, distance: 18, reduced: false).opacity == 0)
    }
}
