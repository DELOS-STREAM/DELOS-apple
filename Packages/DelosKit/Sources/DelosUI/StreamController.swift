import DelosCore
import DelosData
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
}

extension StreamSteps {
    /// Attempts without a video renderer (including lifecycle tests) have no presentation telemetry.
    var statisticsSource: StreamStatisticsSource? { nil }
    var serverCommands: [String] { [] }
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
        // The keyboard belongs to the running stream: not over the loader, the exit or the result overlay
        didSet { if phase != .streaming { keyboardShown = false } }
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
    /// What this device can do for the menu's tiles and pages (the brightness needs a device to set it on).
    let capabilities: StreamMenuCapabilities
    /// The screen's brightness in percent, in steps of 5 (the Brightness page's slider).
    private(set) var brightnessPercent = 100
    /// The on-screen keyboard is wanted over the stream (the Keyboard tile): it is raised while the menu is closed.
    private(set) var keyboardShown = false
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
    var rumbleConfiguration = RumbleConfiguration() {
        didSet { input?.rumbleConfiguration = rumbleConfiguration }
    }
    @ObservationIgnored private var trackpad = TouchTrackpad()
    @ObservationIgnored private var swipe = MenuSwipe()
    /// How the stream menu opens besides a tap of Home (the profile's `ui_stream_menu_buttons` and `ui_stream_menu_swipe`).
    @ObservationIgnored private let menuButtons: Set<ShortcutButton>
    @ObservationIgnored private let menuSwipe: Bool
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

