import DelosData
import DelosHost
import DelosInput
import Foundation
import Observation

/// What the portal shows (`Portal` of DELOS for Android): the orb's icon, the PC's state in two lines, and whether B
/// cancels the wait. [arriving]: the end of a burst that began over the stream (the exit scene), shown at once and
/// without the orb.
struct Portal: Equatable {
    let id: Int
    let icon: String
    let label: String
    let sub: String
    let cancellable: Bool
    var arriving = false
}

/// The time of the connect flow: seconds on a clock that only moves forward, and sleeping on it. The real one is the
/// system's; tests drive their own.
@MainActor
protocol ConnectClock: AnyObject {
    func now() -> Double
    func sleep(seconds: Double) async throws
}

/// What the flow asks of the app: the PC's state, the network, and what the user hears, sees and gets to.
@MainActor
protocol ConnectEnvironment: AnyObject {
    func hostName(_ id: String) -> String?
    func isOnline(_ id: String) -> Bool
    /// Sends the Wake-on-LAN packet.
    func wake(_ id: String) async -> HostStore.WakeResult
    /// Asks the PC again and stores the answer.
    func refresh(_ id: String) async
    /// Loads the PC's apps so its library opens full.
    func loadLibrary(_ id: String) async
    func play(_ cue: Cue)
    func toast(_ text: String, icon: String, kind: ToastKind)
    /// Opens the PC's library.
    func arrive(_ id: String)
    /// The kind of network the device is on now.
    var transport: LinkTransport { get }
    /// The link test of the PC from [startKbps] on [transport] (`LinkTester.run`): a fresh answer of the PC, then the
    /// search; [onStep] hears every probe. Cancelling the task stops it.
    func testLink(_ id: String, startKbps: Int, transport: LinkTransport, onStep: @escaping @MainActor (LinkStep) -> Void) async -> LinkTestRun
    /// Keeps a confirmed result with its date (`LinkTestStore.put`).
    func storeLinkTest(_ id: String, _ test: LinkTest)
}

/// Connecting to a PC (`ShellDeviceActions.connect` of DELOS for Android): the portal opens, a PC that is not online is
/// woken up and waited for, the portal says it connects while the PC's apps load (at least 2.1 s, 0.6 s with reduced
/// motion, at most 5 s for the apps), bursts, and the library opens. B cancels the wait for a PC; the connecting step
/// that follows cannot be cancelled. A PC that does not answer in two minutes ends with a toast, and pressing it again
/// is the retry.
@MainActor
@Observable
final class ConnectFlow {
    enum Phase: Equatable {
        case idle
        /// The wake-up packet is being sent.
        case starting
        /// The packet went out; waiting for the PC to come online.
        case waking
        /// The PC cannot be woken from here (no MAC address, or the packet did not go): waiting for the user to turn it on.
        case waiting
        /// The PC is online; its apps load.
        case connecting
        /// The burst: the library opens under it.
        case arriving
        /// The link test runs (`testLink`).
        case testingLink
    }

    /// The times of the flow, in seconds (`DeviceFlows.kt`).
    enum Timing {
        static let wakeTimeout = 120.0
        static let libraryTimeout = 5.0
        /// The prototype's 2.1 s in the portal, 0.6 s with reduced motion.
        static let connecting = 2.1
        static let connectingReduced = 0.6
        /// From the burst to the library opening, and from there to the end of the burst.
        static let burstToLibrary = 0.38
        static let burstEnd = 0.5
        /// How often a PC that is being waited for is asked again.
        static let poll = 3.0
    }

    /// The Back button's name in the prompts ("B cancels") on the connected controller (circle on a PlayStation pad, A on a
    /// Nintendo one), where Android labels every pad like an Xbox pad.
    static var backButton: String { ControllerGlyphs.shared.mark(.east).text ?? "B" }

    private(set) var phase = Phase.idle
    private(set) var portal: Portal?
    /// The portal bursts into the library.
    private(set) var burst = false
    var reducedMotion = false

