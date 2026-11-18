import DelosData
import DelosInput
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Fully External Display Mode (`checkbox_enable_fullexdisplay`, the external-display mode of DELOS for Android,
/// docs/EXTERNAL_DISPLAY.md): while a stream runs with it on and a monitor or TV is connected, the app's window with the
/// stream and its menu goes to that screen (``ExternalDisplayPlan``) and comes back when the stream ends. If the screen
/// goes away during the stream, the stream is left, as Android finishes it (`listenForExternalDisplayRemoval`).
///
/// - iPhone and iPad: the monitor or TV is the scene the system offers with the external-display role. The app's own
///   window moves into it (`UIWindow.windowScene`, which keeps the whole interface state); the device's screen gets a
///   plain black touch surface whose touches go to the stream as its touch screen (the menu opens with the swipe up or a
///   controller). Afterwards the external scene keeps no window, so the system mirrors the device's screen again.
/// - Mac: the monitor or TV is another `NSScreen` than the built-in one (else the one with the menu bar); the app's window
///   moves there in full screen and back to where it was afterwards.
///
/// With one screen, or with the mode off, nothing is moved.
@MainActor
public final class ExternalDisplays {
    public static let shared = ExternalDisplays()

    /// The running stream and its profile's Fully External Display Mode.
    private weak var stream: StreamController?
    private var fullExternal = false
    private var observers: [any NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        #if os(iOS)
        // A monitor or TV connected during the stream takes it; one that leaves is still listed while it is told it went
        observers.append(center.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in ExternalDisplays.shared.reconcile() }
        })
        observers.append(center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { note in
            let gone = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { ExternalDisplays.shared.reconcile(without: gone) }
        })
        #elseif os(macOS)
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ExternalDisplays.shared.reconcile() }
        })
        #endif
    }

    /// A stream's screen appeared: with [fullExternal] and a monitor or TV, the app's window goes there before the video
    /// surface is laid out, so the stream takes that screen's size and refresh rate.
    func streamBegan(_ controller: StreamController, fullExternal: Bool) {
        stream = controller
        self.fullExternal = fullExternal
        reconcile()
    }

    /// The stream's screen went: the window comes back.
    func streamEnded(_ controller: StreamController) {
        guard stream === controller else { return }
        stream = nil
        fullExternal = false
        reconcile()
    }

    private func streamsOnSecond(secondConnected: Bool) -> Bool {
        ExternalDisplayPlan.streamsOnSecond(
            secondConnected: secondConnected, role: SecondDisplayRole.load(), fullExternal: fullExternal, streaming: stream != nil)
    }

    /// The monitor or TV the stream was on went away: the stream is left and the interface is back on the device's screen.
    private func secondScreenLost() {
        guard let stream else { return }
        stream.closeMenu()
        Task { await stream.leave(quit: false) }
    }

    #if os(iOS)
    /// The app's own window and the scene it belongs to, kept while it is moved.
    private weak var mainWindow: UIWindow?
    private weak var deviceScene: UIWindowScene?
    private var touchWindow: UIWindow?

    private var connectedScenes: [UIWindowScene] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    }

    /// Carries out the plan of this moment; [gone] is a scene that is disconnecting.
    func reconcile(without gone: ObjectIdentifier? = nil) {
        let scenes = connectedScenes.filter { ObjectIdentifier($0) != gone }
        let device = deviceScene ?? scenes.first { $0.session.role == .windowApplication }
        let external = scenes.first { $0.session.role == .windowExternalDisplayNonInteractive }
        guard let device, let window = mainWindow ?? device.keyWindow else { return }
        let moved = window.windowScene !== device
        if let external, streamsOnSecond(secondConnected: true) {
            deviceScene = device
            mainWindow = window
            place(window, in: external)
            showTouchSurface(in: device)
            return
        }
        guard moved || touchWindow != nil else { return }
        place(window, in: device)
        removeTouchSurface()
        mainWindow = nil
        deviceScene = nil
        if moved, external == nil { secondScreenLost() }
    }

    private func place(_ window: UIWindow, in scene: UIWindowScene) {
        guard window.windowScene !== scene else { return }
        window.windowScene = scene
        window.isHidden = false
        if scene.session.role == .windowApplication { window.makeKey() }
    }

    private func showTouchSurface(in scene: UIWindowScene) {
        guard touchWindow?.windowScene !== scene else { return }
        removeTouchSurface()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = ExternalTouchController(stream: stream)
        window.makeKeyAndVisible()
        touchWindow = window
    }

    /// Takes the touch surface off the device's screen.
    private func removeTouchSurface() {
        guard let window = touchWindow else { return }
        window.isHidden = true
        window.windowScene = nil
        touchWindow = nil
    }
    #elseif os(macOS)
    /// Where the app's window was before it was moved, and whether it was in full screen, to undo both.
    private var moved: (window: NSWindow, frame: NSRect, wasFullScreen: Bool)?

    /// The device's own screen: the built-in one, else the one with the menu bar.
    private static var deviceScreen: NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
        } ?? NSScreen.screens.first
    }

    func reconcile() {
        guard let device = Self.deviceScreen else { return }
        let second = NSScreen.screens.first { $0 !== device }
        if let second, streamsOnSecond(secondConnected: true), let window = moved?.window ?? NSApp.mainWindow ?? NSApp.keyWindow {
            move(window, to: second)
            return
        }
        guard let moved else { return }
        self.moved = nil
        if moved.window.styleMask.contains(.fullScreen) { moved.window.toggleFullScreen(nil) }
        moved.window.setFrame(moved.frame, display: true)
        if moved.wasFullScreen { moved.window.toggleFullScreen(nil) }
        if second == nil { secondScreenLost() }
    }

    /// Puts [window] on [screen] in full screen. A window in full screen cannot change screens: it leaves full screen first.
    private func move(_ window: NSWindow, to screen: NSScreen) {
        guard window.screen !== screen || !window.styleMask.contains(.fullScreen) else { return }
        let fullScreen = window.styleMask.contains(.fullScreen)
        if moved == nil { moved = (window, window.frame, fullScreen) }
        if fullScreen { window.toggleFullScreen(nil) }
        let visible = screen.visibleFrame
        let size = NSSize(width: min(window.frame.width, visible.width), height: min(window.frame.height, visible.height))
        window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: true)
        window.toggleFullScreen(nil)
    }
    #else
    func reconcile() {}
    #endif
}

