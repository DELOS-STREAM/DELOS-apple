import Testing
@testable import DelosData

@Suite struct MetadataPresentationTests {
    @Test func theHDRChipNeedsALookupThatFinishedWithoutPCGamingWikiFailing() {
        #expect(GameMetadata().hdrBadge == nil)
        #expect(GameMetadata(hdr: HDREvidence(support: .unknown), updatedAt: 5).hdrBadge == .unknown)
        #expect(GameMetadata(hdr: HDREvidence(support: .unknown), updatedAt: 5, pcgwFailedAt: 9).hdrBadge == nil)
        // A later failure does not invalidate evidence that was confirmed
        #expect(GameMetadata(hdr: HDREvidence(support: .hdr), updatedAt: 5, pcgwFailedAt: 9).hdrBadge == .hdr)
        #expect(GameMetadata(hdr: HDREvidence(support: .sdr), updatedAt: 5).hdrBadge == .sdr)
    }

    @Test func aCompletionTimeShowsOnlyWhenPositive() {
        #expect(GameMetadata().completionSeconds == nil)
        #expect(GameMetadata(completion: CompletionTime(id: 1, name: "g", seconds: 0, url: "")).completionSeconds == nil)
        #expect(GameMetadata(completion: CompletionTime(id: 1, name: "g", seconds: 7200, url: "")).completionSeconds == 7200)
    }

    @Test func lengthsRoundLikeHowLongToBeat() {
        #expect(CompletionLength(seconds: 29) == .minutes(0))
        #expect(CompletionLength(seconds: 45 * 60) == .minutes(45))
        #expect(CompletionLength(seconds: 3599) == .minutes(60))
        #expect(CompletionLength(seconds: 3600) == .hours(halves: 2))
        #expect(CompletionLength(seconds: 3 * 3600 + 1000) == .hours(halves: 7))
        #expect(CompletionLength(seconds: 100 * 3600 + 1799) == .hours(halves: 200))
        #expect(CompletionLength(seconds: 100 * 3600 + 1800) == .hours(halves: 202))
    }

    @Test func halfHoursShowAHalfAndTheUnitFollowsTheHoursRoundedUp() {
        let length = CompletionLength(seconds: 3 * 3600 + 1000)
        #expect(length.hoursText == "3\u{00BD}")
        #expect(length.quantity == 4)
        #expect(CompletionLength(seconds: 12 * 3600).hoursText == "12")
        #expect(CompletionLength.minutes(7).hoursText == nil)
        #expect(CompletionLength.minutes(7).quantity == 7)
    }
}
