import DelosData
import DelosInput
import DelosMedia
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A stream of one app of one PC (`DelosStreamActivity` of DELOS for Android, as far as P4 goes): the loader while it
/// connects, the video full screen with the controllers, keyboard, mouse and touch going to the PC, a minimal stream
/// menu (Resume, Overlay, Disconnect, Quit app), the statistics panel and the result overlay when the stream failed.
///
/// The stream menu opens with a tap of a controller's Home button (a hold is Guide on the PC, ``GuideTapHold``), with the
/// buttons the profile recorded (``MenuShortcut``, none by default), and with a swipe up from the band above the bottom
/// edge of the touch screen (``StreamMenuSwipe``, unless the profile turned it off).
struct StreamScreen: View {
    let hostID: String
    let appID: Int
    /// The profile the streaming time is recorded for (nil: none).
    let profileID: String?
    /// The current profile's stream settings.
    let settings: StreamSettings
    /// Keeps the statistics overlay the stream menu chose (the profile's, for its next streams).
    let keepStatisticsOverlay: @MainActor (StatisticsOverlay) -> Void
    /// Keeps the on-screen controls' opacity the stream menu chose (the profile's).
    let keepOnScreenOpacity: @MainActor (Int) -> Void
    /// Keeps a touch mode the stream menu chose when the profile remembers it (`checkbox_remember_mouse_mode`).
    let keepTouchMode: @MainActor (TouchMode) -> Void
    /// The profile's palette: the on-screen controls' pressed colour (``OscStyle``).
    let palette: Palette
    @Environment(HostStore.self) private var hosts
    @Environment(Navigator.self) private var navigator
    @Environment(Layers.self) private var layers: Layers?
    @Environment(Toasts.self) private var toasts: Toasts?
    @Environment(\.reducedMotion) private var reducedMotion
    @State private var controller: StreamController?
    @State private var renderer: (any VideoRenderer)?
    @State private var shutdownID: UUID?
    #if !os(macOS)
    @Environment(\.scenePhase) private var scenePhase
    #else
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    init(
        hostID: String, appID: Int, profileID: String? = nil, settings: StreamSettings, palette: Palette = .delos,
        keepStatisticsOverlay: @escaping @MainActor (StatisticsOverlay) -> Void = { _ in },
        keepOnScreenOpacity: @escaping @MainActor (Int) -> Void = { _ in },
        keepTouchMode: @escaping @MainActor (TouchMode) -> Void = { _ in }
    ) {
        self.hostID = hostID
        self.appID = appID
        self.profileID = profileID
        self.settings = settings
        self.palette = palette
        self.keepStatisticsOverlay = keepStatisticsOverlay
        self.keepOnScreenOpacity = keepOnScreenOpacity
        self.keepTouchMode = keepTouchMode
    }

    var body: some View {
        ZStack {
            if let controller, let renderer {
                StreamContent(
                    controller: controller, renderer: renderer, focus: navigator.focus, hostID: hostID, appID: appID, settings: settings,
                    palette: palette)
            }
        }
        .onAppear(perform: begin)
        .onDisappear(perform: end)
        .onReceive(NotificationCenter.default.publisher(for: StreamSettingsStore.didSave)) { notification in
            guard let profileID, notification.object as? String == profileID else { return }
            controller?.rumbleConfiguration = StreamSettingsStore().load(profile: profileID).rumble
        }
        .onChange(of: controller?.phase) { old, phase in
            if phase == .ended {
                // The PC ended the session on its own (a stream that was leaving or failed is not "closed by the PC")
                if old == .streaming || old == .connecting { toasts?.show(L("stream_result_host_closed"), icon: Symbols.info) }
                // Disconnect or Quit from the menu: the exit scene bursts into the library with SELECT (`Shell.kt`'s exit arrival)
                if case .leaving? = old, controller?.leavingScene == true { layers?.feedback?.play(.select) }
                navigator.back()
            }
            // The result overlay shows: OPEN, and the hint bar says Select and Back to library while it is up
            if case .failed = phase { layers?.feedback?.play(.open) }
            if let controller, phase != .ended {
                var failed = false
                if case .failed = phase { failed = true }
                navigator.setHints(ScreenHints(streamResult: failed), from: controller)
            }
        }
        // The stream menu opens (the shortcut, a swipe, the remote): OPEN; it closes with BACK, played where it is closed
        .onChange(of: controller?.menuOpen) { _, open in
            if open == true { layers?.feedback?.play(.open) }
        }
        #if !os(macOS)
        // iOS suspends an app that goes to the background; the Mac keeps streaming behind other windows
        .onChange(of: scenePhase) { _, now in
            guard let controller else { return }
            switch now {
            case .background: controller.enteredBackground()
            case .active: controller.returnedToForeground()
            // The keyboard went elsewhere (the app switcher, Control Center): what is held comes up at the PC
            case .inactive: controller.focusLost()
            @unknown default: break
            }
        }
        #else
        // The stream's window is no longer the key one (another app or window): what is held comes up at the PC
        .onChange(of: controlActiveState) { _, now in
            if now != .key && now != .active { controller?.focusLost() }
        }
        #endif
        #if os(iOS)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        #endif
    }

