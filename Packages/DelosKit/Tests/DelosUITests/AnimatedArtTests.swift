import Foundation
import Testing
@testable import DelosUI

/// When animated artwork plays and at what size it is decoded (`AnimatedPlaybackTest` of DELOS for Android).
@Suite struct AnimatedPlaybackTests {
    private func play(visible: Bool = true, foreground: Bool = true, streaming: Bool = false, reduced: Bool = false, system: Bool = false) -> Bool {
        AnimatedPlayback.shouldPlay(visible: visible, foreground: foreground, streaming: streaming, reducedMotion: reduced, systemReduceMotion: system)
    }

    @Test func playsOnlyWhereItCanBeSeenAndMotionIsAllowed() {
        #expect(play())
    }

    @Test func everyReasonToStopStopsIt() {
        #expect(!play(visible: false))
        #expect(!play(foreground: false))
        #expect(!play(streaming: true))
        #expect(!play(reduced: true))
        #expect(!play(system: true))
    }

    @MainActor
    @Test func aDialogStopsTheLibrarysArtworkAndAContextMenuDoesNot() {
        #expect(!AnimatedPlayback.layerStopsLibraryArt(nil))
        #expect(!AnimatedPlayback.layerStopsLibraryArt(.context(ContextMenu(title: "Hades", items: []), anchor: nil)))
        #expect(AnimatedPlayback.layerStopsLibraryArt(.dialog(DialogSpec(title: "Sure?", note: "Really", fields: [], confirm: "Yes") { _ in true })))
    }

    @Test func theAnimatedHeroStartsOnlyAfterTheGameStayedFocused() {
        #expect(!AnimatedPlayback.heroMayPlay(animate: true, dwelledMillis: 0))
        #expect(!AnimatedPlayback.heroMayPlay(animate: true, dwelledMillis: AnimatedPlayback.heroDwell - 1))
        #expect(AnimatedPlayback.heroMayPlay(animate: true, dwelledMillis: AnimatedPlayback.heroDwell))
        // Dwelled long enough does not matter once playing is not allowed (the focus left, a portal opened)
        #expect(!AnimatedPlayback.heroMayPlay(animate: false, dwelledMillis: AnimatedPlayback.heroDwell))
        // Held longer than the cross-fade (900 ms) and the fade-out (800 ms) that remove the hero themselves
        #expect(AnimatedPlayback.heroHold > 900)
    }

    private func size(_ width: Int, _ height: Int, _ maxWidth: Int, _ maxHeight: Int = .max, fit: Bool = false) -> [Int] {
        let size = AnimatedPlayback.decodeSize(width: width, height: height, maxWidth: maxWidth, maxHeight: maxHeight, fit: fit)
        return [size.width, size.height]
    }

    @Test func framesAreDecodedAtTileSizeNeverEnlarged() {
        #expect(size(1040, 600, 520) == [520, 300])
        #expect(size(342, 482, 520) == [342, 482])
        #expect(size(3840, 1240, 1050) == [1050, 339])
        #expect(size(0, 0, 520) == [1, 1])
    }

    @Test func aCroppedViewIsDecodedJustBigEnoughToCoverIt() {
        // A 600 × 900 cover in a 330 × 495 tile: scaled by .55
        #expect(size(600, 900, 330, 495) == [330, 495])
        // A square animation in a portrait tile: the height decides (330 × 495 needs 495 across), never above the original
        #expect(size(1000, 1000, 330, 495) == [495, 495])
        #expect(size(400, 400, 330, 495) == [400, 400])
        // A wide cover in the wide tile
        #expect(size(2104, 984, 1052, 492) == [1052, 492])
    }

    @Test func aFittedViewIsDecodedJustBigEnoughToFitIt() {
        // A 2000 × 500 logo in a 900 × 180 box: the height decides
        #expect(size(2000, 500, 900, 180, fit: true) == [720, 180])
        // A small logo is never enlarged
        #expect(size(300, 100, 900, 180, fit: true) == [300, 100])
    }
}

/// The frame clock of a playing animation: the Android platform's `AnimatedImageDrawable` (hwui `onDraw`) step by step.
@Suite struct FrameClockTests {
    /// The frames shown at display frames every [step] ms from 0 to [until], every frame decoded in time.
    private func shown(_ durations: [Int], repeats: Bool = true, step: Double = 1, until: Double) -> [Int] {
        var clock = FrameClock(durations: durations, repeats: repeats, now: 0)
        var frames = [clock.index]
        for now in stride(from: step, through: until, by: step) where clock.draw(at: now, ready: true) {
            frames.append(clock.index)
        }
        return frames
    }

    /// What [clock] shows after each display frame of [draws] (time, the next frame decoded): the new frame, or nil when
    /// it stays.
    private func draw(_ clock: inout FrameClock, _ draws: [(Double, Bool)]) -> [Int?] {
        draws.map { now, ready in clock.draw(at: now, ready: ready) ? clock.index : nil }
    }

    @Test func eachFrameStaysForItsDurationAndTheAnimationRepeats() {
        var clock = FrameClock(durations: [100, 50, 200], repeats: true, now: 1000)
        #expect(clock.index == 0 && clock.nextIndex == 1)
        let steps = draw(&clock, [(1099, true), (1100, true), (1149, true), (1150, true), (1349, true), (1350, true)])
        #expect(steps == [nil, 1, nil, 2, nil, 0])
        #expect(shown([100, 50, 200], until: 700) == [0, 1, 2, 0, 1, 2, 0])
    }

