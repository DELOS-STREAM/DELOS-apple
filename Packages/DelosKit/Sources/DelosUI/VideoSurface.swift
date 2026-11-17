import DelosInput
import DelosMedia
import SwiftUI

/// The video of a stream: hosts the renderer's layer (the display layer or the Metal layer) full size, aspect fit on
/// black. Reports the display it is shown on (once it is in a window) and, on iPhone and iPad, the touches on it in pixels.
struct VideoSurface {
    let renderer: any VideoRenderer
    let onDisplay: @MainActor (DisplayInfo) -> Void
    var onTouch: @MainActor (_ id: Int, _ phase: StreamController.TouchPhase, _ point: CGPoint, _ area: StreamController.TouchArea, _ time: TimeInterval) -> Void = { _, _, _, _, _ in }
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
        view.onTouch = onTouch
        view.ignoresPointer = ignoresPointer
        view.onText = onText
        view.onBackspace = onBackspace
        view.onKeyboardHidden = onKeyboardHidden
        view.setKeyboard(keyboard)
        #if os(iOS)
        view.capturesPointer = capturesPointer
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
    var onTouch: @MainActor (Int, StreamController.TouchPhase, CGPoint, StreamController.TouchArea, TimeInterval) -> Void = { _, _, _, _, _ in }
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
    #endif

    init(renderer: any VideoRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        backgroundColor = .black
        #if os(iOS)
        isMultipleTouchEnabled = true
        addInteraction(pointerStyle)
        #endif
        layer.addSublayer(renderer.hostLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Raises or lowers the on-screen keyboard: this view is the first responder while it is up.
    func setKeyboard(_ shown: Bool) {
        #if os(iOS)
        guard shown != keyboardWanted else { return }
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
        if window != nil, becomeFirstResponder() { return }
        guard retries > 0 else {
            keyboardWanted = false
            Task { @MainActor [onKeyboardHidden] in onKeyboardHidden() }
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.raiseRetryDelay)
            self?.raiseKeyboard(retries: retries - 1)
        }
    }

    override var canBecomeFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
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
    }

    /// Keeps the display at its highest refresh rate while the video is shown. ProMotion screens slow down to save power
    /// when nothing asks for more, and the display layer alone does not ask: a 120 fps stream ran at 60 and stuttered
    /// on the owner's iPad Pro (M5). Moonlight for iOS keeps a display link for the same reason.
    private var refreshLink: CADisplayLink?

    @objc private func refreshTick(_ link: CADisplayLink) {}

    override func didMoveToWindow() {
        super.didMoveToWindow()
        #if os(iOS)
        // The keyboard was asked for before the view had a window
        if window != nil { raiseKeyboard(retries: Self.raiseRetries) }
        followScene()
        #endif
        refreshLink?.invalidate()
        refreshLink = nil
        guard let screen = window?.windowScene?.screen else {
            renderer.detached()
            return
        }
        let fastest = Float(screen.maximumFramesPerSecond)
        let link = CADisplayLink(target: self, selector: #selector(refreshTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fastest, maximum: fastest, preferred: fastest)
        link.add(to: .main, forMode: .common)
        refreshLink = link
        renderer.attached(maxFramesPerSecond: screen.maximumFramesPerSecond)
        // The window's scale is known now
        setNeedsLayout()
        let size = screen.nativeBounds.size
        let info = DisplayInfo(pixelWidth: Int(size.width), pixelHeight: Int(size.height), maxFramesPerSecond: screen.maximumFramesPerSecond)
        // Not inside the view update that added this view
        Task { @MainActor [onDisplay] in onDisplay(info) }
    }

    // MARK: Touches, in pixels of the screen

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .began) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .moved) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .ended) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .cancelled) }

    private func report(_ touches: Set<UITouch>, _ phase: StreamController.TouchPhase) {
        let scale = window?.windowScene?.screen.nativeScale ?? contentScaleFactor
        let area = StreamController.TouchArea(
            width: bounds.width * scale, height: bounds.height * scale, gestureInset: gestureInset * scale, scale: scale)
        for touch in touches {
            if touch.type == .indirectPointer, ignoresPointer() { continue }
            let point = touch.location(in: self)
            onTouch(ObjectIdentifier(touch).hashValue, phase, CGPoint(x: point.x * scale, y: point.y * scale), area, touch.timestamp)
        }
    }

    /// The points at the bottom of this view that the system keeps for its home gesture (the home indicator's safe area).
    private var gestureInset: CGFloat {
        guard let window else { return 0 }
        let bottom = convert(bounds, to: window).maxY
        return max(0, bottom - (window.bounds.height - window.safeAreaInsets.bottom))
    }
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
        view.capturesPointer = capturesPointer
    }
}

/// The AppKit host of the video layer on the Mac. It reports the screen the window is on, keeps that screen at its
/// highest refresh rate, and locks the system pointer to the stream while the stream wants the mouse (``PointerLock``).
final class VideoHostView: NSView {
    private let renderer: any VideoRenderer
    var onDisplay: @MainActor (DisplayInfo) -> Void = { _ in }
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        renderer.resize(to: bounds, scale: window?.backingScaleFactor ?? 2)
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

        // Keeps the screen at its highest refresh rate: a ProMotion display slows down when nothing asks for more
        let fastest = Float(screen.maximumFramesPerSecond)
        let link = displayLink(target: self, selector: #selector(refreshTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fastest, maximum: fastest, preferred: fastest)
        link.add(to: .main, forMode: .common)
        refreshLink = link
        renderer.attached(maxFramesPerSecond: screen.maximumFramesPerSecond)
        needsLayout = true

        let size = screen.convertRectToBacking(screen.frame).size
        let info = DisplayInfo(pixelWidth: Int(size.width), pixelHeight: Int(size.height), maxFramesPerSecond: screen.maximumFramesPerSecond)
        // Not inside the view update that added this view
        Task { @MainActor [onDisplay] in onDisplay(info) }
    }

    @objc private func refreshTick(_ link: CADisplayLink) {}
}
#endif
