import Testing
@testable import DelosData

struct ExternalDisplayPlanTests {
    @Test func aStreamGoesToTheSecondScreenOnlyInFullyExternalDisplayMode() {
        for role in [SecondDisplayRole.automatic, .external] {
            #expect(ExternalDisplayPlan.streamsOnSecond(secondConnected: true, role: role, fullExternal: true, streaming: true))
            // The mode off, no stream or no second screen: the screen is the system's (mirrored on iPhone and iPad)
            #expect(!ExternalDisplayPlan.streamsOnSecond(secondConnected: true, role: role, fullExternal: false, streaming: true))
            #expect(!ExternalDisplayPlan.streamsOnSecond(secondConnected: true, role: role, fullExternal: true, streaming: false))
            #expect(!ExternalDisplayPlan.streamsOnSecond(secondConnected: false, role: role, fullExternal: true, streaming: true))
        }
        // Part of the device: never a stream target
        #expect(!ExternalDisplayPlan.streamsOnSecond(secondConnected: true, role: .builtIn, fullExternal: true, streaming: true))
    }
}