    @ObservationIgnored private let environment: ConnectEnvironment
    @ObservationIgnored private let clock: ConnectClock
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private var portals = 0

    init(environment: ConnectEnvironment, clock: ConnectClock) {
        self.environment = environment
        self.clock = clock
    }

    var isActive: Bool { portal != nil }

    /// Connects to the PC [hostID]; nothing while a portal is up.
    func connect(_ hostID: String) {
        guard portal == nil, task == nil else { return }
        task = Task { [weak self] in
            await self?.run(hostID)
            self?.task = nil
        }
    }

    /// B while a PC wakes up or the link is tested: stops it. The connecting step and the burst cannot be cancelled.
    func cancel() {
        guard portal?.cancellable == true else { return }
        environment.play(.back)
        task?.cancel()
    }

    /// Measures what the network carries from the PC [hostID] (`DeviceActions.testLink`), starting at [startKbps] (the
    /// selected bitrate): a portal that B cancels says what is being tested, the result is kept with its date and said in
    /// a toast. It never changes a setting. Nothing while a portal is up.
    func testLink(_ hostID: String, startKbps: Int) {
        guard portal == nil, task == nil else { return }
        task = Task { [weak self] in
            await self?.runLinkTest(hostID, startKbps: startKbps)
            self?.task = nil
        }
    }

    private func runLinkTest(_ id: String, startKbps: Int) async {
        guard let name = environment.hostName(id) else { return }
        portals += 1
        let number = portals
        let transport = environment.transport
        phase = .testingLink
        defer {
            portal = nil
            burst = false
            phase = .idle
        }
        environment.play(.open)
        showLinkPortal(number, name, L("devices_link_portal_start", transport.label, Self.backButton))
        let result = await environment.testLink(id, startKbps: startKbps, transport: transport) { [weak self] step in
            guard let self, portal?.id == number else { return }
            showLinkPortal(number, name, L(
                step.confirming ? "devices_link_portal_confirming" : "devices_link_portal_testing",
                linkMbps(step.kbps), transport.label, Self.backButton))
        }
        if Task.isCancelled {
            environment.toast(L("devices_link_stopped"), icon: Symbols.info, kind: .info)
            return
        }
        switch result {
        case .done(let test, let jitter):
            environment.storeLinkTest(id, test)
            environment.play(.select)
            environment.toast(
                L(jitter ? "devices_link_done_jitter" : "devices_link_done", transport.label, linkMbps(test.wireKbps)),
                icon: Symbols.checkCircle, kind: .success)
        case .failed, .noRate:
            environment.play(.error)
            environment.toast(result.failureText ?? "", icon: Symbols.error, kind: .error)
        case .cancelled:
            environment.toast(L("devices_link_stopped"), icon: Symbols.info, kind: .info)
        }
    }

    private func showLinkPortal(_ number: Int, _ name: String, _ sub: String) {
        burst = false
        portal = Portal(id: number, icon: Symbols.linkTest, label: L("devices_link_portal_title", name), sub: sub, cancellable: true)
    }

    private func run(_ id: String) async {
        guard let name = environment.hostName(id) else { return }
        portals += 1
        let number = portals
        var arrived = false
        phase = .starting
        defer {
            if !arrived {
                portal = nil
                burst = false
                phase = .idle
            }
        }
        do {
            environment.play(.open)
            if !environment.isOnline(id) {
                let sent = await environment.wake(id) == .sent
                try Task.checkCancellation()
                phase = sent ? .waking : .waiting
                portal = Portal(
                    id: number, icon: Symbols.wake,
                    label: L(sent ? "devices_portal_waking_title" : "devices_portal_waiting_title", name),
                    sub: L(sent ? "devices_portal_waking_note" : "devices_portal_waiting_note", Self.backButton),
                    cancellable: true)
                guard try await awaitOnline(id) else {
                    environment.play(.error)
                    environment.toast(L("devices_wake_timeout_toast", name), icon: Symbols.wake, kind: .error)
                    return
                }
            }
            burst = false
            phase = .connecting
            portal = Portal(
                id: number, icon: Symbols.desktopWindows, label: L("devices_portal_connecting_title", name),
                sub: L("devices_portal_connecting_note"), cancellable: false)
            let minimum = Task { [clock, reducedMotion] in
                try? await clock.sleep(seconds: reducedMotion ? Timing.connectingReduced : Timing.connecting)
            }
            defer { minimum.cancel() }
            // The PC's apps ready by then if possible
            await first(of: { [environment] in await environment.loadLibrary(id) }, timeout: Timing.libraryTimeout)
            await minimum.value
            try Task.checkCancellation()
            burst = true
            phase = .arriving
            environment.play(.select)
            try await clock.sleep(seconds: Timing.burstToLibrary)
            arrived = true
            environment.arrive(id)
            portal = nil
            try await clock.sleep(seconds: Timing.burstEnd)
        } catch {
            // Cancelled: the portal goes away without a word (the deferred reset)
        }
        if arrived {
            burst = false
            phase = .idle
        }
    }

