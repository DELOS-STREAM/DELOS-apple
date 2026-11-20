import DelosCore
import DelosData
import DelosHost
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
    /// The names of the PC's server commands (Vibepollo and Apollo configure them); a command's number is its position.
    var serverCommands: [String] { get }
    /// Asks the PC and launches the app, or resumes it when it already runs.
    func launch(display: DisplayInfo) async throws(LaunchFailure)
    /// Connects the streaming core; returns once video and audio flow.
    func connect() async throws(StreamError)
    /// Disconnects; the app keeps running on the PC.
    func stop() async
    /// Asks the PC to quit the app; false when it did not.
    func quitApp() async -> Bool
    /// Vibepollo's live bitrate change of the running stream; returns the bitrate the host applied (``StreamBitrate``).
    func setRuntimeBitrate(_ kbps: Int) async throws -> Int
    /// The clipboard sync with the PC once ``launch(display:)`` knows it; nil before and without one.
    var clipboard: ClipboardSync? { get }
    /// Called each time the PC did not answer the launch and is asked again (the loader's "unlocking" lines).
    var waiting: (@MainActor () -> Void)? { get set }
    /// What the launch warns about (``StreamWarnings``), known once ``launch(display:)`` returned.
    var warnings: [String] { get }
    /// The bitrate the stream was set up with, in kbps; nil before the launch.
    var bitrateKbps: Int? { get }
    /// The core's connection test of [ports] (``PortTest``).
    func testPorts(_ ports: UInt32) async -> PortTest.Result
}

extension StreamSteps {
    /// Attempts without a video renderer (including lifecycle tests) have no presentation telemetry.
    var statisticsSource: StreamStatisticsSource? { nil }
    var serverCommands: [String] { [] }
    /// Without a PC that answers, a bitrate change is a command the host does not have (``BitrateFailure/unsupported``).
    func setRuntimeBitrate(_ kbps: Int) async throws -> Int { throw HostError.httpStatus(404) }
    var clipboard: ClipboardSync? { nil }
    var waiting: (@MainActor () -> Void)? {
        get { nil }
        set {}
    }
    var warnings: [String] { [] }
    var bitrateKbps: Int? { nil }
    /// Without the network the test cannot tell anything.
    func testPorts(_ ports: UInt32) async -> PortTest.Result { .inconclusive }
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

    private(set) var phase = Phase.connecting {
        // The keyboards belong to the running stream: not over the loader, the exit or the result overlay
        didSet {
            guard phase != .streaming else { return }
            systemKeyboardShown = false
            closeFullKeyboard()
        }
    }
    /// "Calling up <PC>" and the line of the current stage.
    private(set) var greeting = ""
    /// The game's name (the launch scene's title).
    var appName: String { steps.appName }
    /// The leaving that runs is Quit app (the exit scene's icon and text).
    private(set) var leavingQuit = false
    /// The leaving that runs comes from the stream menu: the exit scene plays, and the stream ends after ``leavingHold``.
    private(set) var leavingScene = false
    /// The PC's name (the exit scene's second line).
    var pcName: String { steps.pcName }
    /// How long a leaving from the stream menu keeps the exit scene up at least (`StreamExit`: 1.5 s, 0.7 s with reduced
    /// motion); the screen sets it. Zero: the stream ends as soon as it has stopped.
    @ObservationIgnored var leavingHold: Duration = .zero
    private(set) var line = ""
    /// The loader's progress, 0…1: each stage adds 8 % up to 92 %, the running stream fills it (Android's
    /// `StreamLoader`).
    private(set) var progress = 0.0
    private(set) var menuOpen = false
    /// What the statistics overlay shows: nothing, the full panel or the compact line (the Overlay tile goes round them).
    private(set) var statisticsOverlay = StatisticsOverlay.off
    /// The popover of the stream menu: which page is open and what has the focus in it.
    let menu = StreamMenuState()
    /// The live bitrate of the stream (the Bitrate page's Apply, ``applyBitrate(_:)``).
    let bitrate = StreamBitrate()
    /// What this device can do for the menu's tiles and pages (the brightness needs a device to set it on).
    let capabilities: StreamMenuCapabilities
    /// The screen's brightness in percent, in steps of 5 (the Brightness page's slider).
    private(set) var brightnessPercent = 100
    /// The system keyboard is wanted over the stream (More's Open system keyboard): it is raised while the menu is closed.
    private(set) var systemKeyboardShown = false
    /// The Delos full keyboard (the Keyboard tile): over the stream, it takes the controllers while it is up.
    let fullKeyboard: FullKeyboardState
    /// The profile's keyboard settings: sticky modifiers and vibration (`checkbox_enable_sticky_modifier_key_virtual_keyboard`,
    /// `checkbox_vibrate_keyboard`).
    @ObservationIgnored var keyboardOptions = FullKeyboardOptions()
    /// Plays the keyboard's vibrations (iPhone and iPad; the screen sets it).
    @ObservationIgnored var keyboardHaptic: (@MainActor (KeyHaptic) -> Void)?
    private(set) var statistics: StreamStatistics?
    /// "Poor connection" or "Slow connection" over the running stream while the core judges it so (``StreamWarnings``).
    private(set) var connectionNotice: String?
    /// The profile turned the stream's warnings off (`checkbox_disable_warnings`); the screen sets it.
    @ObservationIgnored var warningsDisabled = false
    /// The launch's warnings were shown for this stream.
    @ObservationIgnored private var warned = false

    /// The stream's bitrate now: what the Bitrate page applied last, else what the stream was set up with.
    var currentBitrateKbps: Int { bitrate.appliedKbps ?? steps.bitrateKbps ?? 0 }

    @ObservationIgnored private let makeSteps: @MainActor () -> any StreamSteps
    @ObservationIgnored private var steps: any StreamSteps
    /// The Send keys page's combinations: the built-in ones unless the profile cleared them, then the profile's custom ones
    /// (`GameMenu.specialKeyOptions`, ``StreamSpecialKeys``); the screen sets them.
    @ObservationIgnored var specialKeys: [SpecialKeys.Option] = SpecialKeys.all
    /// The profile's custom key file could not be read past some combination: the Send keys page says so when it opens.
    @ObservationIgnored var specialKeysFailed = false
    /// Shows a toast over the stream: its text, its kind and how long it stays (``ToastTiming/streamShortMs`` or
    /// ``ToastTiming/streamLongMs``, Android's `DelosToast.SHORT` and `LONG` of a stream).
    @ObservationIgnored var toast: (@MainActor (String, ToastKind?, Double) -> Void)?
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
    var rumbleConfiguration = RumbleConfiguration() {
        didSet { input?.rumbleConfiguration = rumbleConfiguration }
    }
    /// The touch screen, the pencil and the local pointer while the input runs (StreamController+Touch.swift).
    @ObservationIgnored var touchScreen: TouchScreen?
    /// The profile's touch and pointer settings; the picture the touches are measured against; where the surface was laid
    /// out; whether the stream is on another screen than the touches (only the trackpad modes work then).
    @ObservationIgnored var touchOptions = TouchOptions()
    @ObservationIgnored var touchPicture: TouchPicture?
    @ObservationIgnored var touchArea: TouchArea?
    @ObservationIgnored var touchOnExternalDisplay = false
    /// Where the zoom and pan are kept between streams (nil: nowhere).
    @ObservationIgnored var zoomStore: ZoomPanStore?
    /// Called with a touch mode the menu chose when the profile remembers it; with the zoom mode turned on or off (the
    /// screen's notice); and by a four-finger tap, which toggles the full keyboard.
    @ObservationIgnored var touchModeChosen: (@MainActor (TouchMode) -> Void)?
    @ObservationIgnored var zoomNotice: (@MainActor (Bool) -> Void)?
    @ObservationIgnored var fullKeyboardToggle: (@MainActor () -> Void)?
    /// What the menu's touch rows show, and how the picture is zoomed.
    var touchMode = TouchMode.multiTouch
    var zoomOn = false
    var touchSensitivityOn = false
    var videoZoom = VideoZoom()
    @ObservationIgnored private var swipe = MenuSwipe()
    /// How the stream menu opens besides a tap of Home (the profile's `ui_stream_menu_buttons` and `ui_stream_menu_swipe`).
    @ObservationIgnored private let menuButtons: Set<ShortcutButton>
    @ObservationIgnored private let menuSwipe: Bool
    /// The profile's controller, keyboard and mouse settings for the stream's input (the More page's gyro smoothing changes it).
    var controllerOptions = ControllerOptions()
    /// Called with what the input asks the screen to show (``GameInput/Event``: the mouse emulation, a controller
    /// announced as a generic one).
    @ObservationIgnored var inputNotice: (@MainActor (GameInput.Event) -> Void)?
    /// The keyboard and the mouse reach the PC (Control + Alt + Shift + Z releases them): the pointer is locked only then.
    private(set) var inputGrabbed = true
    /// The local pointer is shown over the stream (Control + Alt + Shift + C, `toggleMouseLocalCursor`): the pointer is
    /// then not locked.
    private(set) var localCursorVisible = false
    /// The app went to the background during the stream: the connection was closed and is opened again on return.
    @ObservationIgnored private(set) var suspended = false
    /// The leaving that runs (``leave(quit:)``).
    @ObservationIgnored private var leaving: Task<Void, Never>?
    /// The loader's phase and its one-shot cancel (B, Escape and the Cancel pill); a new one for each attempt.
    @ObservationIgnored private(set) var loader = LoaderCancel()

