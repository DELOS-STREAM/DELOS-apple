import DelosInput
import DelosMedia
import SwiftUI

/// The video of a stream: hosts the renderer's layer (the display layer or the Metal layer) full size, aspect fit on
/// black, zoomed and panned by ``zoom`` (iPhone and iPad). Reports the display it is shown on (once it is in a window), its
/// size, on iPhone and iPad the touches, the pencil's hover and the system pointer on it in pixels, on the Mac the pointer
/// and the scrolling over it.
struct VideoSurface {
    let renderer: any VideoRenderer
    let onDisplay: @MainActor (DisplayInfo) -> Void
    var onTouches: @MainActor (_ phase: StreamController.TouchPhase, _ samples: [TouchSample], _ area: StreamController.TouchArea, _ time: TimeInterval) -> Void = { _, _, _, _ in }
    /// The pencil hovers at a point (nil: it left), its distance 0…1, azimuth and altitude (radians).
    var onPenHover: @MainActor (_ point: CGPoint?, _ distance: Double, _ azimuth: Double?, _ altitude: Double?, _ area: StreamController.TouchArea, _ time: TimeInterval) -> Void = { _, _, _, _, _, _ in }
    /// The system pointer (a mouse or trackpad) is at a point of the surface.
    var onPointer: @MainActor (_ point: CGPoint, _ area: StreamController.TouchArea) -> Void = { _, _ in }
    /// The Mac's scrolling: AppKit's deltas, in pixels when `precise` (a trackpad), else in lines.
    var onScroll: @MainActor (_ dx: Double, _ dy: Double, _ precise: Bool) -> Void = { _, _, _ in }
    /// The surface was laid out at a size.
    var onLayout: @MainActor (StreamController.TouchArea) -> Void = { _ in }
    var zoom = VideoZoom()
    /// Whether a touch of the system pointer (a mouse or trackpad) is ignored: the mouse's own input already moves the
    /// PC's pointer.
    var ignoresPointer: @MainActor () -> Bool = { false }
    /// Whether the stream wants the system pointer locked to it (``PointerLock``: the Mac and iPad): hidden and detached
    /// from the mouse or trackpad, whose motion the PC gets as relative movement through GameController's `GCMouse`.
    var capturesPointer = false
    /// Whether the on-screen keyboard is up (iPhone and iPad): what is typed goes to the PC as text, Return, Tab and Backspace
    /// as keys.
    var keyboard = false
    var onText: @MainActor (String) -> Void = { _ in }
    var onBackspace: @MainActor () -> Void = {}
    /// The system took the keyboard away (its own hide button).
    var onKeyboardHidden: @MainActor () -> Void = {}
    /// Picture in Picture may take the stream when the app leaves (iPhone and iPad, with a ``PictureInPictureVideo``
    /// renderer), and what its window did.
    var pictureInPicture = false
    var onPictureInPicture: @MainActor (PictureInPictureEvent) -> Void = { _ in }
}

#if canImport(UIKit)
import UIKit

extension VideoSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> VideoHostView {
        let view = VideoHostView(renderer: renderer)
        update(view)
        return view
    }

    func updateUIView(_ view: VideoHostView, context: Context) {
        update(view)
    }

    static func dismantleUIView(_ view: VideoHostView, coordinator: ()) {
        #if os(iOS)
        view.releasePointer()
        #endif
    }

    @MainActor private func update(_ view: VideoHostView) {
        view.onDisplay = onDisplay
        view.onTouches = onTouches
        view.onPenHover = onPenHover
        view.onPointer = onPointer
        view.onLayout = onLayout
        view.zoom = zoom
        view.ignoresPointer = ignoresPointer
        view.onText = onText
        view.onBackspace = onBackspace
        view.onKeyboardHidden = onKeyboardHidden
        view.setKeyboard(keyboard)
        #if os(iOS)
        view.capturesPointer = capturesPointer
        view.setPictureInPicture(pictureInPicture, onEvent: onPictureInPicture)
        #endif
    }
}

