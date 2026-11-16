import DelosCore
import DelosInput
import DelosMedia
import Foundation
import Observation
import OSLog

/// The display a stream is shown on, in pixels.
struct DisplayInfo: Equatable, Sendable {
    var pixelWidth: Int
    var pixelHeight: Int
    /// The highest refresh rate (120 on ProMotion iPhones and iPads).
    var maxFramesPerSecond: Int
}

/// The steps of one stream that talk to the PC and the streaming core. ``LiveStream`` is the real one; tests drive
/// the ``StreamController`` with a fake. Each instance is one attempt: Try again makes a new one.
@MainActor
protocol StreamSteps: AnyObject {
    var pcName: String { get }
    var appName: String { get }
    /// The core's reports of this attempt; must exist before ``connect()``.
    var events: AsyncStream<StreamEvent> { get }
    /// Where input goes once the stream runs; nil without a real session.
    var input: (any StreamInputSink)? { get }
    var statisticsSource: StreamStatisticsSource? { get }
    /// Asks the PC and launches the app, or resumes it when it already runs.
    func launch(display: DisplayInfo) async throws(LaunchFailure)
    /// Connects the streaming core; returns once video and audio flow.
    func connect() async throws(StreamError)
    /// Disconnects; the app keeps running on the PC.
    func stop() async
    /// Asks the PC to quit the app; false when it did not.
    func quitApp() async -> Bool
}

extension StreamSteps {
    /// Attempts without a video renderer (including lifecycle tests) have no presentation telemetry.
    var statisticsSource: StreamStatisticsSource? { nil }
}

/// One stream on the screen (`DelosStreamActivity` with `StreamLoader` of DELOS for Android): launch, the connecting
/// stages, the running stream with its input, the stream menu, leaving, and the result of a stream that failed.
@MainActor
@Observable
final class StreamController {
    enum Phase: Equatable {
        /// Waiting for the display, launching and connecting.
        case connecting
        case streaming
        /// Disconnecting or quitting; the text says which.
        case leaving(String)
        /// The stream failed or ended with an error: the result overlay.
        case failed(ResultText)
        /// Over: the screen goes back.
        case ended
    }

    private(set) var phase = Phase.connecting
    /// "Calling up <PC>" and the line of the current stage.
    private(set) var greeting = ""
    private(set) var line = ""
    /// The loader's progress, 0…1: each stage adds 8 % up to 92 %, the running stream fills it (Android's
    /// `StreamLoader`).
    private(set) var progress = 0.0
    private(set) var menuOpen = false
    private(set) var statisticsEnabled = false
    private(set) var statistics: StreamStatistics?

    @ObservationIgnored private let makeSteps: @MainActor () -> any StreamSteps
    @ObservationIgnored private var steps: any StreamSteps
    @ObservationIgnored private var display: DisplayInfo?
    @ObservationIgnored private var attempt: Task<Void, Never>?
    @ObservationIgnored private var listener: Task<Void, Never>?
    /// Identifies the current attempt: what an attempt reports or returns after it ended is ignored.
    @ObservationIgnored private var attemptID = 0
    /// The stop of the attempts that ended. The core runs one connection at a time, so the next attempt launches only
    /// once this is over.
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var statisticsTask: Task<Void, Never>?
    @ObservationIgnored private(set) var input: GameInput?
    @ObservationIgnored private var trackpad = TouchTrackpad()
    @ObservationIgnored private var swipe = MenuSwipe()
    /// The app went to the background during the stream: the connection was closed and is opened again on return.
    @ObservationIgnored private(set) var suspended = false

    init(makeSteps: @escaping @MainActor () -> any StreamSteps) {
        self.makeSteps = makeSteps
        steps = makeSteps()
        greeting = L("stream_loader_greeting", steps.pcName)
    }

    /// Starts the stream on `display`; the first call starts it, later ones (the view laid out again) do nothing.
    func start(display: DisplayInfo) {
        guard self.display == nil else { return }
        self.display = display
        run()
    }

    /// Try again: the same game on the same PC with a new attempt, once the failed one has stopped (after a lost
    /// connection the session stops itself, and the core stays taken until it has).
    func retry() {
        guard case .failed = phase, display != nil else { return }
        endAttempt()
        steps = makeSteps()
        run()
    }

    private func run() {
        guard let display else { return }
        attemptID += 1
        let id = attemptID
        phase = .connecting
        progress = 0
        line = StageLines.line(.platform, pcName: steps.pcName)
        let steps = self.steps
        let cleanup = self.cleanup
        listener = Task { [weak self] in
            for await event in steps.events {
                self?.handle(event, from: id)
            }
        }
        attempt = Task { [weak self] in
            await cleanup?.value
            guard self?.isCurrent(id) == true else { return }
            do throws(LaunchFailure) {
                try await steps.launch(display: display)
            } catch {
                // An attempt that ended meanwhile was stopped by whoever ended it
                guard let self, self.isCurrent(id) else { return }
                self.fail(StreamText.launchFailure(error, pcName: steps.pcName, appName: steps.appName))
                await steps.stop()
                return
            }
            guard let self, self.isCurrent(id), self.phase == .connecting else { return }
            do throws(StreamError) {
                try await steps.connect()
                if self.isCurrent(id) { self.connected() }
            } catch {
                if self.isCurrent(id), let text = StreamText.startFailure(error) { self.fail(text) }
            }
        }
    }

    private func isCurrent(_ id: Int) -> Bool { id == attemptID }

