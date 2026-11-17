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
    let statisticsSource: StreamStatisticsSource?

    private let hosts: HostStore
    private let hostID: String
    private let appID: Int
    private let session: StreamSession
    private let formats: VideoFormats
    private let settings: StreamSettings
    private var client: (HostClient, HostPin)?
    private var plan: (server: ServerInformation, configuration: StreamConfiguration)?

    /// - Parameter settings: the current profile's stream settings (Settings → Stream).
    init(hosts: HostStore, hostID: String, appID: Int, settings: StreamSettings, renderer: any VideoRenderer) {
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

        let plan = StreamPlan(
            app: app, settings: settings, display: StreamResolution(width: display.pixelWidth, height: display.pixelHeight),
            decodable: formats, refreshRate: display.maxFramesPerSecond,
            displaySupportsHDR: HDRDisplay.isSupported)
        let nvidia = record.isNvidiaServer
        let sessionURL: String?
        switch LaunchChoice.of(app: appID, running: record.runningAppID) {
        case .otherAppRunning:
            // Never quit another app unasked: the library's game menu is the confirmed way to quit it and start this one
            throw .otherAppRunning
        case .resume:
            do {
                sessionURL = try await client.resume(plan.request, nvidiaServer: nvidia, pin: pin)
            } catch {
                throw Self.resumeFailure(error)
            }
        case .launch:
            do {
                sessionURL = try await client.launch(plan.request, nvidiaServer: nvidia, pin: pin)
            } catch HostError.hostStatus(code: 403, _) {
                throw .denied
            } catch {
                throw .launchFailed(detail: Self.detail(error))
            }
        }
        self.client = (client, pin)
        self.plan = (StreamPlan.serverInformation(record, address: client.address, sessionURL: sessionURL), plan.configuration)
    }

    func connect() async throws(StreamError) {
        guard let plan else { throw .cancelled }
        try await session.start(server: plan.server, configuration: plan.configuration)
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
