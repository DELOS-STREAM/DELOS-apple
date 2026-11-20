import Testing
@testable import DelosMedia

@Suite struct FramePacerTests {
    /// 120 fps: one frame is 8.33 ms.
    let t = 1.0 / 120

    @Test func phaseLockLeavesTheTimeToTheQueue() {
        // The display layer shows phase lock's frames at once; the Metal renderer's queue times them (FrameQueue)
        var pacer = FramePacer(pacing: .phaseLock, fps: 120)
        #expect(pacer.presentationTime(arrival: 1) == nil)
    }

    @Test func framesThatArriveBunchedAreSpreadOut() {
        var pacer = FramePacer(pacing: .balanced, fps: 120)
        // Three frames arrive within 1 ms after a gap: they are shown about one frame apart
        let times = [1.0, 1.0005, 1.001].map { pacer.presentationTime(arrival: $0)! }
        #expect(abs(times[0] - (1 + t)) < 1e-9)
        #expect(times[1] - times[0] >= 0.9 * t - 1e-12)
        #expect(times[2] - times[1] >= 0.9 * t - 1e-12)
    }

    @Test func evenFramesKeepTheirSpacingAndTheBuffer() {
        var pacer = FramePacer(pacing: .smoothness, fps: 120)
        let times = (0..<5).map { pacer.presentationTime(arrival: 1 + Double($0) * t)! }
        for (i, time) in times.enumerated() { #expect(abs(time - (1 + Double(i) * t + 2 * t)) < 1e-9) }
    }

    @Test func aBacklogStartsTheScheduleAgainInsteadOfAddingDelay() {
        var pacer = FramePacer(pacing: .balanced, fps: 120)
        // Ten frames at the same instant (a stall caught up): the schedule would run 9 frames ahead
        let times = (0..<10).map { _ in pacer.presentationTime(arrival: 2)! }
        #expect(times.allSatisfy { $0 - 2 <= t + 2 * t + 1e-9 })
    }

    @Test func aResetForgetsThePreviousFrame() {
        var pacer = FramePacer(pacing: .balanced, fps: 60)
        _ = pacer.presentationTime(arrival: 5)
        pacer.reset()
        #expect(pacer.presentationTime(arrival: 1) == 1 + 1.0 / 60)
    }
}
