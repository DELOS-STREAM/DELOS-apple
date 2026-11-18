import DelosData
import DelosHost
import Foundation
import Testing
@testable import DelosUI

/// A clock the test moves: sleepers wake in the order of their deadlines, and what they do on waking runs before the
/// next one wakes.
@MainActor
final class FakeConnectClock: ConnectClock {
    private(set) var time = 0.0
    private var sleepers: [(id: Int, deadline: Double, continuation: CheckedContinuation<Void, any Error>)] = []
    private var counter = 0

    func now() -> Double { time }

    var sleeping: Int { sleepers.count }

    func sleep(seconds: Double) async throws {
        try Task.checkCancellation()
        counter += 1
        let id = counter
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers.append((id, time + seconds, continuation))
            }
        } onCancel: {
            Task { @MainActor in self.cancelSleeper(id) }
        }
    }

    private func cancelSleeper(_ id: Int) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Lets everything that can run without time run.
    func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    func advance(by seconds: Double) async {
        let target = time + seconds
        while true {
            await settle()
            guard let next = sleepers.filter({ $0.deadline <= target }).min(by: { $0.deadline < $1.deadline }) else { break }
            sleepers.removeAll { $0.id == next.id }
            time = max(time, next.deadline)
            next.continuation.resume()
        }
        time = target
        await settle()
    }
}

/// The PCs and the network of the flow, as the test sets them.
@MainActor
final class FakeConnectEnvironment: ConnectEnvironment {
    var names: [String: String] = ["A": "Desk"]
    var online: Set<String> = []
    var wakeResult = HostStore.WakeResult.sent
    private(set) var wakes: [String] = []
    private(set) var refreshes = 0
    private(set) var libraryLoads = 0
    private(set) var cues: [Cue] = []
    private(set) var toasts: [(text: String, icon: String, kind: ToastKind)] = []
    private(set) var arrived: [String] = []
    /// Runs on every refresh (the PC answers or not).
    var onRefresh: @MainActor (Int) -> Void = { _ in }
    /// What loading the apps takes.
    var loadLibraryBody: @MainActor () async -> Void = {}

    func hostName(_ id: String) -> String? { names[id] }
    func isOnline(_ id: String) -> Bool { online.contains(id) }
    func wake(_ id: String) async -> HostStore.WakeResult {
        wakes.append(id)
        return wakeResult
    }
    func refresh(_ id: String) async {
        refreshes += 1
        onRefresh(refreshes)
    }
    func loadLibrary(_ id: String) async {
        libraryLoads += 1
        await loadLibraryBody()
    }
    func play(_ cue: Cue) { cues.append(cue) }
    func toast(_ text: String, icon: String, kind: ToastKind) { toasts.append((text, icon, kind)) }
    func arrive(_ id: String) { arrived.append(id) }

    var transport = LinkTransport.wifi
    private(set) var linkTests: [(id: String, startKbps: Int)] = []
    private(set) var stored: [(id: String, test: LinkTest)] = []
    /// What the link test does: it hears its steps and ends with a result.
    var linkBody: @MainActor (@escaping @MainActor (LinkStep) -> Void) async -> LinkTestRun = { _ in .cancelled }
    func testLink(_ id: String, startKbps: Int, transport: LinkTransport, onStep: @escaping @MainActor (LinkStep) -> Void) async -> LinkTestRun {
        linkTests.append((id, startKbps))
        return await linkBody(onStep)
    }
    func storeLinkTest(_ id: String, _ test: LinkTest) { stored.append((id, test)) }
}

/// The link test's portal (`ShellDeviceActions.testLink`, DeviceFlows.kt:148-192).
@MainActor
@Suite struct LinkTestFlowTests {
    private let clock = FakeConnectClock()
    private let environment = FakeConnectEnvironment()
    private let flow: ConnectFlow
    private let test = LinkTest(wireKbps: 225_000, testedAtMs: 1, transport: .wifi, criticalFECPercent: 50, packetSize: 1392)

    init() {
        environment.online = ["A"]
        flow = ConnectFlow(environment: environment, clock: clock)
    }