#if os(iOS)
/// What the app's root view controller answers for `prefersPointerLocked` (iPadOS asks only the root, or the child it
/// names): whether a stream wants the pointer now. ``VideoHostView``'s ``PointerLock`` sets it.
@MainActor
public enum StreamPointerLock {
    public private(set) static var prefersLocked = false

    /// Asks every window's root view controller again (`setNeedsUpdateOfPrefersPointerLocked`).
    static func set(_ locked: Bool) {
        prefersLocked = locked
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for root in windows.compactMap(\.rootViewController) { root.setNeedsUpdateOfPrefersPointerLocked() }
    }
}

/// iPadOS's pointer lock: the root view controller's preference (``StreamPointerLock``); [changed] runs after each change,
/// so the video's pointer style follows.
@MainActor
private final class ScenePointerBackend: PointerLockBackend {
    private let changed: @MainActor () -> Void

    init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
    }

    func lock() {
        StreamPointerLock.set(true)
        changed()
    }

    func unlock() {
        StreamPointerLock.set(false)
        changed()
    }
}
#endif

/// The thin UIKit host of the video layer (the one UIKit view of the app, docs/ENGINEERING_RULES.md).
final class VideoHostView: UIView {
    private let renderer: any VideoRenderer
    var onDisplay: @MainActor (DisplayInfo) -> Void = { _ in }
    var onTouches: @MainActor (StreamController.TouchPhase, [TouchSample], StreamController.TouchArea, TimeInterval) -> Void = { _, _, _, _ in }
    var onPenHover: @MainActor (CGPoint?, Double, Double?, Double?, StreamController.TouchArea, TimeInterval) -> Void = { _, _, _, _, _, _ in }
    var onPointer: @MainActor (CGPoint, StreamController.TouchArea) -> Void = { _, _ in }
    var onLayout: @MainActor (StreamController.TouchArea) -> Void = { _ in }
    /// The picture's zoom and pan, in pixels (``VideoZoom``): the renderer's layer is drawn through it.
    var zoom = VideoZoom() {
        didSet { if zoom != oldValue { applyZoom() } }
    }
    var ignoresPointer: @MainActor () -> Bool = { false }
    var onText: @MainActor (String) -> Void = { _ in }
    var onBackspace: @MainActor () -> Void = {}
    var onKeyboardHidden: @MainActor () -> Void = {}
    /// The keyboard was asked for (not taken away by the system).
    private var keyboardWanted = false
    #if os(iOS)
    /// A stream wants the pointer: it runs, and neither its menu, the loader nor the result overlay is shown.
    var capturesPointer = false {
        didSet { pointer.setWanted(capturesPointer) }
    }
    private lazy var pointer = PointerLock(backend: ScenePointerBackend { [weak self] in self?.pointerStyle.invalidate() })
    /// Hides the pointer over the video when iPadOS refused the lock (``PointerLock/hidesPointer``).
    private lazy var pointerStyle = UIPointerInteraction(delegate: self)
    private var sceneObservers: [NSObjectProtocol] = []
    /// Picture in Picture over the renderer's layer for it (``PictureInPictureVideo``); nil without one.
    private var pictureInPicture: StreamPictureInPicture?
    private var pictureInPictureWanted = false
    #endif