    /// The connected time of the stream goes to the playtime store (nil: nothing is recorded).
    @ObservationIgnored private let playtime: PlaytimeTracker?
    @ObservationIgnored private let playtimeFlushInterval: Duration
    @ObservationIgnored private var playtimeTask: Task<Void, Never>?

    @ObservationIgnored private let brightness: (any ScreenBrightness)?
    /// The brightness the player chose in this stream: it is set again when the app comes back from the background.
    @ObservationIgnored private var brightnessChosen: Int?
    /// The on-screen controls (iPhone and iPad; nil where there is no touchscreen): controller 0 for the PC.
    let onScreen: OnScreenControls?
    /// Called with the opacity the More page's slider chose: the screen keeps it in the profile.
    @ObservationIgnored var onScreenOpacityChosen: (@MainActor (Int) -> Void)?
    /// The upscaler of the stream's renderer (the Upscaler tile and page).
    let upscaler: any UpscalerControl
    /// The bitrate the Bitrate page's slider asks for, kbps.
    private(set) var bitrateRequested = 20_000
    static let bitrateRange = 1000...1_000_000
    /// The link test's recommendation for this stream (the Bitrate page's Fill row), nil without one.
    @ObservationIgnored var bitrateRecommendation: (@MainActor () -> BitrateRecommendation?)?
    /// Called with the rumble preset the Rumble feel page chose: the screen keeps it in the profile.
    @ObservationIgnored var rumblePresetChosen: (@MainActor (RumblePreset) -> Void)?
    /// Keeps what the menu changes for this game (`ui_game_…` overrides): nil for a stream without a game to keep it for.
    @ObservationIgnored var saveForGame: (@MainActor ([SettingKey: StoredSetting]) -> Void)?
    @ObservationIgnored private lazy var autoSave = MenuAutoSave(
        values: { [unowned self] setting in
            switch setting {
            case .upscaler: UpscalerSave.values(upscaler)
            case .gyroSmoothing: [.gyroSmoothing: .int(min(max(controllerOptions.gyroSmoothing, 0), 100))]
            }
        },
        write: { [unowned self] values in saveForGame?(values) })
    @ObservationIgnored private var autoSaveTask: Task<Void, Never>?

    init(
        capabilities: StreamMenuCapabilities = .platform, brightness: (any ScreenBrightness)? = nil,
        statisticsOverlay: StatisticsOverlay = .off, playtime: PlaytimeTracker? = nil, playtimeFlushInterval: Duration = .seconds(30),
        menuButtons: Set<ShortcutButton> = [], menuSwipe: Bool = true, onScreenControls: OnScreenControls? = nil,
        upscaler: (any UpscalerControl)? = nil,
        fullKeyboard: FullKeyboardState = FullKeyboardState(),
        makeSteps: @escaping @MainActor () -> any StreamSteps
    ) {
        self.playtime = playtime
        self.playtimeFlushInterval = playtimeFlushInterval
        self.makeSteps = makeSteps
        self.statisticsOverlay = statisticsOverlay
        self.menuButtons = menuButtons
        self.menuSwipe = menuSwipe
        self.brightness = brightness
        var capabilities = capabilities
        capabilities.brightness = capabilities.brightness && brightness != nil
        self.capabilities = capabilities
        self.fullKeyboard = fullKeyboard
        if let brightness { brightnessPercent = Self.rounded(brightness.percent) }
        onScreen = onScreenControls
        self.upscaler = upscaler ?? NoUpscaler()
        steps = makeSteps()
        greeting = L("stream_loader_greeting", steps.pcName)
        onScreen?.output.send = { [weak self] state in self?.onScreenSent(state) }
        fullKeyboard.host = self
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
        warned = false
        steps = makeSteps()
        run()
    }