    private func begin() {
        guard controller == nil else { return }
        // The Metal renderer unless the debug switch asks for the display layer (RendererChoice); the Display settings
        // (scale mode, upscaler, refresh rate) go with it
        let device = StreamDevice.current
        let renderer = RendererChoice.current.makeRenderer(
            pacing: settings.framePacing, fps: settings.streamFPS(refreshRate: device.maxFramesPerSecond),
            options: settings.videoRenderOptions(
                displayWidth: device.pixelWidth, displayHeight: device.pixelHeight, decodable: device.decodable,
                displaySupportsHDR: device.hdrDisplay))
        // Android's notice when the upscaler cannot keep up (once per stream and mode); nothing is switched off
        renderer.observeUpscalerOverload { [toasts] _, _ in
            Task { @MainActor in toasts?.show(UpscalerOverload.message, icon: Symbols.warning, durationMs: 6500, kind: .warning) }
        }
        let playtime = profileID.map { profile in
            let store = PlaytimeStore()
            return PlaytimeTracker(sink: { [hostID, appID] in store.add($0, profile: profile, hostID: hostID, appID: appID) })
        }
        let controller = StreamController(
            brightness: Self.deviceBrightness, statisticsOverlay: settings.statisticsOverlay, playtime: playtime,
            menuButtons: ShortcutButton.parse(settings.streamMenuButtons), menuSwipe: settings.streamMenuSwipe,
            onScreenControls: makeOnScreenControls(), upscaler: RendererUpscaler(renderer: renderer)
        ) { [hosts, hostID, appID, settings, toasts] in
            LiveStream(hosts: hosts, hostID: hostID, appID: appID, settings: settings, renderer: renderer) { text, kind in
                toasts?.show(text, durationMs: ToastTiming.streamShortMs, kind: kind)
            }
        }
        controller.rumbleConfiguration = settings.rumble
        controller.controllerOptions = ControllerOptions(settings: settings)
        controller.keyboardOptions = FullKeyboardOptions(settings)
        controller.fullKeyboard.prefs = KeyboardPrefs(settings)
        #if os(iOS)
        let keyboardHaptics = KeyboardHaptics()
        controller.keyboardHaptic = { keyboardHaptics.play($0) }
        #elseif os(tvOS)
        // The Siri Remote is the controller of Apple TV: the keyboard opens with its focus and hints
        controller.fullKeyboard.hasController = { true }
        #endif
        controller.touchOptions = TouchOptions(settings: settings)
        controller.zoomStore = ZoomPanStore()
        controller.touchModeChosen = keepTouchMode
        // A four-finger tap toggles the Delos full keyboard (`checkbox_multi_touch_gestures`)
        controller.fullKeyboardToggle = { [weak controller] in controller?.toggleFullKeyboard() }
        controller.zoomNotice = { [toasts] on in
            // DelosToast.SHORT of a stream
            toasts?.show(L(on ? "pan_zoom_mode_enabled" : "pan_zoom_mode_disabled"), icon: Symbols.info, durationMs: ToastTiming.streamShortMs)
        }
        controller.leavingHold = .seconds(ExitLook.handoff(reduced: reducedMotion))
        controller.warningsDisabled = settings.bool(.disableWarnings)
        // The Bitrate page's recommendation: the last link test of this PC on this kind of network (StreamMenu.kt:420-436)
        controller.bitrateRecommendation = { [hostID, settings] in
            let device = StreamDevice.current
            guard let guidance = LinkGuidance.forStream(
                hostID: hostID, settings: settings, resolution: settings.resolution(displayWidth: device.pixelWidth, displayHeight: device.pixelHeight))
            else { return nil }
            return BitrateRecommendation(line: guidance.line, kbps: guidance.recommendation.kbps, help: guidance.streamHelp())
        }
        controller.menuExitDuration = StreamDockLayout.closeTotal(count: controller.capabilities.tiles.count) / 1000
        // The menu's upscaler and gyro smoothing are kept for this game (MenuAutoSave, StreamMenu.kt:345-380), never the profile
        if let profileID {
            controller.saveForGame = { [hostID, appID] values in
                let store = GameSettingsStore()
                var game = store.load(profile: profileID, hostID: hostID, appID: appID)
                for (key, value) in values { game.values[key.rawValue] = value }
                store.save(game, profile: profileID, hostID: hostID, appID: appID)
            }
            // The Rumble feel page's preset is the profile's (`RumblePreferences.applyPreset`)
            controller.rumblePresetChosen = { preset in
                let store = StreamSettingsStore()
                var saved = store.load(profile: profileID)
                saved.rumble.profile = preset
                store.save(saved, profile: profileID)
            }
        }
        controller.menuOpened = { [navigator] in navigator.cancelRepeats?() }
        controller.statisticsChosen = keepStatisticsOverlay
        controller.onScreenOpacityChosen = keepOnScreenOpacity
        controller.inputNotice = { [toasts] event in
            switch event {
            // DelosToast.SHORT and LONG of a stream (`ToastTiming.STREAM_SHORT_MS`, `STREAM_LONG_MS`)
            case .mouseEmulation(let on):
                toasts?.show(on ? L("stream_mouse_emulation_on") : L("stream_mouse_emulation_off"), icon: Symbols.info, durationMs: ToastTiming.streamShortMs)
            case .controllerTypeChanged:
                toasts?.show(L("toast_controller_type_changed"), icon: Symbols.info, durationMs: ToastTiming.streamLongMs)
            case .keyCombo:
                break
            }
        }
        controller.toast = { [toasts] text, kind, duration in toasts?.show(text, durationMs: duration, kind: kind) }
        let keys = StreamSpecialKeys.options(
            clearDefaults: settings.bool(.enableClearDefaultSpecialButton), custom: profileID.flatMap { CustomSpecialKeys().load(profile: $0) })
        controller.specialKeys = keys.options
        controller.specialKeysFailed = keys.failed
        // Fully External Display Mode: the window goes to a monitor or TV before the video surface is laid out
        ExternalDisplays.shared.streamBegan(controller, fullExternal: settings.bool(.externalDisplayFullscreen))
        self.renderer = renderer
        self.controller = controller
        navigator.takeInput(controller) { [navigator] command in
            // A row's popup takes the commands first; B closes it before the page goes back (StreamMenuRoot.kt:250-253)
            if controller.menuOpen, let picker = controller.picker {
                picker.capture(command, navigator: navigator, feedback: layers?.feedback, close: { controller.closePicker() })
                return true
            }
            return Self.capture(command, controller: controller, focus: navigator.focus, fromRemote: navigator.commandFromRemote, feedback: layers?.feedback,
                repeatCount: navigator.commandRepeat)
        }
        IdleTimer.disabled = true
        // Quitting the app (the Mac: Command-Q, closing the window) leaves the stream first
        shutdownID = StreamShutdown.shared.register { await controller.leave(quit: false) }
    }

