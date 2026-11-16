import Testing
@testable import DelosUI

@MainActor
@Suite struct FeedbackTests {
    @Test func everyCueHasItsSoundInTheBundle() {
        #expect(Feedback().allSoundsLoaded)
    }
}
