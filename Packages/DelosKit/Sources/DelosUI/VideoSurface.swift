import DelosMedia
import SwiftUI

/// The video of a stream: hosts the renderer's layer (the display layer or the Metal layer) full size, aspect fit on
/// black. Reports the display it is shown on (once it is in a window) and, on iPhone and iPad, the touches on it in pixels.
struct VideoSurface {
    let renderer: any VideoRenderer
    let onDisplay: @MainActor (DisplayInfo) -> Void
    var onTouch: @MainActor (_ id: Int, _ phase: StreamController.TouchPhase, _ point: CGPoint, _ width: CGFloat, _ time: TimeInterval) -> Void = { _, _, _, _, _ in }
    /// Whether a touch of the system pointer (a mouse or trackpad) is ignored: the mouse's own input already moves the
    /// PC's pointer.
    var ignoresPointer: @MainActor () -> Bool = { false }
    /// Whether the stream wants the system pointer locked to it (the Mac): hidden and detached from the mouse, whose
    /// motion the PC gets as relative movement.
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

    @MainActor private func update(_ view: VideoHostView) {
        view.onDisplay = onDisplay
        view.onTouch = onTouch
        view.ignoresPointer = ignoresPointer
        view.onText = onText
        view.onBackspace = onBackspace
        view.onKeyboardHidden = onKeyboardHidden
        view.setKeyboard(keyboard)
    }
}

/// The thin UIKit host of the video layer (the one UIKit view of the app, docs/ENGINEERING_RULES.md).
final class VideoHostView: UIView {
    private let renderer: any VideoRenderer
    var onDisplay: @MainActor (DisplayInfo) -> Void = { _ in }
    var onTouch: @MainActor (Int, StreamController.TouchPhase, CGPoint, CGFloat, TimeInterval) -> Void = { _, _, _, _, _ in }
    var ignoresPointer: @MainActor () -> Bool = { false }
    var onText: @MainActor (String) -> Void = { _ in }
    var onBackspace: @MainActor () -> Void = {}
    var onKeyboardHidden: @MainActor () -> Void = {}
    /// The keyboard was asked for (not taken away by the system).
    private var keyboardWanted = false

    init(renderer: any VideoRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        backgroundColor = .black
        #if os(iOS)
        isMultipleTouchEnabled = true
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
        if shown { _ = becomeFirstResponder() } else { _ = resignFirstResponder() }
        #endif
    }

    #if os(iOS)
    override var canBecomeFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        // The system's own hide button: the menu's Keyboard tile turns off
        if resigned, keyboardWanted {
            keyboardWanted = false
            Task { @MainActor [onKeyboardHidden] in onKeyboardHidden() }
        }
        return resigned
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
        for touch in touches {
            if touch.type == .indirectPointer, ignoresPointer() { continue }
            let point = touch.location(in: self)
            onTouch(
                ObjectIdentifier(touch).hashValue, phase, CGPoint(x: point.x * scale, y: point.y * scale),
                bounds.width * scale, touch.timestamp)
        }
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
#endif
#elseif canImport(AppKit)
import AppKit
import DelosInput

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