    private func end() {
        if let controller { navigator.releaseInput(controller) }
        controller?.restoreBrightness()
        if let controller { ExternalDisplays.shared.streamEnded(controller) }
        IdleTimer.disabled = false
        if let shutdownID { StreamShutdown.shared.unregister(shutdownID) }
        shutdownID = nil
        // Leaving the screen any other way than through the menu disconnects (the app keeps running on the PC)
        if let controller { Task { await controller.leave(quit: false) } }
    }

    /// Who gets a controller or keyboard command: the PC while the stream runs (``GameInput`` sends it), the stream
    /// menu or the result overlay while they are shown (through the screen's focus); B closes the menu, leaves the
    /// result overlay (Back to library) and stops a stream that is still connecting.
    ///
    /// The Siri Remote (Apple TV, [fromRemote]) has no Home button for the stream (its TV button is the system's). Its Back
    /// button is the device's Back: a press opens the stream menu when no game controller is connected (a controller's Menu
    /// button is Start for the PC, and the system also reports it as Menu). SwiftUI reports that button only as the exit
    /// command, without how long it was held, so its hold cannot be Guide. Play/Pause opens the menu too; either closes it.
    static func capture(
        _ command: MenuCommand, controller: StreamController, focus: FocusModel, fromRemote: Bool = false,
        feedback: Feedback? = nil, repeatCount: Int = 0, at now: Date = .now,
        hasGamepad: @autoclosure () -> Bool = ConnectedControllers.hasGamepad
    ) -> Bool {
        switch controller.phase {
        case .streaming:
            // The launch scene still opens over the picture: B and Escape cancel it, nothing else reaches the game or the menu
            if controller.loaderCancellable {
                if command == .back {
                    feedback?.play(.back)
                    Task { await controller.cancelLoader() }
                }
                return true
            }
            // The Siri Remote's Back closes the full keyboard (a controller's B does it through the keyboard itself)
            if fromRemote, command == .back, !controller.menuOpen, controller.fullKeyboard.open, !hasGamepad() {
                feedback?.play(.back)
                controller.closeFullKeyboard()
                return true
            }
            let remoteMenu = fromRemote && (command == .options || (command == .back && !hasGamepad()))
            guard controller.menuOpen else {
                if remoteMenu { controller.openMenu() }
                return true
            }
            if command == .back {
                // One level up: a page goes back to its row or tile, the dock resumes
                feedback?.play(.back)
                controller.menuBack()
                return true
            }
            if remoteMenu {
                feedback?.play(.back)
                controller.closeMenu()
                return true
            }
            // A page of the popover has the commands: its own focus, and a slider takes left and right
            if controller.menu.isOpen {
                capturePopover(command, controller: controller, feedback: feedback, repeatCount: repeatCount, at: now)
                return true
            }
            // A direction or A still held from the game is not a choice: nothing reaches the menu's focus until the
            // menu has been open a moment, and a repeat of a held direction never does
            return !controller.menuIsArmed(at: now) || repeatCount > 0
        case .failed:
            if command == .back {
                feedback?.play(.back)
                controller.dismiss()
                return true
            }
            return false
        case .connecting:
            if command == .back {
                feedback?.play(.back)
                Task { await controller.cancelLoader() }
            }
            return true
        case .leaving, .ended:
            return true
        }
    }

