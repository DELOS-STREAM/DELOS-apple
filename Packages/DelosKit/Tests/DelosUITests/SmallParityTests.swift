import Testing
@testable import DelosUI

@MainActor
struct SmallParityTests {
    @Test func pairingWaitReturnsImmediatelyForPublishedTrust() async {
        let clock = FakeConnectClock()
        let result = await PairStateWait.until(timeout: 8, clock: clock) { true }
        #expect(result)
        #expect(clock.sleeping == 0)
    }

    @Test func pairingWaitDoesNotConnectUntilTrustAppears() async {
        let clock = FakeConnectClock()
        var trusted = false
        var result: Bool?
        let task = Task { result = await PairStateWait.until(timeout: 8, clock: clock) { trusted } }
        await clock.advance(by: 0.9)
        #expect(result == nil)
        trusted = true
        await clock.advance(by: 0.11)
        await task.value
        #expect(result == true)
    }

    @Test func absentHostTimesOutAndCancellationDoesNotNavigate() async {
        let clock = FakeConnectClock()
        var result: Bool?
        let task = Task { result = await PairStateWait.until(timeout: 5, clock: clock) { false } }
        await clock.advance(by: 5.01)
        await task.value
        #expect(result == false)
        let cancelled = Task { await PairStateWait.until(timeout: 8, clock: clock) { false } }
        await clock.settle()
        cancelled.cancel()
        await clock.settle()
        #expect(await cancelled.value == false)
    }

    @Test func compactChipCentersOnlyWhenItClearsStatusAndShrinksLongNames() {
        let centered = ProfileChipFit.frame(stageWidth: 1000, start: 40, end: 820, idealWidth: 240)
        #expect(centered.x == 380 && centered.width == 240)
        let shifted = ProfileChipFit.frame(stageWidth: 1000, start: 40, end: 580, idealWidth: 240)
        #expect(shifted.x == 190 && shifted.width == 240)
        let long = ProfileChipFit.frame(stageWidth: 1000, start: 40, end: 580, idealWidth: 900)
        #expect(long.x == 40 && long.width == 540)
        #expect(long.x + long.width <= 580)
    }
}