    /// Ends the current attempt: its events and results are ignored from now on (a cancelled listener can still
    /// deliver what was queued, a cancelled launch can still return), and its stop joins ``cleanup``. Returns that.
    @discardableResult
    private func endAttempt() -> Task<Void, Never> {
        attemptID += 1
        listener?.cancel()
        attempt?.cancel()
        listener = nil
        attempt = nil
        let steps = self.steps
        let previous = cleanup
        let stop = Task {
            await steps.stop()
            await previous?.value
        }
        cleanup = stop
        return stop
    }

    private func handle(_ event: StreamEvent, from id: Int) {
        guard isCurrent(id) else { return }
        switch event {
        case .stageStarting(let stage):
            guard phase == .connecting else { return }
            line = StageLines.line(StageLines.group(stage), pcName: steps.pcName)
            progress = min(progress + 0.08, 0.92)
        case .connectionStarted:
            connected()
        case .terminated(let termination):
            guard phase == .streaming || phase == .connecting else { return }
            stopStatistics()
            stopInput()
            if let text = StreamText.termination(termination) { fail(text) } else { phase = .ended }
        case let .rumble(controller, low, high):
            input?.rumble(controller: controller, low: low, high: high)
        case let .triggerRumble(controller, left, right):
            input?.rumbleTriggers(controller: controller, left: left, right: right)
        default:
            break
        }
    }

    private func connected() {
        guard phase == .connecting else { return }
        phase = .streaming
        progress = 1
        if let sink = steps.input, input == nil {
            let input = GameInput(sink: sink) { [weak self] in self?.openMenu() }
            input.start()
            self.input = input
        }
        startStatistics()
    }

    private func fail(_ text: ResultText) {
        // Once the player leaves or the app goes to the background, what the interrupted attempt throws is no failure
        guard !suspended, phase == .connecting || phase == .streaming else { return }
        stopStatistics()
        stopInput()
        menuOpen = false
        phase = .failed(text)
    }

    private func stopInput() {
        input?.stop()
        input = nil
    }

    // MARK: Menu

    func openMenu() {
        guard phase == .streaming, !menuOpen else { return }
        menuOpen = true
        input?.paused = true
    }

    func closeMenu() {
        guard menuOpen else { return }
        menuOpen = false
        input?.paused = false
    }

    func toggleStatistics() {
        statisticsEnabled.toggle()
    }

    private func startStatistics() {
        guard let source = steps.statisticsSource else { return }
        statisticsTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1))
                    let reading = await source.sample()
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    self.statistics = reading
                }
            } catch is CancellationError {
                // Leaving, termination and suspension cancel the sampler before the core stops.
            } catch {
                Logger(subsystem: "io.github.meitoncz.delos", category: "StreamStatistics")
                    .error("Statistics sampling clock failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func stopStatistics() {
        statisticsTask?.cancel()
        statisticsTask = nil
        statistics = nil
    }

    // MARK: Background

    /// The app goes to the background. iOS suspends it and the connection would break while it is away (the owner
    /// came back to a black screen and a failure), so the stream is closed now, as Disconnect does: the game keeps
    /// running on the PC. The loader shows until ``returnedToForeground()`` connects again. Synchronous, so a return
    /// right after it finds the stream suspended; the returned task ends when the connection is closed.
    @discardableResult
    func enteredBackground() -> Task<Void, Never>? {
        guard phase == .connecting || phase == .streaming, !suspended else { return nil }
        stopStatistics()
        suspended = true
        menuOpen = false
        stopInput()
        phase = .connecting
        progress = 0
        return endAttempt()
    }

    /// The app is back: the same game is resumed on the PC with a new connection, launched once the closed one has
    /// stopped.
    func returnedToForeground() {
        guard suspended else { return }
        suspended = false
        steps = makeSteps()
        run()
    }

    // MARK: Leaving

    /// Leaves the stream: Disconnect (`quit` false) keeps the app running on the PC, Quit app ends it there too.
    func leave(quit: Bool) async {
        switch phase {
        case .leaving, .ended: return
        case .failed:
            phase = .ended
            return
        case .connecting, .streaming:
            break
        }
        stopStatistics()
        menuOpen = false
        // No return from the background starts another attempt now; the one that ran is the one the PC quits
        suspended = false
        let steps = self.steps
        phase = .leaving(quit ? L("stream_exit_quitting", steps.appName) : L("stream_exit_disconnecting"))
        stopInput()
        await endAttempt().value
        if quit, await !steps.quitApp() {
            phase = .failed(StreamText.quitFailure(appName: steps.appName))
            return
        }
        phase = .ended
    }

    /// Back to library on the result overlay.
    func dismiss() {
        if case .failed = phase { phase = .ended }
    }

    // MARK: Touch

    enum TouchPhase { case began, moved, ended, cancelled }

    /// A touch on the stream, in pixels of a screen `width` pixels wide: the left-edge swipe opens the menu, the other
    /// touches are the PC's trackpad.
    func touch(_ id: Int, _ touchPhase: TouchPhase, at point: CGPoint, width: CGFloat, time: TimeInterval) {
        guard phase == .streaming, !menuOpen else { return }
        switch touchPhase {
        case .began:
            if swipe.began(id, x: point.x, width: width) { return }
            trackpad.began(id, at: point, time: time)
        case .moved:
            let (owned, open) = swipe.moved(id, x: point.x, width: width)
            if open { openMenu() }
            if owned { return }
            trackpad.moved(id, to: point).forEach { input?.send($0) }
        case .ended:
            if swipe.ended(id) { return }
            trackpad.ended(id, time: time).forEach { input?.send($0) }
        case .cancelled:
            if swipe.ended(id) { return }
            trackpad.cancelled(id)
        }
    }

    /// Whether a mouse is connected, whose pointer touches are already the PC's mouse.
    var hasMouse: Bool { input?.hasMouse ?? false }
}