    @Test func thePortalSaysWhatIsTestedStepByStepAndTheResultIsKept() async {
        let clock = clock, test = test
        environment.linkBody = { onStep in
            try? await clock.sleep(seconds: 1)
            onStep(LinkStep(kbps: 150_000, confirming: false, probe: 1))
            try? await clock.sleep(seconds: 1)
            onStep(LinkStep(kbps: 225_000, confirming: true, probe: 2))
            try? await clock.sleep(seconds: 1)
            return .done(test, jitter: false)
        }
        flow.testLink("A", startKbps: 150_000)
        await clock.settle()
        #expect(environment.linkTests.map(\.startKbps) == [150_000])
        #expect(flow.phase == .testingLink && flow.isActive)
        #expect(flow.portal?.icon == Symbols.linkTest)
        #expect(flow.portal?.label == "Testing the link to Desk")
        #expect(flow.portal?.sub == "Stay on Wi-Fi · B cancels")
        #expect(flow.portal?.cancellable == true)
        await clock.advance(by: 1)
        #expect(flow.portal?.sub == "Testing 150 Mbps · stay on Wi-Fi · B cancels")
        await clock.advance(by: 1)
        #expect(flow.portal?.sub == "Confirming 225 Mbps · stay on Wi-Fi · B cancels")
        await clock.advance(by: 1)
        #expect(flow.portal == nil && flow.phase == .idle && !flow.isActive)
        #expect(environment.stored.map(\.id) == ["A"] && environment.stored.first?.test == test)
        #expect(environment.cues == [.open, .select])
        #expect(environment.toasts.map(\.text) == ["Wi-Fi carries 225 Mbps"])
        #expect(environment.toasts.first?.icon == Symbols.checkCircle && environment.toasts.first?.kind == .success)
        #expect(environment.arrived.isEmpty && environment.wakes.isEmpty)
    }

    @Test func aLittleJitterIsSaid() async {
        let test = test
        environment.linkBody = { _ in .done(test, jitter: true) }
        flow.testLink("A", startKbps: 150_000)
        await clock.settle()
        #expect(environment.toasts.map(\.text) == ["Wi-Fi carries 225 Mbps (a little jitter)"])
    }

    @Test func aFailureIsSaidAndNothingIsKept() async {
        environment.linkBody = { _ in .failed(.udpBlocked) }
        flow.testLink("A", startKbps: 150_000)
        await clock.settle()
        #expect(environment.stored.isEmpty)
        #expect(environment.cues == [.open, .error])
        #expect(environment.toasts.map(\.text) == ["No test data arrived. UDP may be blocked on this network."])
        #expect(environment.toasts.first?.icon == Symbols.error && environment.toasts.first?.kind == .error)
        #expect(flow.portal == nil)
    }

    @Test func noRateSaysTheLastProbesReason() async {
        environment.linkBody = { _ in .noRate(last: nil, bestPassKbps: 0) }
        flow.testLink("A", startKbps: 150_000)
        await clock.settle()
        #expect(environment.toasts.map(\.text) == ["No rate could be tested."])
    }

    @Test func backStopsTheTest() async {
        let clock = clock
        environment.linkBody = { _ in
            do { try await clock.sleep(seconds: 60) } catch { return .cancelled }
            return .failed(.network)
        }
        flow.testLink("A", startKbps: 150_000)
        await clock.settle()
        flow.cancel()
        await clock.settle()
        #expect(flow.portal == nil && flow.phase == .idle)
        #expect(environment.cues == [.open, .back])
        #expect(environment.toasts.map(\.text) == ["Link test stopped"])
        #expect(environment.toasts.first?.icon == Symbols.info)
        #expect(environment.stored.isEmpty)
    }

    @Test func nothingStartsWhileAPortalIsUp() async {
        let clock = clock
        environment.linkBody = { _ in
            try? await clock.sleep(seconds: 60)
            return .cancelled
        }
        flow.testLink("A", startKbps: 150_000)
        await clock.settle()
        flow.testLink("A", startKbps: 150_000)
        flow.connect("A")
        await clock.settle()
        #expect(environment.linkTests.count == 1)
        #expect(environment.libraryLoads == 0)
    }
}

@MainActor
@Suite struct ConnectFlowTests {
    private let clock = FakeConnectClock()
    private let environment = FakeConnectEnvironment()
    private let flow: ConnectFlow

    init() {
        flow = ConnectFlow(environment: environment, clock: clock)
    }