    init(renderer: any VideoRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        backgroundColor = .black
        #if os(iOS)
        isMultipleTouchEnabled = true
        addInteraction(pointerStyle)
        KeyboardTileLog.observeSystem()
        // The pencil hovering above the screen, and the system pointer while the local pointer is shown
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
        // Picture in Picture's layer lies under the stream's own (the Metal layer) and shows the same pictures
        if let video = renderer as? PictureInPictureVideo {
            if !video.sharesLayer { layer.addSublayer(video.contentLayer) }
            pictureInPicture = StreamPictureInPicture(video: video)
        }
        #endif
        layer.addSublayer(renderer.hostLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Raises or lowers the on-screen keyboard: this view is the first responder while it is up.
    func setKeyboard(_ shown: Bool) {
        #if os(iOS)
        guard shown != keyboardWanted else { return }
        KeyboardTileLog.note("video: keyboard wanted \(shown); \(keyboardState)")
        keyboardWanted = shown
        if shown {
            raiseKeyboard(retries: Self.raiseRetries)
        } else {
            _ = resignFirstResponder()
        }
        #endif
    }

    #if os(iOS)
    /// How often a refused first responder is tried again, and how long after.
    private static let raiseRetries = 5
    private static let raiseRetryDelay = Duration.milliseconds(100)

    /// Takes the first responder, which brings the keyboard up. Refused (the view is not in a window yet, the app is not
    /// active yet): tried again a moment later, and when it never works the Keyboard tile is told, so it does not stay lit
    /// over a keyboard that is not there.
    private func raiseKeyboard(retries: Int) {
        guard keyboardWanted, !isFirstResponder else { return }
        if window != nil, becomeFirstResponder() {
            #if DEBUG
            // Whether the system showed a keyboard for it: the notifications are logged too
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                KeyboardTileLog.note("video: 0.5 s after taking the first responder; \(self.keyboardState)")
            }
            #endif
            return
        }
        KeyboardTileLog.note("video: first responder refused, \(retries) tries left; \(keyboardState)")
        guard retries > 0 else {
            keyboardWanted = false
            KeyboardTileLog.note("video: gives up, the Keyboard tile turns off")
            Task { @MainActor [onKeyboardHidden] in onKeyboardHidden() }
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.raiseRetryDelay)
            self?.raiseKeyboard(retries: retries - 1)
        }
    }

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        KeyboardTileLog.note("video: becomeFirstResponder \(became); \(keyboardState)")
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        // Who took it: the frames that led here (a responder that took the first responder, UIKit's own hide button)
        KeyboardTileLog.note("video: resignFirstResponder \(resigned), keyboard wanted \(keyboardWanted); from "
            + Thread.callStackSymbols.dropFirst().prefix(12).joined(separator: " | "))
        guard resigned else { return resigned }
        // The system's own hide button: the menu's Keyboard tile turns off
        if keyboardWanted {
            keyboardWanted = false
            Task { @MainActor [onKeyboardHidden] in onKeyboardHidden() }
        }
        // The keys of the interface belong to the interface again (the menu's arrows must not reach the system)
        Task { @MainActor in NotificationCenter.default.post(name: MenuKeyOwnerView.reclaim, object: nil) }
        return resigned
    }

    /// Debug builds: the facts that decide whether UIKit shows the keyboard (`KeyboardTileLog`).
    private var keyboardState: String {
        #if DEBUG
        let scene = window?.windowScene
        let windowState = window.map { "key \($0.isKeyWindow)" } ?? "none"
        let sceneState = scene.map { "\($0.activationState.rawValue)" } ?? "none"
        return "self first responder \(isFirstResponder), app first responder \(KeyboardTileLog.firstResponder), window \(windowState), "
            + "scene state \(sceneState), hardware keyboard \(KeyboardTileLog.hardwareKeyboard), pointer lock wanted "
            + "\(StreamPointerLock.prefersLocked), locked \(scene?.pointerLockState?.isLocked == true)"
        #else
        ""
        #endif
    }

    // A hardware keyboard types into the first responder as well as through GameController, which already sends its keys to the
    // PC: the system's own delivery of the same key to the keyboard (as text) would type it twice. These keys end here.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) { swallowKeys(presses) { super.pressesBegan($0, with: event) } }
    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) { swallowKeys(presses) { super.pressesChanged($0, with: event) } }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) { swallowKeys(presses) { super.pressesEnded($0, with: event) } }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { swallowKeys(presses) { super.pressesCancelled($0, with: event) } }

    private func swallowKeys(_ presses: Set<UIPress>, rest: (Set<UIPress>) -> Void) {
        let others = presses.filter { $0.key == nil }
        if !others.isEmpty { rest(others) }
    }

    // The keyboard types plain text: no corrections, capitals or smart punctuation for the PC
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    #endif

    override func layoutSubviews() {
        super.layoutSubviews()
        renderer.resize(to: bounds, scale: window?.windowScene?.screen.nativeScale ?? contentScaleFactor)
        applyZoom()
        #if os(iOS)
        // Fully External Display Mode moves the window to another scene, which lays the view out again
        applyPictureInPicture()
        #endif
        // Not inside the layout pass: the stream measures its touches against the new size
        let area = touchArea
        Task { @MainActor [onLayout] in onLayout(area) }
    }

    private var pixelScale: CGFloat { window?.windowScene?.screen.nativeScale ?? contentScaleFactor }

    private var touchArea: StreamController.TouchArea {
        let scale = pixelScale
        return StreamController.TouchArea(
            width: bounds.width * scale, height: bounds.height * scale, gestureInset: gestureInset * scale, scale: scale)
    }

    /// Draws the renderer's layer through ``zoom``. The sublayer transform works about the middle of the view, so the zoom's
    /// offset (about the top left corner) moves by what scaling about the middle adds.
    private func applyZoom() {
        let scale = pixelScale
        let offsetX = zoom.tx / scale + (zoom.scale - 1) * bounds.midX
        let offsetY = zoom.ty / scale + (zoom.scale - 1) * bounds.midY
        layer.sublayerTransform = CATransform3DMakeAffineTransform(
            CGAffineTransform(a: zoom.scale, b: 0, c: 0, d: zoom.scale, tx: offsetX, ty: offsetY))
    }

    /// Keeps the display at the refresh rate the renderer planned (``DisplayRefreshPlanner``, Android's `setFrameRate`) while
    /// the video is shown. ProMotion screens slow down to save power when nothing asks for more, and the display layer
    /// alone does not ask: a 120 fps stream ran at 60 and stuttered on the owner's iPad Pro (M5). Moonlight for iOS keeps a
    /// display link for the same reason.
    private var refreshLink: CADisplayLink?

    @objc private func refreshTick(_ link: CADisplayLink) {}

    #if os(tvOS)
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // The TV goes back to its own mode when the stream leaves
        if newWindow == nil, let window { StreamDisplay.resetCriteria(of: window) }
    }
    #endif

    override func didMoveToWindow() {
        super.didMoveToWindow()
        #if os(iOS)
        // The keyboard was asked for before the view had a window
        if window != nil { raiseKeyboard(retries: Self.raiseRetries) }
        followScene()
        applyPictureInPicture()
        #endif
        refreshLink?.invalidate()
        refreshLink = nil
        guard let screen = window?.windowScene?.screen else {
            renderer.detached()
            return
        }
        #if os(iOS)
        let external = window?.windowScene?.session.role != .windowApplication
        #else
        let external = false
        #endif
        let display = StreamDisplay.describe(screen, external: external)
        let plan = renderer.attached(to: display)
        StreamPerf.standard?.note(plan.perfText(on: display))
        let link = CADisplayLink(target: self, selector: #selector(refreshTick))
        link.preferredFrameRateRange = plan.frameRateRange
        link.add(to: .main, forMode: .common)
        refreshLink = link
        #if os(tvOS)
        if let window { StreamDisplay.applyCriteria(plan, width: display.currentMode.width, height: display.currentMode.height, to: window) }
        #endif
        // The window's scale is known now
        setNeedsLayout()
        let size = screen.nativeBounds.size
        // The stream is told the refresh rate the display is expected to run (Cap FPS and the host use it)
        let info = DisplayInfo(pixelWidth: Int(size.width), pixelHeight: Int(size.height), maxFramesPerSecond: Int(plan.displayRefreshRate.rounded()))
        // Not inside the view update that added this view
        Task { @MainActor [onDisplay] in onDisplay(info) }
    }

    // MARK: Touches, in pixels of the screen

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .began) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .moved) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .ended) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .cancelled) }

    private func report(_ touches: Set<UITouch>, _ phase: StreamController.TouchPhase) {
        let scale = pixelScale
        let area = touchArea
        var samples: [TouchSample] = []
        for touch in touches {
            let point = touch.location(in: self)
            let pixel = CGPoint(x: point.x * scale, y: point.y * scale)
            if touch.type == .indirectPointer, ignoresPointer() {
                // The mouse's own input clicks; its position is the local pointer's
                if phase == .began || phase == .moved { onPointer(pixel, area) }
                continue
            }
            samples.append(sample(touch, at: pixel, scale: scale))
        }
        guard !samples.isEmpty else { return }
        onTouches(phase, samples, area, touches.map(\.timestamp).max() ?? 0)
    }

    /// A touch as the touch screen takes it: a finger's force where the screen measures it, the pencil's force and angles.
    private func sample(_ touch: UITouch, at pixel: CGPoint, scale: CGFloat) -> TouchSample {
        let id = ObjectIdentifier(touch).hashValue
        let force = touch.maximumPossibleForce > 0 ? Double(min(touch.force / touch.maximumPossibleForce, 1)) : 1
        #if os(iOS)
        if touch.type == .pencil {
            return TouchSample(
                id: id, x: pixel.x, y: pixel.y, tool: .pencil, pressure: force, diameter: touch.majorRadius * 2 * scale,
                azimuth: touch.azimuthAngle(in: self), altitude: touch.altitudeAngle)
        }
        #endif
        return TouchSample(id: id, x: pixel.x, y: pixel.y, pressure: force, diameter: touch.majorRadius * 2 * scale)
    }

    /// The points at the bottom of this view that the system keeps for its home gesture (the home indicator's safe area).
    private var gestureInset: CGFloat {
        guard let window else { return 0 }
        let bottom = convert(bounds, to: window).maxY
        return max(0, bottom - (window.bounds.height - window.safeAreaInsets.bottom))
    }

    #if os(iOS)
    /// A pencil hovers (its last hover had a height above the screen).
    private var penHovering = false

    /// The hover over the video: a pencil above the screen (iPadOS reports its height, `zOffset` above 0), else the system
    /// pointer.
    @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
        let scale = pixelScale
        let area = touchArea
        let point = hover.location(in: self)
        let pixel = CGPoint(x: point.x * scale, y: point.y * scale)
        let time = ProcessInfo.processInfo.systemUptime
        let ended = hover.state == .ended || hover.state == .cancelled || hover.state == .failed
        if hover.zOffset > 0, !ended {
            penHovering = true
            onPenHover(pixel, Double(hover.zOffset), Double(hover.azimuthAngle(in: self)), Double(hover.altitudeAngle), area, time)
        } else if penHovering {
            penHovering = false
            onPenHover(nil, 0, nil, nil, area, time)
        } else if !ended {
            onPointer(pixel, area)
        }
    }
    #endif
}