    private func run() {
        guard let display else { return }
        attemptID += 1
        let id = attemptID
        leavingScene = false
        phase = .connecting
        loader = LoaderCancel()
        progress = 0
        line = StageLines.line(.platform, pcName: steps.pcName)
        let steps = self.steps
        let cleanup = self.cleanup
        steps.waiting = { [weak self] in self?.waitingForPC(from: id) }
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
            self.showWarnings(steps.warnings)
            do throws(StreamError) {
                try await steps.connect()
                if self.isCurrent(id) { self.connected() }
            } catch {
                // A failed stage may be a network that blocks its ports (DelosStreamActivity.java:1657-1683)
                var ports: UInt32 = 0
                if case let .stageFailed(stage, _) = error { ports = PortTest.ports(stage: stage) }
                let test = ports == 0 ? PortTest.Result.passed : await steps.testPorts(ports)
                if self.isCurrent(id), let text = StreamText.startFailure(error, ports: Self.describe(ports), blocked: test.blocked) {
                    self.fail(text)
                }
            }
        }
    }

    /// The ports of a failure as the result lists them; nil without any.
    private static func describe(_ ports: UInt32) -> String? {
        ports == 0 ? nil : PortTest.describe(ports)
    }

    /// The PC did not answer the launch and is asked again: the loader tells an "unlocking" line.
    private func waitingForPC(from id: Int) {
        guard isCurrent(id), phase == .connecting else { return }
        line = StageLines.line(.unlocking, pcName: steps.pcName)
        progress = min(progress + 0.08, 0.92)
    }

    /// The launch's warnings, long toasts (`DelosToast.LONG`, ``ToastTiming/streamLongMs``); once per stream, not again when
    /// it connects again after the background.
    private func showWarnings(_ warnings: [String]) {
        guard !warned else { return }
        warned = true
        for warning in warnings { toast?(warning, .warning, ToastTiming.streamLongMs) }
    }

    private func isCurrent(_ id: Int) -> Bool { id == attemptID }

    /// Ends the current attempt: its events and results are ignored from now on (a cancelled listener can still
    /// deliver what was queued, a cancelled launch can still return), and its stop joins ``cleanup``. Returns that.
    @discardableResult
    private func endAttempt() -> Task<Void, Never> {
        attemptID += 1
        stopPlaytime()
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
            stopPlaytime()
            stopStatistics()
            stopInput()
            connectionNotice = nil
            guard termination != .graceful else {
                DiagLog.i("Stream", "Stream ended: the PC closed it")
                phase = .ended
                return
            }
            // A lost video stream may be a network that blocks its ports (DelosStreamActivity.java:1700-1722)
            let ports = PortTest.ports(termination: termination)
            guard ports != 0 else {
                if let text = StreamText.termination(termination) { fail(text) }
                return
            }
            let steps = self.steps
            Task { [weak self] in
                let test = await steps.testPorts(ports)
                guard let self, self.isCurrent(id), let text = StreamText.termination(termination, ports: Self.describe(ports), blocked: test.blocked)
                else { return }
                self.fail(text)
            }
        case .connectionStatus(let status):
            guard phase == .streaming else { return }
            connectionNotice = StreamWarnings.connection(status, bitrateKbps: currentBitrateKbps, disabled: warningsDisabled)
        case let .rumble(controller, low, high):
            input?.rumble(controller: controller, low: low, high: high)
        case let .triggerRumble(controller, left, right):
            input?.rumbleTriggers(controller: controller, left: left, right: right)
        case let .adaptiveTriggers(controller, flags, typeLeft, typeRight, left, right):
            input?.adaptiveTriggers(controller: controller, flags: flags, typeLeft: typeLeft, typeRight: typeRight, left: left, right: right)
        case let .motionEventState(controller, motionType, reportRateHz):
            input?.motionEventState(controller: controller, motionType: motionType, reportRateHz: reportRateHz)
        case let .controllerLED(controller, red, green, blue):
            input?.controllerLED(controller: controller, red: red, green: green, blue: blue)
        default:
            break
        }
    }

    private func connected() {
        guard phase == .connecting else { return }
        phase = .streaming
        loader.connected()
        progress = 1
        if let sink = steps.input, input == nil {
            let input = GameInput(sink: sink, menuButtons: menuButtons, options: controllerOptions) { [weak self] in self?.openMenu() }
            input.rumbleConfiguration = rumbleConfiguration
            input.onEvent = { [weak self] event in self?.inputEvent(event) }
            inputGrabbed = true
            input.start()
            // The scene is still opening over the picture: B, keys and touches are the loader's, not the game's
            input.paused = true
            self.input = input
            syncOnScreen()
            startTouch(sink: sink, input: input)
        }
        startStatistics()
        startPlaytime()
        // Smart Clipboard Sync sends this device's clipboard once the stream runs (DelosStreamActivity.java:1808-1809)
        steps.clipboard?.handleFocusChange(true, connected: true)
    }

    /// What the input asks for: the keyboard's own combinations (`StreamKeyHandler.Host` of DELOS for Android) are the
    /// stream's, the rest the screen shows.
    private func inputEvent(_ event: GameInput.Event) {
        switch event {
        case .keyCombo(.quit):
            // Android's `quit()` finishes the stream activity: a disconnect, the game keeps running
            Task { await leave(quit: false) }
        case .keyCombo(.toggleInputGrab):
            inputGrabbed = input?.inputGrabbed ?? true
        case .keyCombo(.toggleLocalCursor):
            inputGrabbed = input?.inputGrabbed ?? true
            setLocalCursor(!localCursorVisible)
        case .mouseEmulation, .controllerTypeChanged:
            inputNotice?(event)
        }
    }

    /// The Mouse page's Local mouse cursor (`toggleMouseLocalCursor`): the input is grabbed again, and the local pointer shows
    /// or hides, as Control + Alt + Shift + C does.
    func toggleLocalCursor() {
        input?.grabInput()
        inputGrabbed = input?.inputGrabbed ?? true
        setLocalCursor(!localCursorVisible)
    }

    /// Shown, the system pointer over the picture is the PC's pointer and the mouse's own motion is not sent.
    func setLocalCursor(_ visible: Bool) {
        localCursorVisible = visible
        input?.localCursor = visible
    }

    /// The window lost the keyboard (another app or window): the keys down at the PC are released there
    /// (`handleFocusChange` of DELOS for Android).
    func focusLost() {
        input?.releaseKeys()
    }

    /// Time counts from the moment the core is connected (video and audio flow), like Android's `connectionStarted`;
    /// nothing before it (the loader's waiting, a launch that was cancelled or failed) is counted.
    private func startPlaytime() {
        guard let playtime else { return }
        playtime.start()
        playtimeTask?.cancel()
        let interval = playtimeFlushInterval
        playtimeTask = Task { [weak playtime] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                playtime?.flush()
            }
        }
    }

    /// The connection ended, dropped or was closed: the rest is written; ending twice adds nothing.
    private func stopPlaytime() {
        playtimeTask?.cancel()
        playtimeTask = nil
        playtime?.end()
    }

    private func fail(_ text: ResultText) {
        // Once the player leaves or the app goes to the background, what the interrupted attempt throws is no failure
        guard !suspended, phase == .connecting || phase == .streaming else { return }
        endPictureInPicture()
        stopPlaytime()
        stopStatistics()
        stopInput()
        hideMenu()
        phase = .failed(text)
        // The result is in the log, and a failed stream is a problem the user may report: the card follows once the result has
        // been answered (`StreamResult.show` and `ProblemMonitor.streamFailed` of DELOS for Android)
        DiagLog.e("Stream", "Stream ended: FAILED \"\(text.title)\"" + (text.details.map { " (\($0))" } ?? ""))
        ProblemOffers.shared.streamFailed(title: text.title, details: text.details)
    }

    private func stopInput() {
        stopTouch()
        input?.stop()
        input = nil
    }

    // MARK: Menu

    /// How long after the menu opened its focus ignores commands: what the player still holds from the game (a
    /// direction, A, Return) is not a choice in the menu.
    static let menuGrace: TimeInterval = 0.5
    @ObservationIgnored private var menuOpenedAt = Date.distantPast
    /// Called when the menu opens: the screen cancels the repeats of the direction that is held.
    @ObservationIgnored var menuOpened: (@MainActor () -> Void)?
    /// Called with the overlay the Overlay tile chose: the screen keeps it in the profile.
    @ObservationIgnored var statisticsChosen: (@MainActor (StatisticsOverlay) -> Void)?

    /// Whether the menu has been open long enough for its commands to be the player's choices.
    func menuIsArmed(at now: Date = .now) -> Bool {
        now.timeIntervalSince(menuOpenedAt) >= Self.menuGrace
    }

    func openMenu() {
        guard phase == .streaming, !menuOpen else { return }
        menuOpen = true
        menuOpenedAt = .now
        menuOpened?()
        input?.paused = true
        onScreen?.releaseAll()
        fullKeyboard.releaseInput()
        // What the fingers and the pencil hold comes up at the PC
        touchScreen?.cancelAll(time: Self.milliseconds(ProcessInfo.processInfo.systemUptime))
    }

    func closeMenu() {
        guard menuOpen else { return }
        hideMenu()
        input?.paused = false
    }

    /// The menu is gone, with the page that was open in it.
    private func hideMenu() {
        if menuOpen { menuClosedAt = .now }
        menuOpen = false
        picker = nil
        menu.close()
        // StreamMenu.kt:233-242: what the menu changed is written when it closes
        flushAutoSave()
    }

    /// How long the menu plays its exit after it closed (the screen sets it, ``StreamDockLayout/closeTotal(count:)``): taps
    /// in that time are still the menu's and do nothing (`outsideTapAction` with `closing`, StreamMenuLayout.kt:133-140).
    @ObservationIgnored var menuExitDuration: TimeInterval = 0
    @ObservationIgnored private var menuClosedAt = Date.distantPast

    /// The menu plays its exit.
    func menuClosing(at now: Date = .now) -> Bool {
        !menuOpen && now.timeIntervalSince(menuClosedAt) < menuExitDuration
    }

    // MARK: Touch popups of the rows

    /// The options list of a choice row or the popup of a slider row a tap opened (issue #92, StreamMenuRoot.kt:236-252).
    private(set) var picker: RowPopupState?

    /// A tap on the row [id] of the open page that already had the focus: its options or its slider come up.
    func openPicker(_ id: String) {
        guard menuOpen, case let .rows(rows) = menuContent(menu.page), let row = rows.first(where: { $0.id == id }),
              let setting = row.settingRow else { return }
        picker = RowPopupState.open(setting) { [weak self] value in self?.setRow(id, value) }
    }

    /// Options on the focused row of the open page: the popup a second tap opens, so a controller sees every value at once.
    /// nil: the row has no popup; false: it has one but is unavailable.
    func openFocusedPicker() -> Bool? {
        let focusedID = menu.focus.focused?.base as? String
        guard menuOpen, case let .rows(rows) = menuContent(menu.page),
              let row = rows.first(where: { StreamMenuState.rowID($0.id) == focusedID }), row.settingRow != nil else { return nil }
        switch row.tap(wasFocused: true) {
        case .popup:
            openPicker(row.id)
            return true
        case .refuse: return false
        case .focus, .activate: return nil
        }
    }

    func closePicker() {
        picker = nil
    }

    /// The picker's choice or slider value for the row [id] of the open page.
    func setRow(_ id: String, _ value: Int) {
        guard case let .rows(rows) = menuContent(menu.page), let row = rows.first(where: { $0.id == id }), row.enabled else { return }
        row.set?(value)
    }

    /// The Overlay tile: off → full → compact → off (`toggleHUD` of DELOS for Android). The choice is kept for the next streams.
    func cycleStatistics() {
        statisticsOverlay = statisticsOverlay.next
        statisticsChosen?(statisticsOverlay)
    }

    // MARK: Pages of the menu

    /// What a page shows (`PageRows` of DELOS for Android's stream menu, StreamMenuRoot.kt:528-676), for the actions this device
    /// has.
    func menuContent(_ page: MenuPage) -> StreamMenuContent {
        switch page {
        case .main:
            return .rows([])
        case .more:
            return .rows(moreRows)
        case .brightness:
            return .rows([
                StreamMenuRow(
                    id: MenuRowID.brightness.rawValue, icon: Symbols.brightnessMedium, label: L("stream_menu_row_screen_brightness"),
                    value: .slider(value: brightnessPercent, range: Self.brightnessRange, step: Self.brightnessStep, unit: " %"),
                    help: L("stream_help_screen_brightness"), activate: {}, set: { [self] in setBrightness($0) })
            ])
        case .bitrate:
            return .rows(bitrateRows)
        case .upscaler:
            return .rows(upscalerRows)
        case .mouse:
            return .rows(mouseRows)
        case .rumble:
            return .rows(rumbleRows)
        case .keys:
            let pills = specialKeys.enumerated().map { index, option in
                let label = StreamMenuText.specialKey(option.label)
                return StreamMenuPill(
                    id: "\(index)", label: label, help: L("stream_help_format_keys", label), run: { [self] in send(option.combo) })
            }
            return .pills(pills, empty: nil)
        case .commands:
            let commands = steps.serverCommands
            let pills = commands.enumerated().map { index, name in
                StreamMenuPill(
                    id: "\(index)", label: name,
                    help: L("stream_help_format_command", name.count > 36 ? String(name.prefix(35)) + "\u{2026}" : name),
                    run: { [self] in runServerCommand(index) })
            }
            return .pills(pills, empty: commands.isEmpty ? L("stream_menu_no_commands") : nil)
        }
    }

    /// The More page's rows in Android's order (StreamMenuRoot.kt:548-574): what this device does not have is left out (the
    /// touch rows without a touchscreen, the system keyboard without one to raise).
    private var moreRows: [StreamMenuRow] {
        var rows = [
            StreamMenuRow(
                id: MenuRowID.keys.rawValue, icon: Symbols.keyboardCommandKey, label: L("stream_menu_row_send_keys"), value: .action,
                help: L("stream_help_send_keys"), activate: { [self] in openMenuPage(.keys) }),
            StreamMenuRow(
                id: MenuRowID.sendClipboard.rawValue, icon: Symbols.send, label: L("stream_menu_row_send_clipboard"), value: .action,
                help: L("stream_help_send_clipboard"), activate: { [self] in closeMenu(); sendClipboard() }),
            StreamMenuRow(
                id: MenuRowID.getClipboard.rawValue, icon: Symbols.receive, label: L("stream_menu_row_get_clipboard"), value: .action,
                help: L("stream_help_get_clipboard"), activate: { [self] in closeMenu(); getClipboard() }),
            StreamMenuRow(
                id: MenuRowID.commands.rawValue, icon: Symbols.terminal, label: L("stream_menu_row_commands"), value: .action,
                help: L("stream_help_commands"), activate: { [self] in openMenuPage(.commands) }),
            StreamMenuRow(
                id: MenuRowID.taskManager.rawValue, icon: Symbols.taskManager, label: L("stream_menu_row_task_manager"), value: .action,
                help: L("stream_help_task_manager"), activate: { [self] in send(SpecialKeys.taskManager) }),
        ]
        if capabilities.touchscreen {
            rows.append(StreamMenuRow(
                id: MenuRowID.zoom.rawValue, icon: Symbols.zoomIn, label: L("stream_menu_row_zoom"), value: .toggle(zoomOn),
                help: L("stream_help_zoom"), activate: { [self] in toggleZoom() }))
        }
        if allowsTouchModeChange {
            rows.append(StreamMenuRow(
                id: MenuRowID.mouseMode.rawValue, icon: Symbols.mouse, label: L("stream_menu_row_mouse_mode"), value: .action,
                help: L("stream_help_mouse_mode"), activate: { [self] in openMenuPage(.mouse) }))
        }
        rows += onScreenRows
        rows += systemKeyboardRows
        if capabilities.touchscreen {
            rows.append(StreamMenuRow(
                id: MenuRowID.touchSensitivity.rawValue, icon: Symbols.touchSensitivity, label: L("stream_menu_row_touch_sensitivity"),
                value: .toggle(touchSensitivityOn), help: L("stream_help_touch_sensitivity"), activate: { [self] in toggleTouchSensitivity() }))
        }
        rows.append(StreamMenuRow(
            id: MenuRowID.rumble.rawValue, icon: Symbols.vibration, label: L("stream_menu_row_rumble_feel"),
            value: .text(L(rumbleConfiguration.profile.labelKey)), help: L("stream_help_rumble_feel", "B"),
            activate: { [self] in openMenuPage(.rumble) }))
        // Applies at once and is kept for this game, never the profile (the Settings slider's); usable while a gyroscope source is on
        let gyroOn = controllerOptions.motionSensors || controllerOptions.motionFallbackToDevice
        rows.append(StreamMenuRow(
            id: MenuRowID.gyroSmoothing.rawValue, icon: Symbols.smoothing, label: L("stream_menu_row_gyro_smoothing"),
            value: .slider(value: controllerOptions.gyroSmoothing, range: 0...100, step: 5, unit: " %", minText: L("stream_menu_gyro_off", 0)),
            enabled: gyroOn, help: L(gyroOn ? "stream_help_gyro_smoothing" : "stream_help_gyro_smoothing_disabled"), activate: {},
            set: { [self] in setGyroSmoothing($0) }))
        return rows
    }

    /// The Bitrate page (StreamMenuRoot.kt:580-600): the bitrate asked for, the link test's recommendation where there is one
    /// (its Fill puts it on the slider; nothing is sent before Apply), and Apply with the host's answer on its right.
    private var bitrateRows: [StreamMenuRow] {
        let busy = bitrate.busy
        var rows = [
            StreamMenuRow(
                id: MenuRowID.bitrate.rawValue, icon: Symbols.networkCheck, label: L("stream_menu_row_bitrate"),
                value: .slider(value: bitrateRequested, range: Self.bitrateRange, step: 1000, unit: " Mbps", divisor: 1000),
                enabled: !busy, help: L("stream_help_bitrate"), activate: {}, set: { [self] in bitrateRequested = $0 })
        ]
        if let recommendation = bitrateRecommendation?() {
            let kbps = min(max(recommendation.kbps, Self.bitrateRange.lowerBound), Self.bitrateRange.upperBound)
            rows.append(StreamMenuRow(
                id: "bitrate-recommended", icon: Symbols.recommend, label: recommendation.line, value: .text(L("stream_menu_bitrate_fill")),
                enabled: !busy, help: recommendation.help, activate: { [self] in bitrateRequested = kbps }))
        }
        let status = bitrate.statusText
        rows.append(StreamMenuRow(
            id: MenuRowID.applyBitrate.rawValue, icon: Symbols.check, label: L("stream_menu_row_apply"), value: status.map { .text($0) } ?? .action,
            enabled: !busy, help: bitrate.failureText ?? L("stream_help_apply_bitrate"), activate: { [self] in applyBitrate(bitrateRequested) }))
        return rows
    }

    /// The Upscaler page (StreamMenuRoot.kt:601-631): its rows can be used only where the upscaler can run; every change
    /// applies at once and is kept for this game. The Enabled row says what the upscaler makes of the stream on this display,
    /// and the supersampling levels name the size each renders at (``UpscalerSizeText``).
    private var upscalerRows: [StreamMenuRow] {
        let available = upscaler.available
        let status = upscaler.status
        let supersampling = upscaler.supersamplingMode
        let plan = upscaler.sizePlan
        let sizes = plan.flatMap { plan in
            upscaler.requested ? UpscalerSizeText.note(
                stream: plan.stream, sizes: plan.sizes(mode: upscaler.mode, level: upscaler.supersamplingLevel)) : nil
        }
        var rows = [
            StreamMenuRow(
                id: MenuRowID.upscalerEnabled.rawValue, icon: Symbols.upscaler, label: L("stream_menu_row_enabled"),
                value: .toggle(upscaler.requested), enabled: available && !status.isChanging,
                help: StreamMenuText.helpLine(
                    ([status.text] + (sizes.map { [$0] } ?? [])).joined(separator: "\n") + "\n\n"
                        + L(supersampling ? "stream_help_supersampling_on" : "stream_help_upscaling")),
                activate: { [self] in upscaler.setEnabled(!upscaler.requested); upscalerChanged() })
        ]
        if supersampling, upscaler.mode.scales {
            let level = min(max(upscaler.supersamplingLevel, 1), 2)
            let options = [1, 2].map { level in
                plan.map { UpscalerSizeText.levelLabel(level, plan: $0, mode: upscaler.mode) }
                    ?? L(level == 2 ? "sgsr_supersampling_level_2_short" : "sgsr_supersampling_level_1_short")
            }
            let explanation = plan.flatMap { UpscalerSizeText.levelHelp(level, plan: $0, mode: upscaler.mode) }
            rows.append(StreamMenuRow(
                id: MenuRowID.supersamplingQuality.rawValue, icon: Symbols.highQuality, label: L("stream_menu_row_supersampling_quality"),
                value: .choice(label: options[level - 1], options: options, selected: level - 1), enabled: available,
                help: StreamMenuText.helpLine(([explanation].compactMap { $0 } + [L("stream_help_supersampling")]).joined(separator: "\n\n")),
                activate: { [self] in setSupersampling(2) },
                set: { [self] in setSupersampling($0 + 1) }, step: { [self] in setSupersampling($0 < 0 ? 1 : 2) }))
        }
        let mode = upscaler.mode
        rows.append(StreamMenuRow(
            id: MenuRowID.upscalerMode.rawValue, icon: Symbols.upscalerMode, label: L("stream_menu_row_mode"),
            value: .choice(label: mode.label, options: UpscalerMode.allCases.map(\.label), selected: mode.index), enabled: available,
            help: StreamMenuText.helpLine(mode.help + "\n\n" + L("stream_help_mode")),
            activate: { [self] in setUpscalerMode(upscaler.mode.next(1)) },
            set: { [self] in setUpscalerMode(UpscalerMode(index: $0)) }, step: { [self] in setUpscalerMode(upscaler.mode.next($0)) }))
        rows.append(StreamMenuRow(
            id: MenuRowID.sharpness.rawValue, icon: Symbols.sharpness, label: L("stream_menu_row_sharpness"),
            value: .slider(value: upscaler.sharpness, range: 0...100, step: 5, unit: " %"), enabled: available,
            help: L("stream_help_upscaler_sharpness"), activate: {}, set: { [self] in upscaler.setSharpness($0); upscalerChanged() }))
        return rows
    }

    /// The Mouse page (StreamMenuRoot.kt:632-641): the touchscreen mode, and the local pointer.
    private var mouseRows: [StreamMenuRow] {
        let modes = touchModeOptions
        let selected = max(modes.firstIndex { $0.value == selectedTouchMode } ?? 0, 0)
        var rows: [StreamMenuRow] = []
        if !modes.isEmpty {
            let applies = L(rememberMouseMode ? "stream_menu_mouse_applies_saved" : "stream_menu_mouse_applies_stream")
            rows.append(StreamMenuRow(
                id: MenuRowID.touchscreenMode.rawValue, icon: Symbols.touchApp, label: L("stream_menu_row_touchscreen_mode"),
                value: .choice(label: modes[selected].label, options: modes.map(\.label), selected: selected),
                help: StreamMenuText.helpLine(modes[selected].help + "\n\n" + applies),
                activate: { [self] in setTouchMode(modes[(selected + 1) % modes.count].value) },
                set: { [self] in setTouchMode(modes[$0].value) },
                step: { [self] in setTouchMode(modes[((selected + $0) % modes.count + modes.count) % modes.count].value) }))
        }
        rows.append(StreamMenuRow(
            id: MenuRowID.localCursor.rawValue, icon: Symbols.cursor, label: L("stream_menu_row_local_cursor"), value: .toggle(localCursorVisible),
            help: L("stream_help_local_cursor_device"), activate: { [self] in toggleLocalCursor() }))
        return rows
    }

    /// The Rumble feel page (StreamMenuRoot.kt:658-674): the presets, switched live and saved; the menu stays open so they can
    /// be compared. The active one says so, one with a problem says that instead and its help tells it.
    private var rumbleRows: [StreamMenuRow] {
        let active = rumbleConfiguration.profile
        let problem = input?.rumbleProblem
        return RumblePreset.allCases.map { preset in
            var help = Self.rumbleHelp(preset)
            let hasProblem = preset == active && problem != nil
            if hasProblem, let problem { help += "\n" + L("stream_menu_rumble_problem", Self.rumbleProblemText(problem, preset: preset)) }
            return StreamMenuRow(
                id: Self.rumbleRowID(preset), icon: Self.rumbleIcon(preset), label: L(preset.labelKey), value: .action, help: help,
                activate: { [self] in selectRumblePreset(preset) },
                confirmation: hasProblem ? L("stream_menu_rumble_problem_word") : preset == active ? L("stream_menu_rumble_active") : nil)
        }
    }

    nonisolated static func rumbleRowID(_ preset: RumblePreset) -> String { "rumble-\(preset.rawValue)" }

    private static func rumbleIcon(_ preset: RumblePreset) -> String {
        switch preset {
        case .original: Symbols.presetOriginal
        case .soft: Symbols.presetSoft
        case .kickStart: Symbols.presetKick
        case .pulsing: Symbols.presetPulsing
        }
    }

    /// The preset's explanation, the same as the setting's choice (StreamMenuHelp.kt:28-29).
    private static func rumbleHelp(_ preset: RumblePreset) -> String {
        switch preset {
        case .original: L("help_list_rumble_feel_original")
        case .soft: L("help_list_rumble_feel_gentle")
        case .kickStart: L("help_list_rumble_feel_kick_only")
        case .pulsing: L("help_list_rumble_feel_pulse_25")
        }
    }

    /// Why the running rumble could not use its preset's technique (`RumbleProblem.text`): the technique's code name stays.
    private static func rumbleProblemText(_ problem: RumbleProblem, preset: RumblePreset) -> String {
        let technique = preset.profile.pulseMilliseconds > 0 ? "PULSE" : "AMPLITUDE"
        return switch problem {
        case .noAmplitudeControl: L("rumble_problem_no_amplitude")
        case .singleVibratorOnly: L("rumble_problem_single_vibrator", technique)
        case .failed(let reason): L("rumble_problem_failed", technique, reason)
        }
    }

    /// Where the focus starts on [page]: the row that opened the page above it is handled by ``go(_:)``; the Rumble page starts
    /// on the active preset (StreamMenuRoot.kt:663-664), the others on their first item.
    private func firstFocus(_ page: MenuPage) -> String {
        if page == .rumble { return StreamMenuState.rowID(Self.rumbleRowID(rumbleConfiguration.profile)) }
        if page == .bitrate { bitrateRequested = min(max(currentBitrateKbps, Self.bitrateRange.lowerBound), Self.bitrateRange.upperBound) }
        return menuContent(page).ids.first ?? StreamMenuState.backID
    }

    /// The tile's page opens in the popover; its own tile again closes the popover, another tile's page replaces it.
    func openMenuPage(_ page: MenuPage) {
        guard menuOpen else { return }
        if menu.page == page {
            dismissPopover()
            return
        }
        picker = nil
        menu.open(page, focusing: firstFocus(page))
        // GameMenu.java:144: a custom key file that could not be read
        if page == .keys, specialKeysFailed { toast?(L("wrong_import_format"), .warning, ToastTiming.streamShortMs) }
    }

    /// B (or the back circle): a picker closes first; then one level up, to the row that opened the page or to its tile; on the
    /// dock it resumes.
    func menuBack() {
        guard menuOpen else { return }
        if picker != nil {
            closePicker()
            return
        }
        guard let exit = StreamMenuNavigation.afterBack(menu.page) else {
            closeMenu()
            return
        }
        go(exit)
    }

    /// A tap outside the popover closes it and never resumes the stream.
    func dismissPopover() {
        guard menuOpen, let exit = StreamMenuNavigation.afterDismiss(menu.page) else { return }
        go(exit)
    }

    /// A tap outside the dock and the popover: the popover closes first, then the menu (it resumes the stream). The tap is the
    /// menu's alone: the game gets no click (the menu paused its input, and a release without a press is not sent).
    func tapOutside() {
        switch StreamMenuNavigation.afterOutsideTap(menu.page, closing: menuClosing() || !menuOpen) {
        case .dismissPopover(let exit): go(exit)
        case .closeMenu: closeMenu()
        case .none: break
        }
    }

    private func go(_ exit: PageExit) {
        picker = nil
        menu.go(exit, focusing: exit.focusRow.map { StreamMenuState.rowID($0.rawValue) })
    }

    /// Left (-1) or right (+1) on the focused row of the popover: a slider steps (faster the longer the key is held), a choice
    /// goes to its next value. False when the focused item adjusts nothing, so the focus moves instead.
    @discardableResult
    func adjustFocusedRow(_ direction: Int, repeatCount: Int = 0) -> Bool {
        let focusedID = menu.focus.focused?.base as? String
        guard case let .rows(rows) = menuContent(menu.page),
            let row = rows.first(where: { StreamMenuState.rowID($0.id) == focusedID }), row.enabled
        else { return false }
        if case .choice = row.value, let step = row.step {
            step(direction)
            return true
        }
        guard let set = row.set, let next = row.stepped(direction, steps: row.acceleration(repeatCount: repeatCount)) else { return false }
        set(next)
        return true
    }

    // MARK: Actions of the menu pages

    static let brightnessRange = 5...100
    static let brightnessStep = 5

    private static func rounded(_ percent: Int) -> Int {
        min(max(Int((Double(percent) / Double(brightnessStep)).rounded()) * brightnessStep, brightnessRange.lowerBound), brightnessRange.upperBound)
    }

    func setBrightness(_ percent: Int) {
        guard let brightness else { return }
        let value = Self.rounded(percent)
        brightnessPercent = value
        brightnessChosen = value
        brightness.set(value)
    }

    /// Gives the screen's own brightness back (the stream is left or the app goes to the background).
    func restoreBrightness() {
        brightness?.restore()
    }

    /// A key combination to the PC; the menu closes first.
    func send(_ combo: KeyCombo) {
        closeMenu()
        input?.send(combo)
    }

    func runServerCommand(_ index: Int) {
        closeMenu()
        input?.runServerCommand(index)
    }

    // MARK: On-screen controls

    /// The More page's on-screen controls rows (`StreamMenuRoot`): the toggle for this stream and the profile's opacity.
    private var onScreenRows: [StreamMenuRow] {
        guard let onScreen else { return [] }
        return [
            StreamMenuRow(
                id: MenuRowID.onScreenControls.rawValue, icon: Symbols.joystick, label: L("stream_menu_row_onscreen_controls"),
                value: .toggle(onScreen.visible), help: L("stream_help_on_screen_controls"),
                activate: { [self] in toggleOnScreenControls() }),
            StreamMenuRow(
                id: MenuRowID.onScreenOpacity.rawValue, icon: Symbols.opacity, label: L("settings_native_osc_opacity_title"),
                value: .slider(value: onScreen.options.opacity, range: 0...100, step: StreamSettingsForm.oscOpacityStep, unit: " %"),
                help: L("stream_help_on_screen_controls_opacity"), activate: {}, set: { [self] in setOnScreenOpacity($0) }),
        ]
    }

    /// The More page's toggle: the on-screen controls go away, or come up (also while a controller is in use) for the rest of
    /// this stream (`toggleVirtualController`; the profile's setting is not changed).
    func toggleOnScreenControls() {
        onScreen?.toggle()
        syncOnScreen()
    }

    /// The More page's slider: the running controls take it at once, and the profile keeps it (the same value as Settings).
    func setOnScreenOpacity(_ percent: Int) {
        guard let onScreen else { return }
        onScreen.setOpacity(percent)
        onScreenOpacityChosen?(onScreen.options.opacity)
    }

    private func onScreenSent(_ state: ControllerState) {
        guard onScreen?.enabled == true else { return }
        input?.setOnScreenControls(state)
    }

    /// Tells the input whether the on-screen controls are controller 0 now, and whether its rumble plays on the device.
    private func syncOnScreen() {
        guard let input, let onScreen else { return }
        input.onScreenRumble = onScreen.rumblesDevice
        input.setOnScreenControls(onScreen.enabled ? onScreen.state : nil)
    }

    /// Apply of the Bitrate page (`applyBitrate`, StreamMenu.kt:308-331): asks the PC for [kbps] while the stream runs.
    func applyBitrate(_ kbps: Int) {
        let steps = self.steps
        let task = bitrate.apply(kbps, connected: { [weak self] in self?.phase == .streaming }, change: { try await steps.setRuntimeBitrate($0) })
        // What the host applied goes onto the slider (`accepted`, StreamMenuRoot.kt:596)
        Task { [weak self] in
            await task?.value
            guard let self else { return }
            switch self.bitrate.result {
            case .accepted(let applied)?, .limited(let applied)?: self.bitrateRequested = applied
            default: break
            }
        }
    }

    // MARK: Upscaler, gyro smoothing and rumble feel of the menu

    /// An upscaler change of the page: kept for this game (`upscalerChanged`, StreamMenu.kt:405).
    private func upscalerChanged() {
        menuSettingChanged(.upscaler)
    }

    func setUpscalerMode(_ mode: UpscalerMode) {
        upscaler.setMode(mode)
        upscalerChanged()
    }

    func setSupersampling(_ level: Int) {
        upscaler.setSupersamplingLevel(level)
        upscalerChanged()
    }

    /// The More page's gyro smoothing: the running input takes it at once (the next motion sample uses it), and it is kept for
    /// this game, never the profile (StreamMenu.kt:449-459).
    func setGyroSmoothing(_ percent: Int) {
        let value = min(max(percent, 0), 100)
        controllerOptions.gyroSmoothing = value
        input?.gyroSmoothing = value
        menuSettingChanged(.gyroSmoothing)
    }

    /// A preset of the Rumble feel page: the running stream rumbles with it from the next event and the profile keeps it; no
    /// sample plays and the menu stays open (StreamMenu.kt:425-438).
    func selectRumblePreset(_ preset: RumblePreset) {
        rumbleConfiguration.profile = preset
        rumblePresetChosen?(preset)
    }

    /// Called only by a player's change of a menu row, never while the menu opens: written once it settles.
    private func menuSettingChanged(_ setting: MenuSavedSetting) {
        guard saveForGame != nil else { return }
        autoSave.changed(setting)
        scheduleAutoSave()
    }

    private func scheduleAutoSave() {
        autoSaveTask?.cancel()
        guard let delay = autoSave.nextDelay() else { return }
        autoSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.autoSave.tick()
            self.scheduleAutoSave()
        }
    }

    /// Writes the pending menu changes now: the menu closed or the stream ends (`flushAutoSave`).
    func flushAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        autoSave.flush()
    }

    /// Send clipboard of the More page (StreamMenu.kt:453): this device's clipboard to the PC, also a clip DELOS marked.
    func sendClipboard() {
        steps.clipboard?.send(force: true)
    }

    /// Get clipboard of the More page (StreamMenu.kt:454): the PC's clipboard to this device.
    func getClipboard() {
        steps.clipboard?.get()
    }

    /// The Keyboard tile (`toggleFullKeyboard`): the menu closes, then the Delos full keyboard comes up (it takes the
    /// controllers and the pointer) or goes away.
    func toggleFullKeyboard() {
        closeMenu()
        guard phase == .streaming else { return }
        if fullKeyboard.open {
            closeFullKeyboard()
        } else {
            fullKeyboard.show()
            input?.padCapture = { [weak self] old, new in self?.fullKeyboard.controller(old, new) }
            input?.mouseSuspended = true
            #if os(tvOS)
            remoteKeyboard.start()
            #endif
        }
    }

    #if os(tvOS)
    /// The Siri Remote drives the full keyboard while it is up.
    @ObservationIgnored private lazy var remoteKeyboard = SiriRemoteKeyboard { [weak self] old, new in
        self?.fullKeyboard.controller(old, new)
    }
    #endif

    /// The full keyboard goes away (its Hide key, B, the tile): what it held comes up at the PC, the controllers and the
    /// pointer are the game's again.
    func closeFullKeyboard() {
        fullKeyboard.hide()
        input?.padCapture = nil
        input?.mouseSuspended = false
        #if os(tvOS)
        remoteKeyboard.stop()
        #endif
    }

    /// More's Open system keyboard (`toggleSystemKeyboard`): the menu closes, then the system keyboard comes up or goes away.
    func toggleSystemKeyboard() {
        KeyboardTileLog.note("row: system keyboard; offered \(capabilities.systemKeyboard), shown \(systemKeyboardShown), menu open \(menuOpen)")
        guard capabilities.systemKeyboard else { return }
        closeMenu()
        systemKeyboardShown.toggle()
    }

    /// The system took the keyboard away (its own hide button).
    func keyboardDismissed() {
        KeyboardTileLog.note("row: the system keyboard went away")
        systemKeyboardShown = false
    }

    /// More's row that raises the system keyboard (Android's Open Android keyboard), where there is one.
    private var systemKeyboardRows: [StreamMenuRow] {
        guard capabilities.systemKeyboard else { return [] }
        return [
            StreamMenuRow(
                id: MenuRowID.systemKeyboard.rawValue, icon: Symbols.androidKeyboard, label: L("stream_menu_row_system_keyboard"),
                value: .action, help: L("stream_help_open_system_keyboard"), activate: { [self] in toggleSystemKeyboard() })
        ]
    }

    func typed(_ text: String) {
        input?.type(text, asText: keyboardOptions.commitText)
    }

    func typedBackspace() {
        input?.backspace()
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
        connectionNotice = nil
    }

    // MARK: Background

    /// The app goes to the background. iOS suspends it and the connection would break while it is away (the owner
    /// came back to a black screen and a failure), so the stream is closed now, as Disconnect does: the game keeps
    /// running on the PC. The loader shows until ``returnedToForeground()`` connects again. Synchronous, so a return
    /// right after it finds the stream suspended; the returned task ends when the connection is closed.
    ///
    /// With Picture in Picture the stream stays: shown in its window, it is watched (``pictureInPicture(_:)``); while the
    /// window may still come (it starts as the app leaves), the stream is closed only after ``pictureInPictureGrace`` without
    /// it, and the returned task ends then.
    @discardableResult
    func enteredBackground() -> Task<Void, Never>? {
        inBackground = true
        guard phase == .connecting || phase == .streaming, !suspended, !pictureInPictureShown else { return nil }
        guard pictureInPictureMayStart else { return suspend() }
        let grace = pictureInPictureGrace
        let task = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self, self.inBackground, !self.pictureInPictureShown else { return }
            self.pictureInPictureWait = nil
            await self.suspend()?.value
        }
        pictureInPictureWait = task
        return task
    }

    /// Closes the stream for the background (``enteredBackground()``).
    @discardableResult
    private func suspend() -> Task<Void, Never>? {
        guard phase == .connecting || phase == .streaming, !suspended else { return nil }
        endPictureInPicture()
        stopStatistics()
        suspended = true
        hideMenu()
        systemKeyboardShown = false
        closeFullKeyboard()
        restoreBrightness()
        stopInput()
        phase = .connecting
        progress = 0
        return endAttempt()
    }

    /// The app is back: the same game is resumed on the PC with a new connection, launched once the closed one has
    /// stopped. A stream that Picture in Picture kept is the player's again.
    func returnedToForeground() {
        inBackground = false
        pictureInPictureWait?.cancel()
        pictureInPictureWait = nil
        leavePictureInPicture()
        guard suspended else { return }
        suspended = false
        if let brightnessChosen { brightness?.set(brightnessChosen) }
        steps = makeSteps()
        run()
    }

    // MARK: Picture in Picture

    /// The profile turned Picture in Picture on (`checkbox_enable_pip`) and the stream can be shown in it
    /// (``PictureInPictureVideo``); the screen sets it.
    var pictureInPictureEnabled = false
    /// The system may take the stream into its Picture in Picture window when the app leaves (AVKit's automatic start):
    /// the stream runs (Android's `pipAutoEnter`: connected).
    var pictureInPictureMayStart: Bool { pictureInPictureEnabled && phase == .streaming }
    /// The window shows the stream: Android's observer mode. Nothing reaches the PC, what was held came up there, the
    /// menu and the keyboards are closed, and the connection stays while the app is in the background.
    @ObservationIgnored private(set) var pictureInPictureShown = false
    /// How long the background waits for the window before the stream is closed as without it.
    @ObservationIgnored var pictureInPictureGrace: Duration = .seconds(2)
    @ObservationIgnored private var pictureInPictureWait: Task<Void, Never>?
    @ObservationIgnored private var inBackground = false

    /// What AVKit's Picture in Picture window did (``PictureInPictureEvent``).
    func pictureInPicture(_ event: PictureInPictureEvent) {
        switch event {
        case .starting:
            guard pictureInPictureMayStart, !pictureInPictureShown else { return }
            pictureInPictureShown = true
            pictureInPictureWait?.cancel()
            pictureInPictureWait = nil
            hideMenu()
            systemKeyboardShown = false
            closeFullKeyboard()
            restoreBrightness()
            input?.paused = true
            onScreen?.releaseAll()
            touchScreen?.cancelAll(time: Self.milliseconds(ProcessInfo.processInfo.systemUptime))
        case .failed:
            guard inBackground else { return leavePictureInPicture() }
            // The window did not come: the stream is closed as without it
            pictureInPictureWait?.cancel()
            pictureInPictureWait = nil
            suspend()
        case .stopped(let restored):
            guard pictureInPictureShown else { return }
            // Closed from its own button while the app is away: the stream is closed as without it
            if inBackground, !restored {
                suspend()
            } else {
                leavePictureInPicture()
            }
        }
    }

    /// The stream is the player's again after its window: the input (unless the menu or the launch scene has it) and the
    /// chosen brightness.
    private func leavePictureInPicture() {
        guard pictureInPictureShown else { return }
        pictureInPictureShown = false
        if let brightnessChosen { brightness?.set(brightnessChosen) }
        if phase == .streaming, !menuOpen, !loader.cancellable { input?.paused = false }
    }

    /// The stream ends or is closed: whatever the window did, nothing is resumed.
    private func endPictureInPicture() {
        pictureInPictureShown = false
        pictureInPictureWait?.cancel()
        pictureInPictureWait = nil
    }

    // MARK: Leaving

    /// Leaves the stream: Disconnect (`quit` false) keeps the app running on the PC, Quit app ends it there too. A
    /// call while the stream is already leaving returns when that leaving is over (the app waits for it before it
    /// quits).
    func leave(quit: Bool, scene: Bool = false) async {
        switch phase {
        case .leaving:
            await leaving?.value
            return
        case .ended: return
        case .failed:
            phase = .ended
            return
        case .connecting, .streaming:
            break
        }
        // Disconnect brings the PC's clipboard along with Smart Clipboard Sync (DelosStreamActivity.java:2086-2091)
        if !quit, phase == .streaming { steps.clipboard?.disconnecting() }
        stopStatistics()
        hideMenu()
        // No return from the background starts another attempt now; the one that ran is the one the PC quits
        suspended = false
        endPictureInPicture()
        let steps = self.steps
        leavingQuit = quit
        leavingScene = scene
        phase = .leaving(quit ? StreamText.quitting(appName: steps.appName) : L("stream_exit_disconnecting"))
        stopInput()
        let stopped = endAttempt()
        let hold = scene ? leavingHold : .zero
        let task = Task { @MainActor [weak self] in
            let began = ContinuousClock.now
            await stopped.value
            if quit {
                guard await steps.quitApp() else {
                    self?.phase = .failed(StreamText.quitFailure(appName: steps.appName))
                    return
                }
                // DelosStreamActivity.java:1642-1647: a long success toast
                self?.toast?(StreamText.quitSuccess(appName: steps.appName), .success, ToastTiming.streamLongMs)
            }
            // The exit scene plays out before the library comes back
            try? await ContinuousClock().sleep(until: began.advanced(by: hold))
            self?.phase = .ended
        }
        leaving = task
        await task.value
    }

    /// Back to library on the result overlay.
    func dismiss() {
        if case .failed = phase { phase = .ended }
    }

    // MARK: Touch

    enum TouchPhase { case began, moved, ended, cancelled }

    /// The surface the touches arrive on, in pixels: its size, the strip at its bottom the system keeps for its home
    /// gesture, and the pixels per point.
    struct TouchArea: Equatable {
        var width: CGFloat
        var height: CGFloat
        var gestureInset: CGFloat = 0
        var scale: CGFloat = 1

        /// Where the swipe up that opens the menu starts.
        var swipeZone: SwipeZone {
            StreamMenuSwipe.zone(height: height, gestureInset: gestureInset, minDeadEdge: StreamMenuSwipe.minDeadEdge * scale)
        }
    }

    // MARK: Loader

    /// The loader can be cancelled now: its scene is up, while it connects and while it opens over the picture.
    var loaderCancellable: Bool { loader.cancellable && (phase == .connecting || phase == .streaming) }

    /// Cancels the loader in any phase (B, Escape, the Cancel pill): this client's attempt ends and the library comes back.
    /// The game is never quit on the PC and no result overlay is shown (``LoaderCancel/plan``). One cancel per attempt.
    func cancelLoader() async {
        guard loaderCancellable, loader.request() else { return }
        await leave(quit: LoaderCancel.plan.quitGame)
    }

    /// The launch scene is over: the stream is the player's.
    func loaderEnded() {
        loader.ended()
        if phase == .streaming, !menuOpen, !pictureInPictureShown { input?.paused = false }
    }

    /// One touch on the stream (``touches(_:_:area:time:)``).
    func touch(_ id: Int, _ touchPhase: TouchPhase, at point: CGPoint, area: TouchArea, time: TimeInterval) {
        touches(touchPhase, [TouchSample(id: id, x: point.x, y: point.y)], area: area, time: time)
    }

    /// Touches on the stream that changed together, in pixels of [area]: the on-screen controls take the touches that land on
    /// them, the swipe up from the band above the bottom edge opens the menu (unless the profile turned it off), the other
    /// touches go to the touch screen in its mode (``TouchScreen``). While the controls are moved or resized, the stream
    /// gets no touch.
    func touches(_ touchPhase: TouchPhase, _ samples: [TouchSample], area: TouchArea, time: TimeInterval) {
        let screenPhase: TouchScreen.Phase = switch touchPhase {
        case .began: .began
        case .moved: .moved
        case .ended: .ended
        case .cancelled: .cancelled
        }
        // A touch that ends after the menu opened (its own swipe opened it) is forgotten all the same
        if touchPhase == .ended || touchPhase == .cancelled, phase != .streaming || menuOpen || loader.cancellable {
            for sample in samples { _ = swipe.ended(sample.id) }
            touchScreen?.touches(.cancelled, samples, time: Self.milliseconds(time))
            return
        }
        guard phase == .streaming, !menuOpen, !loader.cancellable else { return }
        // A tap while the menu plays its exit is still the menu's: it never reaches the game (StreamMenuLayout.kt:133-140)
        if touchPhase == .began, menuClosing() { return }
        if area != touchArea { surfaceLaidOut(area) }
        var rest: [TouchSample] = []
        for sample in samples {
            let id = sample.id, point = CGPoint(x: sample.x, y: sample.y)
            if let onScreen, area.width > 0, area.height > 0 {
                let x = Float(point.x / area.width) * Float(onScreen.panel.width), y = Float(point.y / area.height) * Float(onScreen.panel.height)
                let oscPhase: OnScreenControls.Phase = switch touchPhase {
                case .began: .began
                case .moved: .moved
                case .ended: .ended
                case .cancelled: .cancelled
                }
                if onScreen.touch(id, oscPhase, x: x, y: y, time: time * 1000) { continue }
                if touchPhase == .began, onScreen.mode == .move || onScreen.mode == .resize { continue }
            }
            switch touchPhase {
            case .began:
                if sample.tool == .finger, menuSwipe, swipe.began(id, at: point, zone: area.swipeZone) { continue }
            case .moved:
                let (owned, open) = swipe.moved(id, to: point, height: area.height)
                if open { openMenu() }
                if owned { continue }
            case .ended, .cancelled:
                if swipe.ended(id) { continue }
            }
            rest.append(sample)
        }
        guard !rest.isEmpty else { return }
        // The swipe opened the menu: the other touches are over for the PC
        touchScreen?.touches(menuOpen ? .cancelled : screenPhase, rest, time: Self.milliseconds(time))
    }

    /// Whether a mouse is connected, whose pointer touches are already the PC's mouse.
    var hasMouse: Bool { input?.hasMouse ?? false }
}