    /// Asks the PC again until it is online or two minutes have passed (`PcRepository.awaitPc`). Throws when cancelled.
    private func awaitOnline(_ id: String) async throws -> Bool {
        let start = clock.now()
        while true {
            if environment.isOnline(id) { return true }
            await environment.refresh(id)
            try Task.checkCancellation()
            if environment.isOnline(id) { return true }
            if clock.now() - start >= Timing.wakeTimeout { return false }
            try await clock.sleep(seconds: Timing.poll)
        }
    }

    /// Runs [work] and returns when it is done or [timeout] seconds have passed, whichever is first; the other one is
    /// cancelled and not waited for.
    private func first(of work: @escaping @MainActor () async -> Void, timeout: Double) async {
        let (stream, done) = AsyncStream<Void>.makeStream()
        let job = Task { @MainActor in
            await work()
            done.yield()
        }
        let limit = Task { @MainActor [clock] in
            try? await clock.sleep(seconds: timeout)
            done.yield()
        }
        for await _ in stream { break }
        job.cancel()
        limit.cancel()
    }
}

/// The system's clock for the connect flow.
@MainActor
final class SystemConnectClock: ConnectClock {
    private let clock = ContinuousClock()
    private let origin = ContinuousClock.now

    func now() -> Double {
        let elapsed = origin.duration(to: clock.now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    func sleep(seconds: Double) async throws {
        try await clock.sleep(for: .seconds(seconds))
    }
}

/// The connect flow on the app's stores.
@MainActor
final class AppConnectEnvironment: ConnectEnvironment {
    private let hosts: HostStore
    private let toasts: Toasts
    private let layers: Layers
    private let open: @MainActor (String) -> Void

    init(hosts: HostStore, toasts: Toasts, layers: Layers, open: @escaping @MainActor (String) -> Void) {
        self.hosts = hosts
        self.toasts = toasts
        self.layers = layers
        self.open = open
    }

    func hostName(_ id: String) -> String? { hosts.host(id)?.name }
    func isOnline(_ id: String) -> Bool { hosts.host(id)?.reachability == .online }
    func wake(_ id: String) async -> HostStore.WakeResult { await hosts.wake(id) }
    func refresh(_ id: String) async { await hosts.refresh(id) }
    func loadLibrary(_ id: String) async { _ = try? await hosts.loadApps(id) }
    func play(_ cue: Cue) { layers.feedback?.play(cue) }
    func toast(_ text: String, icon: String, kind: ToastKind) { toasts.show(text, icon: icon, kind: kind) }
    func arrive(_ id: String) { open(id) }
    var transport: LinkTransport { .current }
    func testLink(_ id: String, startKbps: Int, transport: LinkTransport, onStep: @escaping @MainActor (LinkStep) -> Void) async -> LinkTestRun {
        await LinkTester.run(hosts: hosts, hostID: id, startKbps: startKbps, transport: transport, onStep: onStep)
    }
    func storeLinkTest(_ id: String, _ test: LinkTest) { LinkTestStore.shared.put(hostID: id, test: test) }
}