#if os(iOS)
/// What the on-screen keyboard types goes to the PC (``StreamController/typed(_:)``).
extension VideoHostView: UIKeyInput, UITextInputTraits {
    var hasText: Bool { true }

    func insertText(_ text: String) {
        onText(text)
    }

    func deleteBackward() {
        onBackspace()
    }
}

// MARK: Picture in Picture (iPhone and iPad)

extension VideoHostView {
    /// [wanted]: the stream may be taken into Picture in Picture now (``StreamController/pictureInPictureMayStart``).
    func setPictureInPicture(_ wanted: Bool, onEvent: @escaping @MainActor (PictureInPictureEvent) -> Void) {
        pictureInPicture?.onEvent = onEvent
        pictureInPictureWanted = wanted
        applyPictureInPicture()
    }

    /// Only on this device's own screen: a stream shown on another display stays there (Android turns PiP off on an
    /// external display).
    private func applyPictureInPicture() {
        pictureInPicture?.allowed = pictureInPictureWanted && window?.windowScene?.session.role == .windowApplication
    }
}

// MARK: The pointer lock (iPad)

extension VideoHostView: UIPointerInteractionDelegate {
    /// Gives the pointer back (the stream screen is gone).
    func releasePointer() {
        pointer.release()
    }

    /// Follows the window's scene: the pointer is the stream's only while the scene is in the foreground and active, and
    /// the system says whether it holds the lock it was asked for.
    private func followScene() {
        let center = NotificationCenter.default
        sceneObservers.forEach(center.removeObserver)
        sceneObservers.removeAll()
        guard let scene = window?.windowScene else {
            pointer.setEligible(false)
            return
        }
        let changes: [(Notification.Name, Bool?)] = [
            (UIScene.didActivateNotification, true), (UIScene.willDeactivateNotification, false),
            (UIScene.didEnterBackgroundNotification, false), (UIPointerLockState.didChangeNotification, nil),
        ]
        for (name, active) in changes {
            sceneObservers.append(center.addObserver(forName: name, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sceneChanged(active: active) }
            })
        }
        sceneChanged(active: scene.activationState == .foregroundActive)
    }

    /// [active]: the scene became active (true) or is leaving it (false); nil: only the lock's state changed.
    private func sceneChanged(active: Bool?) {
        if let active { pointer.setEligible(active) }
        pointer.setGranted(window?.windowScene?.pointerLockState?.isLocked == true)
        pointerStyle.invalidate()
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        pointer.hidesPointer ? .hidden() : nil
    }
}
#endif
#elseif canImport(AppKit)
import AppKit