/// The profile's settings of the Delos full keyboard that are not its size.
struct FullKeyboardOptions: Equatable, Sendable {
    /// `checkbox_enable_sticky_modifier_key_virtual_keyboard`: a modifier held 300 ms stays down.
    var stickyModifiers = true
    /// `checkbox_vibrate_keyboard`.
    var vibrate = false
    /// `checkbox_enable_commit_text`: what the system keyboard types goes as text, not as key presses.
    var commitText = false
}

extension FullKeyboardOptions {
    init(_ settings: StreamSettings) {
        self.init(
            stickyModifiers: settings.bool(.enableStickyModifierKeyVirtualKeyboard), vibrate: settings.bool(.vibrateKeyboard),
            commitText: settings.bool(.enableCommitText))
    }
}

/// The keyboard's keys go to the PC through the stream's input, with the modifiers that are down (``GameInput/sendVirtualKey(_:pressed:)``).
extension StreamController: FullKeyboardHost {
    var stickyModifiers: Bool { keyboardOptions.stickyModifiers }

    func sendKey(_ code: Int, down: Bool) {
        guard let key = UInt8(exactly: code) else { return }
        input?.sendVirtualKey(key, pressed: down)
    }

    func haptic(_ haptic: KeyHaptic) {
        guard keyboardOptions.vibrate else { return }
        keyboardHaptic?(haptic)
    }
}