#if os(iOS)
/// The device's screen while the stream is on a monitor or TV: black, landscape, the system's edge gestures deferred, and
/// a touch surface over all of it.
private final class ExternalTouchController: UIViewController {
    private weak var stream: StreamController?

    init(stream: StreamController?) {
        self.stream = stream
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() { view = ExternalTouchSurface(stream: stream) }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
}

/// Sends its touches to the stream as the stream's own surface does (``StreamController/touches(_:_:area:time:)``), in
/// pixels of this view: the touch screen's mode, the on-screen controls and the swipe up that opens the menu work on it.
private final class ExternalTouchSurface: UIView {
    private weak var stream: StreamController?

    init(stream: StreamController?) {
        self.stream = stream
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .began) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .moved) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .ended) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .cancelled) }

    private func report(_ touches: Set<UITouch>, _ phase: StreamController.TouchPhase) {
        guard let stream else { return }
        let scale = window?.windowScene?.screen.nativeScale ?? contentScaleFactor
        let area = StreamController.TouchArea(
            width: bounds.width * scale, height: bounds.height * scale, gestureInset: safeAreaInsets.bottom * scale, scale: scale)
        let samples = touches.map { touch in
            let point = touch.location(in: self)
            return TouchSample(id: ObjectIdentifier(touch).hashValue, x: point.x * scale, y: point.y * scale)
        }
        stream.touches(phase, samples, area: area, time: touches.map(\.timestamp).max() ?? 0)
    }
}
#endif
