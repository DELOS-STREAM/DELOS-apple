import DelosCore
import DelosData
import DelosHost
import DelosInput
import DelosMedia
import Foundation

/// The real steps of a stream (`NvConnection.startApp` and the stream start of DELOS for Android): ask the PC again
/// over its pinned connection, launch the app (resume it when it already runs; another running app is never quit here), then connect
/// the streaming core with the video and audio outputs.
@MainActor
final class LiveStream: StreamSteps {
    let pcName: String
    private(set) var appName: String
    let events: AsyncStream<StreamEvent>
    var input: (any StreamInputSink)? { session }
    private(set) var serverCommands: [String] = []
    let statisticsSource: StreamStatisticsSource?

    private let hosts: HostStore
    private let hostID: String
    private let appID: Int
    private let session: StreamSession
    private let formats: VideoFormats
    private let settings: StreamSettings
    private var client: (HostClient, HostPin)?
    private var plan: (server: ServerInformation, configuration: StreamConfiguration)?
    private let toast: @MainActor (String, ToastKind) -> Void
    private(set) var clipboard: ClipboardSync?

    /// - Parameters:
    ///   - settings: the current profile's stream settings (Settings → Stream).
    ///   - toast: shows a toast over the stream (the clipboard sync's reports).
    init(
        hosts: HostStore, hostID: String, appID: Int, settings: StreamSettings, renderer: any VideoRenderer,
        toast: @escaping @MainActor (String, ToastKind) -> Void = { _, _ in }
    ) {
        self.toast = toast
        self.hosts = hosts
        self.settings = settings
        self.hostID = hostID
        self.appID = appID
        pcName = hosts.host(hostID)?.name ?? L("stream_result_default_pc")
        appName = hosts.apps[hostID]?.first { $0.id == appID }?.title ?? ""
        formats = DecoderSupport.device
        let watchdog = WatchdogVideoRenderer(renderer: renderer)
        let video = VideoOutput(renderer: watchdog, supportedFormats: formats)
        session = StreamSession(videoSink: video, audioSink: AudioOutput())
        // Debug builds: the throughput line reads the core's FEC and reordering counters of this stream (weakly: the line
        // is global and must not keep a finished stream's renderer alive)
        StreamPerf.standard?.setPacketSource { [weak session] in session?.videoStatistics() }
        statisticsSource = StreamStatisticsSource(video: video.statistics, renderer: renderer, session: session, watchdog: watchdog)
        events = session.events
    }

    func launch(display: DisplayInfo) async throws(LaunchFailure) {
        // A fresh answer: whether the PC is there, still knows this device, and what it runs
        await hosts.refresh(hostID)
        guard let record = hosts.host(hostID), record.reachability != .offline else { throw .offline }
        guard record.lastReplyVerified else { throw .notPaired }
        let client: HostClient, pin: HostPin
        do {
            (client, _, pin) = try hosts.pairedClient(hostID)
        } catch {
            throw .offline
        }
        var app = hosts.apps[hostID]?.first { $0.id == appID }
        if app == nil { app = try? await hosts.loadApps(hostID).first { $0.id == appID } }
        guard let app else { throw .appNotFound }
        appName = app.title

        // A metered network (NWPathMonitor: expensive or constrained) streams at the metered bitrate
        let metered = await NetworkPath.isMetered()
        let plan = StreamPlan(
            app: app, settings: settings, display: StreamResolution(width: display.pixelWidth, height: display.pixelHeight),
            decodable: formats, refreshRate: display.maxFramesPerSecond,
            displaySupportsHDR: HDRDisplay.isSupported,
            virtualDisplayReady: record.virtualDisplay?.capable == true && record.virtualDisplay?.driverReady == true,
            metered: metered)
        let nvidia = record.isNvidiaServer
        // What goes out (GeForce Experience gets 0 above 60 fps in the launch query): the throughput lines start from it.
        // The upscaler and Picture in Picture are what the stream starts with (the app's own settings over the profile's)
        StreamPerf.standard?.note(String(
            format: "launch mode=%dx%dx%g fps=%d refresh=%d pacing=%@ bitrate=%d nvidia=%d %@ pip=%d", plan.request.width,
            plan.request.height, plan.request.frameRate, plan.configuration.fps, display.maxFramesPerSecond,
            settings.framePacing.rawValue, plan.configuration.bitrateKbps, nvidia ? 1 : 0,
            StreamPerf.launchText(settings.upscalerSettings), settings.bool(.enablePip) ? 1 : 0))
        var sessionURL: String?
        let choice = LaunchChoice.of(app: appID, running: record.runningAppID)
        // Never quit another app unasked: the library's game menu is the confirmed way to quit it and start this one
        if choice == .otherAppRunning { throw .otherAppRunning }
        // A PC that is unlocking or whose server is still starting does not answer at first: it is asked again
        // (NvConnection.java:413-458, DelosStreamActivity.java:1657-1664)
        for attempt in 0... {
            do {
                switch choice {
                case .resume: sessionURL = try await client.resume(plan.request, nvidiaServer: nvidia, pin: pin)
                default: sessionURL = try await client.launch(plan.request, nvidiaServer: nvidia, pin: pin)
                }
                break
            } catch where LaunchRetry.isUnanswered(error) {
                let test = await PortTest.run(PortTest.launchPorts)
                if let failure = LaunchRetry.after(attempt: attempt, test: test) { throw failure }
                waiting?()
                try? await Task.sleep(for: LaunchRetry.pause)
                if Task.isCancelled { throw .offline }
            } catch {
                if choice == .resume { throw Self.resumeFailure(error) }
                if case HostError.hostStatus(code: 403, _) = error { throw .denied }
                throw .launchFailed(detail: Self.detail(error))
            }
        }
        self.client = (client, pin)
        clipboard = ClipboardSync(options: ClipboardSync.Options(settings), host: PairedClipboardHost(client: client, pin: pin), toast: toast)
        // The PC's commands for the menu's Commands page: asked in the background, the stream does not wait for them
        Task { [weak self] in
            guard let reply = try? await client.serverInfo(pin: pin), reply.source == .pinnedHTTPS else { return }
            self?.serverCommands = reply.info.serverCommands
        }
        self.plan = (StreamPlan.serverInformation(record, address: client.address, sessionURL: sessionURL), plan.configuration)
        warnings = StreamWarnings.of(settings: settings, decodable: formats, displaySupportsHDR: HDRDisplay.isSupported, metered: metered)
    }

