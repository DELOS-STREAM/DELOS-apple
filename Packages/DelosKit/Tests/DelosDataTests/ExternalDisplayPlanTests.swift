import Testing
@testable import DelosData

struct ExternalDisplayPlanTests {
    @Test func aStreamGoesToTheSecondScreenOnlyInFullyExternalDisplayMode() {
        #expect(ExternalDisplayPlan.streamsOnSecond(secondConnected: true, fullExternal: true, streaming: true))
        // The mode off, no stream or no second screen: the screen is the system's (mirrored on iPhone and iPad)
        #expect(!ExternalDisplayPlan.streamsOnSecond(secondConnected: true, fullExternal: false, streaming: true))
        #expect(!ExternalDisplayPlan.streamsOnSecond(secondConnected: true, fullExternal: true, streaming: false))
        #expect(!ExternalDisplayPlan.streamsOnSecond(secondConnected: false, fullExternal: true, streaming: true))
    }
}
