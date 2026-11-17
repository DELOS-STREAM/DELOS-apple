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
/// The stream menu opens like on Android by default: L3 + R3 held together on a controller (``MenuShortcut``), or a
/// swipe from the left edge of the touch screen (``MenuSwipe``).
struct StreamScreen: View {
    let hostID: String
    let appID: Int
    /// The current profile's stream settings.
    let settings: StreamSettings
    /// Keeps the statistics overlay the stream menu chose (the profile's, for its next streams).
    let keepStatisticsOverlay: @MainActor (StatisticsOverlay) -> Void
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
    #endif

    init(hostID: String, appID: Int, settings: StreamSettings, keepStatisticsOverlay: @escaping @MainActor (StatisticsOverlay) -> Void = { _ in }) {
        self.hostID = hostID
        self.appID = appID
        self.settings = settings
        self.keepStatisticsOverlay = keepStatisticsOverlay
    }

    var body: some View {
        ZStack {
            if let controller, let renderer {
                StreamContent(controller: controller, renderer: renderer, focus: navigator.focus, hostID: hostID, appID: appID, settings: settings)
            }
        }
        .onAppear(perform: begin)
        .onDisappear(perform: end)
        .onChange(of: controller?.phase) { old, phase in
            if phase == .ended {
                // The PC ended the session on its own (a stream that was leaving or failed is not "closed by the PC")
                if old == .streaming || old == .connecting { toasts?.show(L("stream_result_host_closed"), icon: Symbols.info) }
                navigator.back()
            }
            // The result overlay shows: OPEN
            if case .failed = phase { layers?.feedback?.play(.open) }
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
            default: break
            }
        }
        #endif
        #if os(iOS)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        #endif
    }

    private func begin() {
        guard controller == nil else { return }
        // The display layer unless the debug switch asks for the Metal renderer (RendererChoice)
        let renderer = RendererChoice.current.makeRenderer(
            pacing: settings.framePacing, fps: settings.streamFPS(refreshRate: StreamDevice.current.maxFramesPerSecond))
        let controller = StreamController(brightness: Self.deviceBrightness, statisticsOverlay: settings.statisticsOverlay) { [hosts, hostID, appID, settings] in
            LiveStream(hosts: hosts, hostID: hostID, appID: appID, settings: settings, renderer: renderer)
        }
        controller.leavingHold = .seconds(ExitLook.handoff(reduced: reducedMotion))
        controller.menuOpened = { [navigator] in navigator.cancelRepeats?() }
        controller.statisticsChosen = keepStatisticsOverlay
        self.renderer = renderer
        self.controller = controller
        navigator.commandCapture = { [navigator] command in
            Self.capture(command, controller: controller, focus: navigator.focus, fromRemote: navigator.commandFromRemote, feedback: layers?.feedback,
                repeatCount: navigator.commandRepeat)
        }
        IdleTimer.disabled = true
        // Quitting the app (the Mac: Command-Q, closing the window) leaves the stream first
        shutdownID = StreamShutdown.shared.register { await controller.leave(quit: false) }
    }

    private func end() {
        navigator.commandCapture = nil
        controller?.restoreBrightness()
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
    /// The Siri Remote (Apple TV, [fromRemote]) has no L3 + R3: its Play/Pause opens the stream menu, and so does its
    /// Menu button when no game controller is connected (a controller's Menu button is Start for the PC, and the
    /// system also reports it as Menu). Either closes the open menu.
    static func capture(
        _ command: MenuCommand, controller: StreamController, focus: FocusModel, fromRemote: Bool = false,
        feedback: Feedback? = nil, repeatCount: Int = 0, at now: Date = .now,
        hasGamepad: @autoclosure () -> Bool = ConnectedControllers.hasGamepad
    ) -> Bool {
        switch controller.phase {
        case .streaming:
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
                Task { await controller.leave(quit: false) }
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
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion
    @Environment(HomeArt.self) private var art: HomeArt?
    @Environment(Layers.self) private var layers: Layers?
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
                            controller.start(display: info)
                        },
                        onTouch: { id, phase, point, width, time in
                            controller.touch(id, phase, at: point, width: width, time: time)
                        },
                        ignoresPointer: { controller.hasMouse },
                        capturesPointer: controller.phase == .streaming && !controller.menuOpen,
                        keyboard: controller.keyboardShown && !controller.menuOpen,
                        onText: { controller.typed($0) },
                        onBackspace: { controller.typedBackspace() },
                        onKeyboardHidden: { controller.keyboardDismissed() }
                    )
                    .ignoresSafeArea()
                    .opacity(pictureOpacity(cover))
                    // The stream behind the menu is blurred (it follows the gradient behind the tiles)
                    .blur(radius: controller.menuOpen ? stage.px(StreamDockLayout.videoBlur) : 0)
                    .animation(
                        .timingCurve(0.25, 0.1, 0.25, 1, duration: (controller.menuOpen ? StreamDockLayout.gradientIn : StreamDockLayout.gradientOut) / 1000),
                        value: controller.menuOpen)
                }
            }
            if let director, director.isActive, launching {
                LaunchLoader(director: director, card: card)
            }
            switch controller.phase {
            case .connecting:
                EmptyView()
            case .streaming:
                if controller.statisticsOverlay.isShown, let statistics = controller.statistics {
                    StreamStatsOverlay(statistics: statistics, overlay: controller.statisticsOverlay)
                }
                if dockShown {
                    StreamMenu(focus: focus, controller: controller, open: controller.menuOpen)
                        .environment(\.glassOverMedia, true)
                }
            case .leaving, .ended:
                if exitScene, let exitPortal, let leavingSince {
                    StreamExitScene(portal: exitPortal, since: leavingSince, reducedMotion: reducedMotion, focus: focus)
                }
            case .failed(let text):
                StreamResultLayer(
                    text: text, focus: focus,
                    onRetry: { controller.retry() },
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
        LaunchDirector(line: controller.line.isEmpty ? nil : controller.line, reducedMotion: reducedMotion)
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
