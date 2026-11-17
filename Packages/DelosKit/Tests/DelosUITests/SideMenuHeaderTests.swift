@testable import DelosUI
import Testing

@Suite struct SideMenuHeaderTests {
    @Test func connectingWinsOverEverything() {
        #expect(SidePCState.of(reachability: .online, running: true, connecting: true, canWake: true) == .connecting)
        #expect(SidePCState.of(reachability: .offline, running: false, connecting: true, canWake: false) == .connecting)
    }

    @Test func anOnlinePCStreamsWhileItRunsAGame() {
        #expect(SidePCState.of(reachability: .online, running: true, connecting: false, canWake: false) == .streaming)
        #expect(SidePCState.of(reachability: .online, running: false, connecting: false, canWake: false) == .online)
    }

    @Test func anOfflinePCSleepsWhenItCanBeWokenAndAnUnansweredOneConnects() {
        #expect(SidePCState.of(reachability: .offline, running: false, connecting: false, canWake: true) == .asleep)
        #expect(SidePCState.of(reachability: .offline, running: true, connecting: false, canWake: false) == .offline)
        #expect(SidePCState.of(reachability: .unknown, running: false, connecting: false, canWake: true) == .connecting)
    }
}