    @Test func anOnlinePCIsNotWokenAndItsLibraryOpensAfterTheMinimumTimeInThePortal() async {
        environment.online = ["A"]
        flow.connect("A")
        await clock.settle()
        #expect(environment.wakes.isEmpty)
        #expect(flow.phase == .connecting)
        #expect(flow.portal?.label == L("devices_portal_connecting_title", "Desk"))
        #expect(flow.portal?.sub == L("devices_portal_connecting_note"))
        #expect(flow.portal?.cancellable == false)
        #expect(environment.libraryLoads == 1)

        await clock.advance(by: 2.0)
        #expect(flow.phase == .connecting && !flow.burst)
        await clock.advance(by: 0.1)
        #expect(flow.phase == .arriving && flow.burst)
        #expect(environment.arrived.isEmpty)
        await clock.advance(by: ConnectFlow.Timing.burstToLibrary)
        #expect(environment.arrived == ["A"])
        #expect(flow.portal == nil && flow.burst)
        await clock.advance(by: ConnectFlow.Timing.burstEnd)
        #expect(flow.phase == .idle && !flow.burst)
        #expect(environment.cues == [.open, .select])
        #expect(environment.toasts.isEmpty)
    }

    @Test func reducedMotionShortensTheMinimumTimeToSixHundredMilliseconds() async {
        environment.online = ["A"]
        flow.reducedMotion = true
        flow.connect("A")
        await clock.advance(by: 0.5)
        #expect(flow.phase == .connecting)
        await clock.advance(by: 0.15)
        #expect(flow.phase == .arriving)
    }

    @Test func aSleepingPCIsWokenAndWaitedForThenItsLibraryOpens() async {
        flow.connect("A")
        await clock.settle()
        #expect(environment.wakes == ["A"])
        #expect(flow.phase == .waking)
        #expect(flow.portal?.icon == Symbols.wake)
        #expect(flow.portal?.label == L("devices_portal_waking_title", "Desk"))
        #expect(flow.portal?.sub == L("devices_portal_waking_note", "B"))
        #expect(flow.portal?.cancellable == true)

        // The PC answers at its third ask, about 6 s in: it is asked again every 3 s
        environment.onRefresh = { [environment] count in if count == 3 { environment.online = ["A"] } }
        await clock.advance(by: 5.9)
        #expect(flow.phase == .waking)
        #expect(environment.refreshes == 2)
        await clock.advance(by: 0.2)
        #expect(environment.refreshes == 3)
        #expect(flow.phase == .connecting)
        #expect(flow.portal?.label == L("devices_portal_connecting_title", "Desk"))
        await clock.advance(by: 2.1 + ConnectFlow.Timing.burstToLibrary + 0.01)
        #expect(environment.arrived == ["A"])
        #expect(environment.cues == [.open, .select])
        #expect(environment.wakes == ["A"])
    }

    @Test func aPCThatCannotBeWokenIsWaitedForWithTheTurnItOnLine() async {
        environment.wakeResult = .noMAC
        flow.connect("A")
        await clock.settle()
        #expect(flow.phase == .waiting)
        #expect(flow.portal?.label == L("devices_portal_waiting_title", "Desk"))
        #expect(flow.portal?.sub == L("devices_portal_waiting_note", "B"))
        #expect(flow.portal?.cancellable == true)
        // The user turns it on: it is found online and the library opens
        environment.online = ["A"]
        await clock.advance(by: 3.1)
        #expect(flow.phase == .connecting)
    }

    @Test func aWakePacketThatCouldNotBeSentWaitsLikeAPCWithoutAMACAddress() async {
        environment.wakeResult = .failed
        flow.connect("A")
        await clock.settle()
        #expect(flow.phase == .waiting)
        #expect(flow.portal?.label == L("devices_portal_waiting_title", "Desk"))
    }

    @Test func aPCThatDoesNotWakeInTwoMinutesEndsWithAToastAndCanBeTriedAgain() async {
        flow.connect("A")
        await clock.advance(by: 119)
        #expect(flow.phase == .waking)
        await clock.advance(by: 3.1)
        #expect(flow.phase == .idle && flow.portal == nil)
        #expect(environment.toasts.count == 1)
        #expect(environment.toasts[0].text == L("devices_wake_timeout_toast", "Desk"))
        #expect(environment.toasts[0].icon == Symbols.wake)
        #expect(environment.toasts[0].kind == .error)
        #expect(environment.cues == [.open, .error])
        #expect(environment.arrived.isEmpty)
        #expect(environment.refreshes <= 42)

        // Pressing the PC again wakes it again
        flow.connect("A")
        await clock.settle()
        #expect(environment.wakes == ["A", "A"])
        #expect(flow.phase == .waking)
    }