    /// Called each time the PC did not answer the launch and is asked again (the loader's "unlocking" lines).
    var waiting: (@MainActor () -> Void)?
    /// The warnings of this launch (``StreamWarnings``); empty before ``launch(display:)``.
    private(set) var warnings: [String] = []
    /// The bitrate the stream was set up with.
    var bitrateKbps: Int? { plan?.configuration.bitrateKbps }

    func testPorts(_ ports: UInt32) async -> PortTest.Result {
        await PortTest.run(ports)
    }

    func connect() async throws(StreamError) {
        guard let plan else { throw .cancelled }
        try await session.start(server: plan.server, configuration: plan.configuration)
        // `checkbox_prevent_packet_loss`: empty payloads keep the device's Wi-Fi awake between frames
        if settings.bool(.preventPacketLoss) { await session.keepWiFiAwake() }
    }

    func stop() async {
        await session.stop()
    }

    func quitApp() async -> Bool {
        guard let (client, pin) = client else { return false }
        do {
            try await client.cancel(pin: pin)
            return true
        } catch {
            return false
        }
    }

    /// Vibepollo's paired HTTPS command (`NvConnection.setRuntimeBitrate`, NvConnection.java:508-513) to the PC this
    /// stream was launched on.
    func setRuntimeBitrate(_ kbps: Int) async throws -> Int {
        guard let (client, pin) = client else { throw HostError.unreachable("not launched") }
        return try await client.setRuntimeBitrate(kbps, pin: pin)
    }

    // MARK: The PC's answers (NvConnection.startApp)

    static func resumeFailure(_ error: any Error) -> LaunchFailure {
        switch error {
        case HostError.hostStatus(470, _): .resumeForeign(code: 470)
        case HostError.hostStatus(525, _): .appMinimized
        case HostError.hostStatus(403, _): .denied
        default: .resumeFailed(detail: detail(error))
        }
    }

    /// The technical text behind Details: the host's own message and status, or the error.
    static func detail(_ error: any Error) -> String {
        switch error {
        case let HostError.hostStatus(code, message?): "\(message) (\(code))"
        default: String(describing: error)
        }
    }
}

/// What a launch does with what the PC runs. Quitting another app is the player's choice, made in the library's game
/// menu before the stream opens; a launch, a retry and the return from the background never make it.
enum LaunchChoice: Equatable {
    case launch, resume, otherAppRunning

    /// [running]: the app id the PC reports (0: none).
    static func of(app: Int, running: Int) -> LaunchChoice {
        running == 0 ? .launch : running == app ? .resume : .otherAppRunning
    }
}