    init(
        capabilities: StreamMenuCapabilities = .platform, brightness: (any ScreenBrightness)? = nil,
        statisticsOverlay: StatisticsOverlay = .off, playtime: PlaytimeTracker? = nil, playtimeFlushInterval: Duration = .seconds(30),
        menuButtons: Set<ShortcutButton> = [], menuSwipe: Bool = true, onScreenControls: OnScreenControls? = nil,
        makeSteps: @escaping @MainActor () -> any StreamSteps
    ) {
        self.playtime = playtime
        self.playtimeFlushInterval = playtimeFlushInterval
        self.makeSteps = makeSteps
        self.statisticsOverlay = statisticsOverlay
        self.menuButtons = menuButtons
        self.menuSwipe = menuSwipe
        self.brightness = brightness
        self.capabilities = StreamMenuCapabilities(keyboard: capabilities.keyboard, brightness: capabilities.brightness && brightness != nil)
        if let brightness { brightnessPercent = Self.rounded(brightness.percent) }
        onScreen = onScreenControls
        steps = makeSteps()
        greeting = L("stream_loader_greeting", steps.pcName)
        onScreen?.output.send = { [weak self] state in self?.onScreenSent(state) }
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
        leavingScene = false
        phase = .connecting
        loader = LoaderCancel()
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
            if let text = StreamText.termination(termination) { fail(text) } else { phase = .ended }
        case let .rumble(controller, low, high):
            input?.rumble(controller: controller, low: low, high: high)
        case let .triggerRumble(controller, left, right):
            input?.rumbleTriggers(controller: controller, left: left, right: right)
        case let .adaptiveTriggers(controller, flags, typeLeft, typeRight, left, right):
            input?.adaptiveTriggers(controller: controller, flags: flags, typeLeft: typeLeft, typeRight: typeRight, left: left, right: right)
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
            let input = GameInput(sink: sink, menuButtons: menuButtons) { [weak self] in self?.openMenu() }
            input.rumbleConfiguration = rumbleConfiguration
            input.start()
            // The scene is still opening over the picture: B, keys and touches are the loader's, not the game's
            input.paused = true
            self.input = input
            syncOnScreen()
        }
        startStatistics()
        startPlaytime()
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
        stopPlaytime()
        stopStatistics()
        stopInput()
        hideMenu()
        phase = .failed(text)
    }

    private func stopInput() {
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
    }

    func closeMenu() {
        guard menuOpen else { return }
        hideMenu()
        input?.paused = false
    }

    /// The menu is gone, with the page that was open in it.
    private func hideMenu() {
        menuOpen = false
        menu.close()
    }

    /// The Overlay tile: off → full → compact → off (`toggleHUD` of DELOS for Android). The choice is kept for the next streams.
    func cycleStatistics() {
        statisticsOverlay = statisticsOverlay.next
        statisticsChosen?(statisticsOverlay)
    }

    // MARK: Pages of the menu

    /// What a page shows (`PageRows` of DELOS for Android's stream menu), for the actions this device has.
    func menuContent(_ page: MenuPage) -> StreamMenuContent {
        switch page {
        case .main:
            return .rows([])
        case .more:
            return .rows([
                StreamMenuRow(
                    id: MenuRowID.keys.rawValue, icon: Symbols.keyboardCommandKey, label: L("stream_menu_row_send_keys"), value: .action,
                    help: L("stream_help_send_keys"), activate: { [self] in openMenuPage(.keys) }),
                StreamMenuRow(
                    id: MenuRowID.commands.rawValue, icon: Symbols.terminal, label: L("stream_menu_row_commands"), value: .action,
                    help: L("stream_help_commands"), activate: { [self] in openMenuPage(.commands) }),
                StreamMenuRow(
                    id: MenuRowID.taskManager.rawValue, icon: Symbols.taskManager, label: L("stream_menu_row_task_manager"), value: .action,
                    help: L("stream_help_task_manager"), activate: { [self] in send(SpecialKeys.taskManager) }),
            ] + onScreenRows)
        case .brightness:
            return .rows([
                StreamMenuRow(
                    id: MenuRowID.brightness.rawValue, icon: Symbols.brightnessMedium, label: L("stream_menu_row_screen_brightness"),
                    value: .slider(value: brightnessPercent, range: Self.brightnessRange, step: Self.brightnessStep, unit: " %"),
                    help: L("stream_help_screen_brightness"), activate: {}, set: { [self] in setBrightness($0) })
            ])
        case .keys:
            let pills = SpecialKeys.all.enumerated().map { index, option in
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

    /// The tile's page opens in the popover; its own tile again closes the popover, another tile's page replaces it.
    func openMenuPage(_ page: MenuPage) {
        guard menuOpen else { return }
        if menu.page == page {
            dismissPopover()
            return
        }
        menu.open(page, focusing: menuContent(page).ids.first ?? StreamMenuState.backID)
    }

    /// B (or the back circle): one level up, to the row that opened the page or to its tile; on the dock it resumes.
    func menuBack() {
        guard menuOpen else { return }
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
        guard menuOpen else { return }
        switch StreamMenuNavigation.afterOutsideTap(menu.page) {
        case .dismissPopover(let exit): go(exit)
        case .closeMenu: closeMenu()
        }
    }

    private func go(_ exit: PageExit) {
        menu.go(exit, focusing: exit.focusRow.map { StreamMenuState.rowID($0.rawValue) })
    }

    /// Left (-1) or right (+1) on the focused row of the popover: a slider steps (faster the longer the key is held). False
    /// when the focused item adjusts nothing, so the focus moves instead.
    @discardableResult
    func adjustFocusedRow(_ direction: Int, repeatCount: Int = 0) -> Bool {
        let focusedID = menu.focus.focused?.base as? String
        guard case let .rows(rows) = menuContent(menu.page),
            let row = rows.first(where: { StreamMenuState.rowID($0.id) == focusedID }),
            row.enabled, let set = row.set,
            let next = row.stepped(direction, steps: row.acceleration(repeatCount: repeatCount))
        else { return false }
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

    /// The Keyboard tile: the menu closes, then the on-screen keyboard comes up or goes away.
    func toggleKeyboard() {
        KeyboardTileLog.note("tile: Keyboard pressed; offered \(capabilities.keyboard), shown \(keyboardShown), menu open \(menuOpen)")
        guard capabilities.keyboard else { return }
        closeMenu()
        keyboardShown.toggle()
    }

    /// The system took the keyboard away (its own hide button).
    func keyboardDismissed() {
        KeyboardTileLog.note("tile: the keyboard went away, the tile turns off")
        keyboardShown = false
    }

    func typed(_ text: String) {
        input?.type(text)
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
        hideMenu()
        keyboardShown = false
        restoreBrightness()
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
        if let brightnessChosen { brightness?.set(brightnessChosen) }
        steps = makeSteps()
        run()
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
        stopStatistics()
        hideMenu()
        // No return from the background starts another attempt now; the one that ran is the one the PC quits
        suspended = false
        let steps = self.steps
        leavingQuit = quit
        leavingScene = scene
        phase = .leaving(quit ? L("stream_exit_quitting", steps.appName) : L("stream_exit_disconnecting"))
        stopInput()
        let stopped = endAttempt()
        let hold = scene ? leavingHold : .zero
        let task = Task { @MainActor [weak self] in
            let began = ContinuousClock.now
            await stopped.value
            if quit, await !steps.quitApp() {
                self?.phase = .failed(StreamText.quitFailure(appName: steps.appName))
                return
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
        if phase == .streaming, !menuOpen { input?.paused = false }
    }

    /// A touch on the stream, in pixels of [area]: the on-screen controls take the touches that land on them, the swipe up from
    /// the band above the bottom edge opens the menu (unless the profile turned it off), the other touches are the PC's
    /// trackpad. While the controls are moved or resized, the stream gets no touch.
    func touch(_ id: Int, _ touchPhase: TouchPhase, at point: CGPoint, area: TouchArea, time: TimeInterval) {
        // A touch that ends after the menu opened (its own swipe opened it) is forgotten all the same
        if touchPhase == .ended || touchPhase == .cancelled, phase != .streaming || menuOpen || loader.cancellable {
            _ = swipe.ended(id)
            trackpad.cancelled(id)
            return
        }
        guard phase == .streaming, !menuOpen, !loader.cancellable else { return }
        if let onScreen, area.width > 0, area.height > 0 {
            let x = Float(point.x / area.width) * Float(onScreen.panel.width), y = Float(point.y / area.height) * Float(onScreen.panel.height)
            let oscPhase: OnScreenControls.Phase = switch touchPhase {
            case .began: .began
            case .moved: .moved
            case .ended: .ended
            case .cancelled: .cancelled
            }
            if onScreen.touch(id, oscPhase, x: x, y: y, time: time * 1000) { return }
            if touchPhase == .began, onScreen.mode == .move || onScreen.mode == .resize { return }
        }
        switch touchPhase {
        case .began:
            if menuSwipe, swipe.began(id, at: point, zone: area.swipeZone) { return }
            trackpad.began(id, at: point, time: time)
        case .moved:
            let (owned, open) = swipe.moved(id, to: point, height: area.height)
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