extension VideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> VideoHostView {
        let view = VideoHostView(renderer: renderer)
        update(view)
        return view
    }

    func updateNSView(_ view: VideoHostView, context: Context) {
        update(view)
    }

    static func dismantleNSView(_ view: VideoHostView, coordinator: ()) {
        view.releasePointer()
    }

    @MainActor private func update(_ view: VideoHostView) {
        view.onDisplay = onDisplay
        view.onPointer = onPointer
        view.onScroll = onScroll
        view.onLayout = onLayout
        view.capturesPointer = capturesPointer
    }
}

/// The AppKit host of the video layer on the Mac. It reports the screen the window is on, keeps that screen at the
/// renderer's planned refresh rate, and locks the system pointer to the stream while the stream wants the mouse (``PointerLock``).
final class VideoHostView: NSView {
    private let renderer: any VideoRenderer
    var onDisplay: @MainActor (DisplayInfo) -> Void = { _ in }
    var onPointer: @MainActor (CGPoint, StreamController.TouchArea) -> Void = { _, _ in }
    var onScroll: @MainActor (Double, Double, Bool) -> Void = { _, _, _ in }
    var onLayout: @MainActor (StreamController.TouchArea) -> Void = { _ in }
    /// A stream wants the mouse: it runs and its menu is closed.
    var capturesPointer = false {
        didSet { pointer.setWanted(capturesPointer) }
    }
    private lazy var pointer = PointerLock(backend: AppKitPointerBackend { [weak self] in self?.parkingPoint() })
    private var refreshLink: CADisplayLink?
    private var observers: [NSObjectProtocol] = []

