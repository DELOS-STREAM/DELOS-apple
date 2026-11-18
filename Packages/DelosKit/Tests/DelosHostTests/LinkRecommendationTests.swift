/// Ports `LinkRecommendationTest.kt` (DELOS for Android); the `line` texts are in DelosUITests/LinkVerdictTextTests.swift.
import Testing
@testable import DelosHost

@Suite struct LinkRecommendationTests {
    private let drops = LinkReading(
        verdict: .dropping, targetKbps: 225_000, rxKbps: 180_000, partialPerSecond: 6, lostPerSecond: 0, skippedPerSecond: 0,
        dropShare: 0.1, suggestedKbps: 135_000)

    @Test func withoutATestTheStaticGuideStandsAndSaysSo() {
        let r = recommend(staticKbps: 225_000)
        #expect(r.kbps == 225_000)
        #expect(r.reason == .untested)
    }

    @Test func aLinkThatCarriesMoreThanTheFormatNeedsKeepsTheStaticGuide() {
        let r = recommend(staticKbps: 225_000, testedWireKbps: 340_000)
        #expect(r.kbps == 225_000)
        #expect(r.reason == .testedOK)
        // Exactly enough is enough
        #expect(recommend(staticKbps: 225_000, testedWireKbps: 225_000).reason == .testedOK)
    }

    @Test func aSlowerLinkLowersTheRecommendationToWhatItCarries() {
        let r = recommend(staticKbps: 225_000, testedWireKbps: 180_000)
        #expect(r.kbps == 180_000)
        #expect(r.reason == .testedLimited)
    }

    @Test func theHostLinkIsOnlyACeilingNotAMeasurement() {
        // Untested: the PC's own 100 Mbps link caps the offer
        let capped = recommend(staticKbps: 225_000, hostLinkKbps: 100_000)
        #expect(capped.kbps == 100_000)
        #expect(capped.reason == .hostLinkLimited)
        // A faster host link than needed changes nothing
        #expect(recommend(staticKbps: 225_000, hostLinkKbps: 1_000_000).reason == .untested)
        // Tested above need, but the host link is lower: the lower budget binds
        #expect(recommend(staticKbps: 225_000, testedWireKbps: 340_000, hostLinkKbps: 100_000).reason == .hostLinkLimited)
        // Tested below the host link: the test binds
        let tested = recommend(staticKbps: 225_000, testedWireKbps: 150_000, hostLinkKbps: 1_000_000)
        #expect(tested.reason == .testedLimited)
        #expect(tested.kbps == 150_000)
        // Unknown host link (0) is ignored
        #expect(recommend(staticKbps: 225_000, testedWireKbps: 340_000, hostLinkKbps: 0).reason == .testedOK)
    }

    @Test func theRecommendationIsRoundedDownToTheSliderStepAndNeverBelowTheProbeFloor() {
        #expect(recommend(staticKbps: 225_000, testedWireKbps: 178_000).kbps == 175_000)
        #expect(recommend(staticKbps: 225_000, testedWireKbps: 5_000).kbps == 5_000)
    }

    @Test func aTestedBudgetAlsoReportsThePictureItCarries() {
        let transport = WireTransport(packetSize: 1392, criticalFECPercent: 50)
        #expect(recommend(staticKbps: 225_000, testedWireKbps: 180_000, fps: 60, transport: transport).pictureKbps == 102_370)
        #expect(recommend(staticKbps: 225_000, fps: 60, transport: transport).pictureKbps == -1)
        #expect(recommend(staticKbps: 225_000, testedWireKbps: 180_000).pictureKbps == -1)
    }