    /// A command while a page of the stream menu is open: A, the directions and left / right on a slider go to the popover's
    /// focus (the dock keeps its own; the focus cannot leave the popover). A repeat of a held direction moves the focus
    /// within the page and steps a slider faster; the page's rows do not wrap.
    private static func capturePopover(
        _ command: MenuCommand, controller: StreamController, feedback: Feedback?, repeatCount: Int, at now: Date
    ) {
        let menu = controller.menu
        switch command {
        case .accept:
            guard repeatCount == 0, !menu.swallowsAccept(at: now) else { return }
            if let feedback { feedback.activate(menu.focus.acceptCue) { menu.focus.handle(.accept) } } else { menu.focus.handle(.accept) }
        case .up, .down:
            if menu.focus.handle(command) { feedback?.play(.move) }
        case .left, .right:
            if controller.adjustFocusedRow(command == .right ? 1 : -1, repeatCount: repeatCount) {
                feedback?.play(.move)
            } else if menu.focus.handle(command) {
                feedback?.play(.move)
            }
        default:
            break
        }
    }

    /// The screen's brightness, where the device has it to change.
    private static var deviceBrightness: (any ScreenBrightness)? {
        #if os(iOS)
        DeviceBrightness()
        #else
        nil
        #endif
    }

    /// The on-screen controls of this stream on iPhone and iPad (`initVirtualController`): up when the profile shows them
    /// (`checkbox_show_onscreen_controls`), hidden while a controller is in use when it says so
    /// (`checkbox_hide_osc_when_has_gamepad`). Apple TV and the Mac have no touchscreen and no on-screen controls.
    private func makeOnScreenControls() -> OnScreenControls? {
        #if os(iOS)
        var output = OscOutput()
        if let profileID { output.storing(profile: profileID) }
        output.announce = { [toasts] text in toasts?.show(text, icon: Symbols.settings) }
        let haptics = OscPressHaptics()
        output.vibrate = { haptics.play($0) }
        return OnScreenControls(
            options: OscOptions(settings), enabled: settings.bool(.showOnscreenControls),
            followsGamepad: settings.bool(.hideOscWhenHasGamepad), output: output)
        #else
        nil
        #endif
    }
}