    @Test func backCancelsTheWaitWithoutAToastAndTheAskingStops() async {
        flow.connect("A")
        await clock.advance(by: 4)
        let asked = environment.refreshes
        flow.cancel()
        await clock.settle()
        #expect(flow.portal == nil && flow.phase == .idle)
        #expect(environment.cues == [.open, .back])
        #expect(environment.toasts.isEmpty)
        await clock.advance(by: 30)
        #expect(environment.refreshes == asked)
        #expect(environment.arrived.isEmpty)
        #expect(clock.sleeping == 0)
    }

    @Test func backDoesNothingWhileTheLibraryIsConnecting() async {
        environment.online = ["A"]
        flow.connect("A")
        await clock.settle()
        flow.cancel()
        #expect(environment.cues == [.open])
        await clock.advance(by: 2.2 + ConnectFlow.Timing.burstToLibrary)
        #expect(environment.arrived == ["A"])
    }

    @Test func aSlowLibraryIsWaitedForAtMostFiveSeconds() async {
        environment.online = ["A"]
        environment.loadLibraryBody = { [clock] in try? await clock.sleep(seconds: 60) }
        flow.connect("A")
        await clock.advance(by: 4.9)
        #expect(flow.phase == .connecting)
        await clock.advance(by: 0.2)
        #expect(flow.phase == .arriving)
        await clock.advance(by: ConnectFlow.Timing.burstToLibrary)
        #expect(environment.arrived == ["A"])
        await clock.advance(by: ConnectFlow.Timing.burstEnd)
        #expect(clock.sleeping == 0)
    }

    @Test func aLibraryThatIsReadyEarlyStillWaitsForTheMinimumTime() async {
        environment.online = ["A"]
        environment.loadLibraryBody = { [clock] in try? await clock.sleep(seconds: 0.5) }
        flow.connect("A")
        await clock.advance(by: 2.0)
        #expect(flow.phase == .connecting)
        await clock.advance(by: 0.2)
        #expect(flow.phase == .arriving)
    }

    @Test func aSecondPressWhileThePortalIsUpIsIgnored() async {
        flow.connect("A")
        await clock.settle()
        flow.connect("A")
        await clock.settle()
        #expect(environment.wakes == ["A"])
        #expect(environment.cues == [.open])
    }

    @Test func aPCThatWasRemovedOpensNothing() async {
        environment.names = [:]
        flow.connect("A")
        await clock.settle()
        #expect(flow.portal == nil && flow.phase == .idle)
        #expect(environment.cues.isEmpty && environment.wakes.isEmpty)
    }

    @Test func theTimesOfTheFlowAreTheOnesOfAndroid() {
        #expect(ConnectFlow.Timing.wakeTimeout == 120)
        #expect(ConnectFlow.Timing.libraryTimeout == 5)
        #expect(ConnectFlow.Timing.connecting == 2.1)
        #expect(ConnectFlow.Timing.connectingReduced == 0.6)
    }
}

@Suite struct PortalLookTests {
    @Test func theRingsStartOneAfterTheOtherAndRepeatEveryPeriod() {
        #expect(PortalLook.ringPhase(index: 0, time: 0) == 0)
        #expect(PortalLook.ringPhase(index: 1, time: 0.3) == nil)
        #expect(PortalLook.ringPhase(index: 1, time: 0.35) == 0)
        #expect(abs((PortalLook.ringPhase(index: 3, time: 1.05 + 1.1) ?? -1) - 0.5) < 1e-9)
        #expect(abs((PortalLook.ringPhase(index: 0, time: 2.2 + 0.55) ?? -1) - 0.25) < 1e-9)
    }

    @Test func aRingFadesInOverTheFirstQuarterAndOutAfterIt() {
        #expect(PortalLook.ringAlpha(0) == 0)
        #expect(abs(PortalLook.ringAlpha(0.25) - 1) < 1e-9)
        #expect(PortalLook.ringAlpha(0.999) < 0.01)
        #expect(PortalLook.ringAlpha(0.1) > 0 && PortalLook.ringAlpha(0.1) < 1)
    }

    @Test func aRingGrowsFromAThirdOfItsSizeToThreeAndAHalfTimes() {
        #expect(abs(PortalLook.ringRadius(0) - 150 * 0.35) < 1e-9)
        #expect(abs(PortalLook.ringRadius(1) - 150 * 3.4) < 1e-9)
    }
}