    @Test func aLiveDropHintOnlyEverLowersTheOffer() {
        let lowered = recommend(staticKbps: 225_000, testedWireKbps: 340_000, live: drops)
        #expect(lowered.kbps == 135_000)
        #expect(lowered.reason == .dropping)
        #expect(lowered.droppedAtKbps == 225_000)
        // The tested budget is already lower than the live suggestion: it stays
        let tested = recommend(staticKbps: 225_000, testedWireKbps: 100_000, live: drops)
        #expect(tested.kbps == 100_000)
        #expect(tested.reason == .testedLimited)
        // A healthy reading changes nothing
        var keeping = drops
        keeping.verdict = .keepingUp
        keeping.suggestedKbps = 225_000
        #expect(recommend(staticKbps: 225_000, testedWireKbps: 340_000, live: keeping).reason == .testedOK)
        var tiny = drops
        tiny.suggestedKbps = 2_000
        #expect(recommend(staticKbps: 225_000, live: tiny).kbps >= LinkPolicy.minKbps)
    }

    @Test func theReasonNamesTheCeilingAndTheRecommendationCarriesBothNumbers() {
        let r = recommend(staticKbps: 225_000, testedWireKbps: 665_000)
        #expect(r.kbps == 225_000)
        #expect(r.testedKbps == 665_000)
        #expect(r.wantedKbps == 225_000)
    }

    @Test func anOrdinaryCodecsUsefulMaximumIsAMultipleOfTheAppsDefaultCapped() {
        #expect(ordinaryWantedKbps(.h264, defaultKbps: 20_000) == 60_000) // 1080p60
        #expect(ordinaryWantedKbps(.hevc, defaultKbps: 20_000) == 40_000)
        #expect(ordinaryWantedKbps(.av1, defaultKbps: 20_000) == 40_000)
        #expect(ordinaryWantedKbps(.automatic, defaultKbps: 20_000) == 40_000)
        #expect(ordinaryWantedKbps(.hevc, defaultKbps: 80_000) == 150_000) // 4K60: 160 capped
        #expect(ordinaryWantedKbps(.h264, defaultKbps: 80_000) == 150_000)
    }

    @Test func anOrdinaryCodecIsOfferedItsDefaultUntilTestedThenAShareOfTheBudgetUpToItsMaximum() {
        let wanted = ordinaryWantedKbps(.hevc, defaultKbps: 20_000)
        let share = LinkPolicy.ordinaryBudgetShare
        let untested = recommend(staticKbps: wanted, share: share, untestedKbps: 20_000)
        #expect(untested.kbps == 20_000)
        #expect(untested.reason == .untested)
        let plenty = recommend(staticKbps: wanted, testedWireKbps: 665_000, share: share, untestedKbps: 20_000)
        #expect(plenty.kbps == 40_000)
        #expect(plenty.reason == .testedOK)
    }

    @Test func aLinkThatCannotCarryTheMaximumWithMarginLimitsAnOrdinaryCodec() {
        let wanted = ordinaryWantedKbps(.h264, defaultKbps: 20_000) // 60
        // 65 % of 80 = 52 < 60
        let limited = recommend(staticKbps: wanted, testedWireKbps: 80_000, share: 0.65, untestedKbps: 20_000)
        #expect(limited.kbps == 50_000)
        #expect(limited.reason == .testedLimited)
        // 65 % of 92 = 59.8: just under, still limited; of 93 = 60.45: enough
        #expect(recommend(staticKbps: wanted, testedWireKbps: 92_000, share: 0.65, untestedKbps: 20_000).reason == .testedLimited)
        #expect(recommend(staticKbps: wanted, testedWireKbps: 93_000, share: 0.65, untestedKbps: 20_000).reason == .testedOK)
        // A slow link goes under the plain default as well
        #expect(recommend(staticKbps: wanted, testedWireKbps: 16_000, share: 0.65, untestedKbps: 20_000).kbps == 10_000)
    }

    @Test func anOrdinaryCodecGetsNoPictureFigureAndIgnoresNothingAboutTheHostLink() {
        let transport = WireTransport(packetSize: 1392, criticalFECPercent: 50)
        #expect(recommend(staticKbps: 40_000, testedWireKbps: 665_000, fps: 60, transport: transport, share: 0.65).pictureKbps == -1)
        let host = recommend(staticKbps: 40_000, testedWireKbps: 665_000, hostLinkKbps: 50_000, share: 0.65, untestedKbps: 20_000)
        #expect(host.reason == .hostLinkLimited)
        #expect(host.kbps == 30_000)
    }
}