/// What the stream screen shows in each phase: the launch scene while it connects and opens (`StreamLoader` and
/// `LaunchOverlay` of DELOS for Android), the video with the menu and the statistics, the exit scene while it is left
/// from the menu (`StreamExit`) and the result overlay when it failed.
struct StreamContent: View {
    let controller: StreamController
    let renderer: any VideoRenderer
    let focus: FocusModel
    let hostID: String
    let appID: Int
    let settings: StreamSettings
    let palette: Palette
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion
    @Environment(HomeArt.self) private var art: HomeArt?
    @Environment(Layers.self) private var layers: Layers?
    @Environment(HostStore.self) private var hosts: HostStore?
    @Environment(Navigator.self) private var navigator: Navigator?
    @Environment(Toasts.self) private var toasts: Toasts?
    /// The dock is mounted while the menu is open and for its exit after it closed.
    @State private var dockShown = false
    @State private var unmount: Task<Void, Never>?
    /// The launch scene's clock and choreography; a new one for each attempt.
    @State private var director: LaunchDirector?
    @State private var display: DisplayInfo?
    @State private var logo: CGImage?
    /// When the exit scene began, and what it says.
    @State private var leavingSince: Date?
    @State private var exitPortal: Portal?

    var body: some View {
        ZStack {
            // Black under the video and the exit; the loader and the result overlay lie on DELOS's background. In the exit
            // scene the picture blurs, zooms in a little and gives way to the background.
            StreamExitMotion(since: exitScene ? leavingSince : nil, reducedMotion: reducedMotion) { cover in
                ZStack {
                    Color.black.ignoresSafeArea().opacity(pictureOpacity(cover))
                        .preference(key: VideoCoversBackdrop.self, value: showsBlack)
                    VideoSurface(
                        renderer: renderer,
                        onDisplay: { info in
                            display = info
                            let size = settings.resolution(displayWidth: info.pixelWidth, displayHeight: info.pixelHeight)
                            controller.touchPicture = TouchPicture(
                                width: size.width, height: size.height, fit: PictureFit(VideoScaleMode(value: settings.text(.videoScaleMode))))
                            controller.start(display: info)
                        },
                        onTouches: { phase, samples, area, time in
                            controller.touches(phase, samples, area: area, time: time)
                        },
                        onPenHover: { point, distance, azimuth, altitude, area, time in
                            controller.penHover(at: point, distance: distance, azimuth: azimuth, altitude: altitude, area: area, time: time)
                        },
                        onPointer: { point, area in controller.pointerMoved(to: point, area: area) },
                        onScroll: { dx, dy, precise in controller.scrollWheel(dx: dx, dy: dy, precise: precise) },
                        onLayout: { controller.surfaceLaidOut($0) },
                        zoom: controller.videoZoom,
                        ignoresPointer: { controller.hasMouse },
                        capturesPointer: capturesPointer,
                        keyboard: controller.systemKeyboardShown && !controller.menuOpen,
                        onText: { controller.typed($0) },
                        onBackspace: { controller.typedBackspace() },
                        onKeyboardHidden: { controller.keyboardDismissed() }
                    )
                    .ignoresSafeArea()
                    .opacity(pictureOpacity(cover))
                    // The stream behind the menu is blurred (it follows the gradient behind the tiles)
                    // Sharp while the Upscaler page is open, so its changes can be judged (StreamMenuRoot.kt:167-170,298-300)
                    .blur(radius: controller.menuOpen && controller.menu.page != .upscaler ? stage.px(StreamDockLayout.videoBlur) : 0)
                    .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: StreamDockLayout.gradientIn / 1000), value: controller.menu.page == .upscaler)
                    .animation(
                        .timingCurve(0.25, 0.1, 0.25, 1, duration: (controller.menuOpen ? StreamDockLayout.gradientIn : StreamDockLayout.gradientOut) / 1000),
                        value: controller.menuOpen)
                }
            }
            #if os(iOS)
            // The on-screen controls over the picture, under the launch scene and the menu; blurred with the picture behind
            // the menu. Their touches come from the video surface (``StreamController/touch(_:_:at:area:time:)``)
            if let onScreen = controller.onScreen, controller.phase == .streaming {
                OnScreenControlsCanvas(controls: onScreen, palette: palette)
                    .ignoresSafeArea()
                    .blur(radius: controller.menuOpen && controller.menu.page != .upscaler ? stage.px(StreamDockLayout.videoBlur) : 0)
            }
            #endif
            // The Delos full keyboard over the picture and the on-screen controls, under the launch scene and the menu
            if controller.fullKeyboard.present, controller.phase == .streaming {
                FullKeyboardLayer(state: controller.fullKeyboard)
                    .ignoresSafeArea()
                    .blur(radius: controller.menuOpen ? stage.px(StreamDockLayout.videoBlur) : 0)
            }
            if let director, director.isActive, launching {
                LaunchLoader(director: director, card: card, onCancel: {
                    layers?.feedback?.play(.back)
                    Task { await controller.cancelLoader() }
                })
            }
            switch controller.phase {
            case .connecting:
                EmptyView()
            case .streaming:
                if dockShown {
                    StreamMenu(focus: focus, controller: controller, open: controller.menuOpen)
                        .environment(\.glassOverMedia, true)
                }
                // Over the menu's backdrop, sharp (Android moves it into the menu's window, DelosStreamActivity.java:2046)
                if controller.statisticsOverlay.isShown, let statistics = controller.statistics {
                    StreamStatsOverlay(statistics: statistics, overlay: controller.statisticsOverlay, position: settings.statsPosition)
                }
                if let notice = controller.connectionNotice {
                    StreamConnectionNotice(text: notice)
                }
            case .leaving, .ended:
                if exitScene, let exitPortal, let leavingSince {
                    StreamExitScene(portal: exitPortal, since: leavingSince, reducedMotion: reducedMotion, focus: focus)
                }
            case .failed(let text):
                StreamResultLayer(
                    text: text, focus: focus,
                    onRetry: {
                        StreamRetry.run(controller: controller, hosts: hosts, navigator: navigator, toasts: toasts, feedback: layers?.feedback,
                                        hostID: hostID, appID: appID)
                    },
                    onBack: { controller.dismiss() })
            }
            #if os(tvOS)
            // Menu and Play/Pause reach the app only through a focused view: while nothing else is focusable (the
            // loader, the running stream) this one holds the focus, so Menu does not leave the app for Apple TV's Home
            if holdsFocus {
                FocusItem(id: Self.sinkID, model: focus, action: {}) { _ in Color.clear.frame(width: 2, height: 2) }
                    .onAppear { focus.focus(Self.sinkID) }
            }
            #endif
        }
        .onAppear {
            if director == nil { director = makeDirector() }
        }
        .task { await loadLogo() }
        .task(id: controller.phase == .streaming) { await watchFirstFrame() }
        // The on-screen controls hide while a controller is the input in use (`checkbox_hide_osc_when_has_gamepad`)
        .onChange(of: ControllerGlyphs.shared.kind, initial: true) { _, kind in controller.onScreen?.setGamepadInUse(kind == .controller) }
        .onChange(of: controller.line) { _, line in
            if !line.isEmpty { director?.stage(line) }
        }
        .onChange(of: controller.menuOpen) { _, open in
            unmount?.cancel()
            if open {
                dockShown = true
            } else {
                unmount = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(Int(StreamDockLayout.closeTotal(count: controller.capabilities.tiles.count))))
                    guard !Task.isCancelled else { return }
                    dockShown = false
                }
            }
        }
        // The launch scene is over: the stream is the player's (input, touches and the menu come alive)
        .onChange(of: director?.isActive) { _, active in
            if active == false { controller.loaderEnded() }
        }
        .onChange(of: controller.phase) { old, phase in
            dockShown = controller.menuOpen
            switch phase {
            case .connecting:
                // Another attempt (Try again, back from the background): a new launch
                if old != .connecting { director = makeDirector() }
                leavingSince = nil
                exitPortal = nil
            case .streaming:
                director?.gameRuns()
            case .leaving(let text):
                director?.stop()
                guard controller.leavingScene else { break }
                leavingSince = Date()
                exitPortal = Portal(
                    id: -1, icon: controller.leavingQuit ? Symbols.powerSettingsNew : Symbols.home, label: text,
                    sub: controller.pcName, cancellable: false)
                layers?.feedback?.play(.open)
            case .failed, .ended:
                director?.stop()
            }
        }
    }

    static let sinkID = "stream-sink"

    /// A launch scene for a new attempt; its first line is the stage told so far, if any.
    private func makeDirector() -> LaunchDirector {
        LaunchDirector(line: controller.line.isEmpty ? nil : controller.line, reducedMotion: reducedMotion, renderer: renderer)
    }

    /// The launch scene's words.
    private var card: LaunchCard {
        LaunchCard(
            title: controller.appName, logo: logo, parameters: LaunchText.parameters(settings: settings, display: display),
            greeting: controller.greeting)
    }

    /// The launch scene is up while the stream connects and opens over the picture.
    private var launching: Bool {
        switch controller.phase {
        case .connecting, .streaming: true
        case .leaving, .failed, .ended: false
        }
    }

    /// The input released (Control + Alt + Shift + Z) or the local pointer shown (Control + Alt + Shift + C) frees the pointer
    /// too (Android's `disableCapture` and `showCursor`, which both release the pointer capture); so does the full keyboard,
    /// whose keys the pointer clicks.
    private var capturesPointer: Bool {
        Self.capturesPointer(phase: controller.phase, menuOpen: controller.menuOpen, loaderUp: director?.isActive == true)
            && controller.inputGrabbed && !controller.localCursorVisible && !controller.fullKeyboard.open
    }

    /// The pointer is the stream's (locked and hidden, ``PointerLock``): the stream runs and neither its menu, the loader
    /// nor the result overlay is shown. Leaving, the exit scene and a stream suspended in the background free it.
    static func capturesPointer(phase: StreamController.Phase, menuOpen: Bool, loaderUp: Bool) -> Bool {
        phase == .streaming && !menuOpen && !loaderUp
    }

    /// The exit scene of a leaving from the stream menu.
    private var exitScene: Bool {
        switch controller.phase {
        case .leaving, .ended: controller.leavingScene
        case .connecting, .streaming, .failed: false
        }
    }

    /// How much of the picture (and the black under it) shows: all of it while the stream runs, what the exit scene has not
    /// covered yet while it is left from the menu.
    private func pictureOpacity(_ cover: Double) -> Double {
        switch controller.phase {
        case .streaming: 1
        case .leaving, .ended: exitScene ? 1 - cover : 0
        case .connecting, .failed: 0
        }
    }

    /// Whether the picture covers the screen, so the animated background is not drawn: while the stream runs and while the
    /// launch scene (opaque until it opens) is up.
    private var showsBlack: Bool { controller.phase == .streaming || launching }

    /// Whether no other view of the stream screen can take the focus.
    private var holdsFocus: Bool {
        switch controller.phase {
        case .connecting, .leaving: true
        case .streaming: !controller.menuOpen
        case .failed, .ended: false
        }
    }

    /// The game's logo, if it has one, replaces the title in the launch scene.
    private func loadLogo() async {
        guard let art else { return }
        logo = art.cachedImage(hostID: hostID, appID: appID, kind: .logo)
        if logo == nil { logo = await art.image(hostID: hostID, appID: appID, kind: .logo) }
    }

    /// Tells the launch scene when the renderer has presented a frame (it waits for that, at most 3 s).
    private func watchFirstFrame() async {
        guard controller.phase == .streaming else { return }
        while !Task.isCancelled {
            if let counters = await renderer.presentationCounters(), counters.totalFrames > 0 {
                director?.framePresented()
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// True while the video covers the whole screen: the animated background behind it is not drawn then, so it costs the
/// GPU nothing during the stream.
struct VideoCoversBackdrop: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The result overlay (`StreamResultLayer` of DELOS for Android): a sad face, the title, one sentence, Try again
/// (focused first) and Back to library, and the technical details behind Details, never open at first. B is Back
/// to library.
private struct StreamResultLayer: View {
    let text: ResultText
    let focus: FocusModel
    let onRetry: @MainActor () -> Void
    let onBack: @MainActor () -> Void
    @State private var expanded = false
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        ZStack {
            colors.scrim.color.ignoresSafeArea()
            VStack(spacing: stage.px(24)) {
                ZStack {
                    Circle().fill(colors.accent.opacity(0.16).color)
                        .overlay(Circle().strokeBorder(colors.accent.opacity(0.42).color, lineWidth: stage.px(2)))
                    SymbolView(symbol: Symbols.sentimentDissatisfied, size: 128, color: colors.accent, filled: true)
                }
                .frame(width: stage.px(220), height: stage.px(220))
                Text(text.title)
                    .font(DelosFonts.unbounded(stage.tpx(stage.compact ? 42 : 52)))
                    .foregroundStyle(colors.text.color)
                    .multilineTextAlignment(.center)
                    .padding(.top, stage.px(8))
                if !text.sentence.isEmpty {
                    Text(text.sentence)
                        .font(DelosFonts.figtree(stage.tpx(28)))
                        .foregroundStyle(colors.text2.color)
                        .multilineTextAlignment(.center)
                        .lineSpacing(stage.px(28) * 0.4)
                        .frame(maxWidth: stage.px(1000))
                }
                HStack(spacing: stage.px(24)) {
                    FocusItem(id: "result-retry", model: focus, action: onRetry) { focused in
                        PillButton(label: L("stream_result_try_again"), icon: Symbols.refresh, primary: true, focused: focused)
                    }
                    FocusItem(id: "result-back", model: focus, clickCue: .back, action: onBack) { focused in
                        PillButton(label: L("stream_result_back_to_library"), icon: Symbols.library, focused: focused)
                    }
                }
                .padding(.top, stage.px(12))
                if let details = text.details, !details.isEmpty {
                    FocusItem(id: "result-details", model: focus, action: { expanded.toggle() }) { focused in
                        HStack(spacing: stage.px(8)) {
                            Text(L("stream_result_details"))
                                .font(DelosFonts.figtree(stage.tpx(22), .semibold))
                                .foregroundStyle(colors.text2.color)
                            SymbolView(symbol: expanded ? Symbols.expandLess : Symbols.expandMore, size: 26, color: colors.text2)
                        }
                        .padding(.horizontal, stage.px(26))
                        .padding(.vertical, stage.px(12))
                        .focusLook(focused, scale: 1.06, ring: 3, glowBlur: 0, glowY: 0)
                    }
                    if expanded {
                        ScrollView {
                            Text(details)
                                .font(DelosFonts.figtree(stage.tpx(22)))
                                .foregroundStyle(colors.text2.color)
                                .lineSpacing(stage.px(22) * 0.4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, stage.px(32))
                                .padding(.vertical, stage.px(22))
                        }
                        .frame(maxWidth: stage.px(1100), maxHeight: stage.px(stage.compact ? 200 : 280))
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GlassShape(RoundedRectangle(cornerRadius: stage.px(28)), tint: colors.surface, role: .panel))
                        .overlay(RoundedRectangle(cornerRadius: stage.px(28)).strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                        .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, stage.px(48))
            .animation(.easeOut(duration: 0.25), value: expanded)
        }
        .onAppear { focus.focus("result-retry") }
    }
}

/// Keeps the screen on during a stream (`UIApplication.isIdleTimerDisabled`). On the Mac it is a process activity: the
/// display stays awake, and App Nap does not slow the stream down while another window covers the video.
@MainActor
private enum IdleTimer {
    #if os(macOS)
    private static var activity: (any NSObjectProtocol)?
    #endif

    static var disabled: Bool {
        get {
            #if os(iOS) || os(tvOS)
            UIApplication.shared.isIdleTimerDisabled
            #elseif os(macOS)
            activity != nil
            #else
            false
            #endif
        }
        set {
            #if os(iOS) || os(tvOS)
            UIApplication.shared.isIdleTimerDisabled = newValue
            #elseif os(macOS)
            if newValue {
                guard activity == nil else { return }
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Streaming from a PC")
            } else if let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
            #endif
        }
    }
}