    init(renderer: any VideoRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(renderer.hostLayer)
        // The pointer over the video while the local pointer shows
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        renderer.resize(to: bounds, scale: window?.backingScaleFactor ?? 2)
        let area = touchArea
        Task { @MainActor [onLayout] in onLayout(area) }
    }

    /// The view in pixels, as the stream measures the pointer.
    private var touchArea: StreamController.TouchArea {
        let scale = window?.backingScaleFactor ?? 2
        return StreamController.TouchArea(width: bounds.width * scale, height: bounds.height * scale, scale: scale)
    }

    /// Where the pointer of [event] is, in pixels from the view's top left corner.
    private func pixel(_ event: NSEvent) -> CGPoint {
        let scale = window?.backingScaleFactor ?? 2
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x * scale, y: (isFlipped ? point.y : bounds.height - point.y) * scale)
    }

    override func mouseMoved(with event: NSEvent) { onPointer(pixel(event), touchArea) }
    override func mouseDragged(with event: NSEvent) { onPointer(pixel(event), touchArea) }
    override func rightMouseDragged(with event: NSEvent) { onPointer(pixel(event), touchArea) }
    override func otherMouseDragged(with event: NSEvent) { onPointer(pixel(event), touchArea) }

    /// AppKit's scrolling (GameController's misses steps on the Mac): a trackpad's precise deltas in pixels, a wheel's in
    /// lines; the momentum after a trackpad flick goes along.
    override func scrollWheel(with event: NSEvent) {
        let scale = event.hasPreciseScrollingDeltas ? (window?.backingScaleFactor ?? 2) : 1
        onScroll(event.scrollingDeltaX * scale, event.scrollingDeltaY * scale, event.hasPreciseScrollingDeltas)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// Gives the pointer back (the stream screen is gone).
    func releasePointer() {
        pointer.release()
    }

    /// Where the pointer is parked while locked: the middle of the video, in Core Graphics' display coordinates.
    private func parkingPoint() -> CGPoint? {
        guard let window, let main = NSScreen.screens.first else { return nil }
        let onScreen = window.convertToScreen(convert(bounds, to: nil))
        return PointerLockGeometry.parkingPoint(windowFrame: onScreen, mainScreenHeight: main.frame.height)
    }

    private func updateEligibility() {
        pointer.setEligible(NSApp.isActive && window?.isKeyWindow == true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        refreshLink?.invalidate()
        refreshLink = nil
        guard let window, let screen = window.screen else {
            pointer.setEligible(false)
            renderer.detached()
            StreamDisplay.restoreMode()
            return
        }
        // The pointer is the stream's only while the app is active and this window is the key window: another app, the
        // menu bar and other windows can be clicked otherwise
        let center = NotificationCenter.default
        let names: [(Notification.Name, AnyObject?)] = [
            (NSApplication.didBecomeActiveNotification, nil), (NSApplication.didResignActiveNotification, nil),
            (NSWindow.didBecomeKeyNotification, window), (NSWindow.didResignKeyNotification, window),
        ]
        for (name, object) in names {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateEligibility() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointer.release() }
        })
        updateEligibility()

        // Keeps the screen at the planned refresh rate (``DisplayRefreshPlanner``): a ProMotion display slows down when
        // nothing asks for more; a mode switch the plan asks for is made for this app only
        let display = StreamDisplay.describe(screen)
        let plan = renderer.attached(to: display)
        StreamPerf.standard?.note(plan.perfText(on: display))
        StreamDisplay.applyMode(plan, on: screen)
        let link = displayLink(target: self, selector: #selector(refreshTick))
        link.preferredFrameRateRange = plan.frameRateRange
        link.add(to: .main, forMode: .common)
        refreshLink = link
        needsLayout = true

        let size = screen.convertRectToBacking(screen.frame).size
        let info = DisplayInfo(pixelWidth: Int(size.width), pixelHeight: Int(size.height), maxFramesPerSecond: Int(plan.displayRefreshRate.rounded()))
        // Not inside the view update that added this view
        Task { @MainActor [onDisplay] in onDisplay(info) }
    }

    @objc private func refreshTick(_ link: CADisplayLink) {}
}
#endif
