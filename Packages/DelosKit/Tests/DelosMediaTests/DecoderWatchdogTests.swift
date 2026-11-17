import Testing
@testable import DelosMedia

struct DecoderWatchdogTests {
    private struct Clock {
        var now: UInt64 = 0
        mutating func second() { now += 1_000_000_000 }
    }
    @Test func arrivingFramesWithoutAnyPresentationRequestRecoveryAfterFiveSeconds() {
        var clock = Clock(); var watchdog = DecoderWatchdog()
        #expect(watchdog.observe(arrivedFrames: 1, presentedFrames: 0, now: clock.now) == false)
        for i in 1...4 {
            clock.second()
            #expect(watchdog.observe(arrivedFrames: UInt64(i + 1), presentedFrames: 0, now: clock.now) == false)
        }
        clock.second()
        #expect(watchdog.observe(arrivedFrames: 6, presentedFrames: 0, now: clock.now) == true)
        clock.second()
        #expect(watchdog.observe(arrivedFrames: 7, presentedFrames: 0, now: clock.now) == false)
    }
    @Test func networkSilenceAndLaterFirstArrivalDoNotCountAsDecoderStall() {
        var clock = Clock(); var watchdog = DecoderWatchdog()
        #expect(watchdog.observe(arrivedFrames: 0, presentedFrames: 0, now: clock.now) == false)
        for _ in 0..<20 {
            clock.second()
            #expect(watchdog.observe(arrivedFrames: 0, presentedFrames: 0, now: clock.now) == false)
        }
        clock.second()
        #expect(watchdog.observe(arrivedFrames: 1, presentedFrames: 0, now: clock.now) == false)
        clock.second()
        #expect(watchdog.observe(arrivedFrames: 2, presentedFrames: 0, now: clock.now) == false)
    }
    @Test func actualPresentationProgressRestartsTheStallWindow() {
        var clock = Clock(); var watchdog = DecoderWatchdog()
        _ = watchdog.observe(arrivedFrames: 1, presentedFrames: 0, now: clock.now)
        for i in 1...4 {
            clock.second()
            #expect(watchdog.observe(arrivedFrames: UInt64(i + 1), presentedFrames: 0, now: clock.now) == false)
        }
        clock.second()
        #expect(watchdog.observe(arrivedFrames: 6, presentedFrames: 1, now: clock.now) == false)
        clock.second()
        #expect(watchdog.observe(arrivedFrames: 7, presentedFrames: 1, now: clock.now) == false)
        for i in 1...4 {
            clock.second()
            #expect(watchdog.observe(arrivedFrames: UInt64(i + 7), presentedFrames: 1, now: clock.now) == false)
        }
        clock.second()
        #expect(watchdog.observe(arrivedFrames: 12, presentedFrames: 1, now: clock.now) == true)
    }
    @Test func missingMetricsCounterResetAndClockRewindNeverInventProgressOrFailure() {
        var watchdog = DecoderWatchdog()
        _ = watchdog.observe(arrivedFrames: 1, presentedFrames: 0, now: 0)
        #expect(watchdog.observe(arrivedFrames: 100, presentedFrames: nil, now: 10_000_000_000) == false)
        #expect(watchdog.observe(arrivedFrames: 101, presentedFrames: 5, now: 11_000_000_000) == false)
        #expect(watchdog.observe(arrivedFrames: 102, presentedFrames: 0, now: 12_000_000_000) == false)
        #expect(watchdog.observe(arrivedFrames: 103, presentedFrames: 0, now: 1) == false)
        watchdog.reset()
        #expect(watchdog.observe(arrivedFrames: 1, presentedFrames: 0, now: 2) == false)
    }
    @Test func warpModesNeverAddClientPacingDelay() {
        for mode in [FramePacing.warp, .warp2] {
            var pacer = FramePacer(pacing: mode, fps: 480)
            #expect(pacer.presentationTime(arrival: 1) == nil)
            #expect(pacer.presentationTime(arrival: 1.0001) == nil)
        }
    }
}
