/// Ports `LinkMonitorTest.kt` (DELOS for Android); the reading texts are in DelosUITests/LinkVerdictTextTests.swift.
import Testing
@testable import DelosHost

private func linkSample(
    target: Int = 225_000, total: Int64 = 60, partial: Int64 = 0, lost: Int64 = 0, skipped: Int64 = 0,
    rx: Float = 28_000, seconds: Float = 1
) -> LinkSample {
    LinkSample(seconds: seconds, targetKbps: target, totalFrames: total, partialFrames: partial, lostFrames: lost, skippedFrames: skipped, rxKbps: rx)
}

private func linkMonitor(_ samples: [LinkSample]) -> LinkMonitor {
    let monitor = LinkMonitor()
    samples.forEach(monitor.add)
    return monitor
}

@Suite struct LinkMonitorTests {
    private func sample(
        target: Int = 225_000, total: Int64 = 60, partial: Int64 = 0, lost: Int64 = 0, skipped: Int64 = 0,
        rx: Float = 28_000, seconds: Float = 1
    ) -> LinkSample {
        linkSample(target: target, total: total, partial: partial, lost: lost, skipped: skipped, rx: rx, seconds: seconds)
    }

    private func monitor(_ samples: LinkSample...) -> LinkMonitor { linkMonitor(samples) }
    private func monitor(_ count: Int, _ sample: LinkSample) -> LinkMonitor { linkMonitor(Array(repeating: sample, count: count)) }

    @Test func nothingIsSaidBeforeTheFirstSampleAndForTheFirstThreeSeconds() throws {
        #expect(LinkMonitor().reading() == nil)
        let early = monitor(sample(), sample())
        #expect(try #require(early.reading()).verdict == .measuring)
        #expect(early.hint() == nil)
        #expect(monitor(sample(), sample(), sample()).reading()?.verdict == .keepingUp)
    }

    @Test func framesThatArriveWholeKeepUp() throws {
        let reading = try #require(monitor(5, sample()).reading())
        #expect(reading.verdict == .keepingUp)
        #expect(reading.dropShare == 0)
    }

    @Test func partialAndLostFramesAboveTwoPercentMeanTheLinkDropsFrames() throws {
        // 4 partial + 2 lost of 300 frames over 5 s = 2 %
        let m = monitor(sample(partial: 2), sample(partial: 2), sample(lost: 1), sample(lost: 1), sample())
        let reading = try #require(m.reading())
        #expect(reading.verdict == .dropping)
        #expect(abs(reading.partialPerSecond - 0.8) <= 1e-6)
        #expect(abs(reading.lostPerSecond - 0.4) <= 1e-6)
        #expect(m.hint() != nil)
        // 1.7 % does not
        let below = monitor(sample(partial: 2), sample(partial: 2), sample(partial: 1), sample(), sample())
        #expect(below.reading()?.verdict == .keepingUp)
    }

    @Test func theHintNamesTheBitrateAndASuggestedLowerOne() throws {
        // 6 partial a second: 10 % -> cut 40 % (capped), 225 -> 135 Mbps
        let reading = try #require(monitor(4, sample(partial: 6)).reading())
        #expect(reading.suggestedKbps == 135_000)
        // A mild 3 %: 4 x 3 % = 12 % -> 198 Mbps rounded down to 195
        #expect(monitor(4, sample(total: 100, partial: 3)).reading()?.suggestedKbps == 195_000)
    }

    @Test func theSuggestionIsAPureFunctionOfTheDegradation() {
        #expect(suggestedBitrate(targetKbps: 225_000, dropShare: 0.02) == 200_000) // 10 % minimum cut: 202.5 -> 200
        #expect(suggestedBitrate(targetKbps: 225_000, dropShare: 0.5) == 135_000)  // 40 % maximum cut
        #expect(suggestedBitrate(targetKbps: 6_000, dropShare: 0.5) == 5_000)      // never under the probe floor
        #expect(suggestedBitrate(targetKbps: 225_000, dropShare: 0.05) == suggestedBitrate(targetKbps: 225_000, dropShare: 0.05))
    }

    @Test func theWindowIsAboutFiveSecondsSoTheHintClearsAfterTheDropsStop() {
        let m = LinkMonitor()
        for _ in 0..<4 { m.add(sample(partial: 6)) }
        #expect(m.reading()?.verdict == .dropping)
        for _ in 0..<5 { m.add(sample()) }
        #expect(m.reading()?.verdict == .keepingUp)
        #expect(m.hint() == nil)
    }

    @Test func aBitrateChangeStartsAFreshReadingAtTheNewBitrate() throws {
        let m = LinkMonitor()
        for _ in 0..<5 { m.add(sample(partial: 6)) }
        m.add(sample(target: 135_000))
        #expect(m.reading()?.verdict == .measuring)
        for _ in 0..<3 { m.add(sample(target: 135_000)) }
        let reading = try #require(m.reading())
        #expect(reading.verdict == .keepingUp)
        #expect(reading.targetKbps == 135_000)
    }

    @Test func skippedFramesWithoutNetworkDropsPointAtTheDeviceNotTheLink() throws {
        let reading = try #require(monitor(5, sample(skipped: 3)).reading())
        #expect(reading.verdict == .deviceBehind)
        #expect(abs(reading.skippedPerSecond - 3) <= 1e-6)
        #expect(monitor(5, sample(skipped: 3)).hint() == nil)
        // When the network drops as well, the link verdict wins
        #expect(monitor(5, sample(partial: 3, skipped: 3)).reading()?.verdict == .dropping)
    }

    @Test func receivedRateIsAveragedOverTheKnownSeconds() throws {
        let reading = try #require(monitor(sample(rx: 20_000), sample(rx: -1), sample(rx: 30_000), sample(rx: 30_000)).reading())
        #expect(abs(reading.rxKbps - 26_666.666) <= 0.01)
        #expect(monitor(4, sample(rx: -1)).reading()?.rxKbps == -1)
    }

    @Test func emptySamplesAreIgnoredAndFramelessWindowsStayMeasuring() {
        let m = LinkMonitor()
        m.add(sample(seconds: 0))
        #expect(m.reading() == nil)
        for _ in 0..<4 { m.add(sample(total: 0)) }
        #expect(m.reading()?.verdict == .measuring)
    }
}