    @Test func aFrameOfZeroMillisecondsShowsForOneDisplayFrame() {
        var clock = FrameClock(durations: [40, 0, 250], repeats: true, now: 0)
        // Frame 1 is due at once, but changes only at the next display frame
        let steps = draw(&clock, [(40, true), (56, true), (72, true)])
        #expect(steps == [1, 2, nil])
    }

    @Test func theNextFrameWaitsUntilItIsDecoded() {
        var clock = FrameClock(durations: [100, 100, 100], repeats: true, now: 0)
        // Shown as soon as it is there; it was due at 100, so the frame after it keeps its pace (due at 200)
        let steps = draw(&clock, [(120, false), (130, true), (199, true), (200, true)])
        #expect(steps == [nil, 1, nil, 2])
    }

    @Test func aFrameThatCameVeryLateKeepsItsWholeTimeInsteadOfTheNextOnesRushingBy() {
        var clock = FrameClock(durations: [100, 100, 100, 100], repeats: true, now: 0)
        // Not drawn for a second: one frame steps on, and it shows for its whole 100 ms from then
        let steps = draw(&clock, [(1000, true), (1016, true), (1099, true), (1100, true)])
        #expect(steps == [1, nil, nil, 2])
    }

    @Test func onePassStopsOnItsLastFrame() {
        var clock = FrameClock(durations: [100, 100, 100], repeats: false, now: 0)
        let pass = draw(&clock, [(100, true), (200, true)])
        #expect(pass == [1, 2])
        #expect(clock.index == 2 && clock.finished && clock.nextIndex == nil)
        let after = draw(&clock, [(10_000, true)])
        #expect(after == [nil])
        #expect(shown([100, 100, 100], repeats: false, step: 100, until: 1000) == [0, 1, 2])
        // Told to repeat before the end, it goes on
        var looping = FrameClock(durations: [100, 100, 100], repeats: false, now: 0)
        looping.repeats = true
        let steps = draw(&looping, [(100, true), (200, true), (300, true)])
        #expect(steps == [1, 2, 0])
    }
}

/// How an animated game background loops without a jump (`HeroLoopTimelineTest` of DELOS for Android).
@Suite struct HeroLoopTimelineTests {
    private func of(_ loop: Int) throws -> HeroLoopTimeline { try #require(HeroLoopTimeline.of(loopMillis: loop)) }

    @Test func aShortOrUnknownLoopKeepsThePlainLoop() {
        #expect(HeroLoopTimeline.of(loopMillis: 0) == nil)
        #expect(HeroLoopTimeline.of(loopMillis: 1_000) == nil)
        #expect(HeroLoopTimeline.of(loopMillis: HeroLoopTimeline.minLoop - 1) == nil)
        #expect(HeroLoopTimeline.of(loopMillis: HeroLoopTimeline.minLoop) != nil)
    }

    @Test func theFadeIsAboutSevenHundredMillisecondsAndNeverMoreThanAThirdOfTheLoop() throws {
        #expect(try of(1_500).fadeMillis == 500)
        #expect(try of(1_800).fadeMillis == 600)
        #expect(try of(2_100).fadeMillis == 700)
        #expect(try of(3_500).fadeMillis == 700)
        #expect(try of(60_000).fadeMillis == 700)
        for loop in stride(from: 1_500, through: 20_000, by: 37) { #expect(try of(loop).fadeMillis * 3 <= loop) }
    }

    @Test func eachPassStartsOneLoopLessTheFadeAfterTheOneBefore() throws {
        let t = try of(3_500)
        #expect(t.periodMillis == 2_800)
        // The last fade's worth of a pass is the next pass's first
        #expect(t.loopMillis == t.periodMillis + t.fadeMillis)
    }

    @Test func theNextPassIsDecodedAfterTheFadeOfTheCurrentOneAndBeforeItStarts() throws {
        for loop in stride(from: 1_500, through: 20_000, by: 53) {
            let t = try of(loop)
            #expect(t.decodeAtMillis >= t.fadeMillis, "loop \(loop)")
            #expect(t.decodeAtMillis < t.periodMillis)
        }
        #expect(try of(3_500).decodeAtMillis == 2_300)
    }

    @Test func theIncomingPassFadesFromNothingToFullAndStaysThere() throws {
        let t = try of(3_500)
        #expect(t.progress(0) == 0)
        #expect(abs(t.progress(350) - 0.5) < 1e-9)
        #expect(t.progress(700) == 1)
        #expect(t.progress(2_000) == 1)
        // A clock a hair earlier than the start never gives a negative opacity
        #expect(t.progress(-3) == 0)
    }

    @Test func theEasedFadeIsMonotonicAndEndsAtFull() throws {
        let t = try of(3_500)
        var last = 0.0
        for ms in stride(from: 0, through: 700, by: 10) {
            let eased = Motion.ease(t.progress(Double(ms)))
            #expect(eased >= last)
            last = eased
        }
        #expect(abs(last - 1) < 1e-9)
    }
}
