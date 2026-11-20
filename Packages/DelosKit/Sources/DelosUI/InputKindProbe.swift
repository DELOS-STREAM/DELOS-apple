import DelosInput
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension View {
    /// Tells ``ControllerGlyphs`` which kind of input the player uses, as it happens: a finger on the screen (touch), a
    /// mouse or trackpad (pointer). Keys and controllers are noted by ``MenuInput``. It is also where the pointer reaches
    /// [router] beyond what the items do themselves (docs/ARCHITECTURE.md, "Pointer"): a right click or a two-finger
    /// click (``ShellRouter/secondaryClick(at:)``). The system pointer is left as it is everywhere: it never hides over the
    /// items. Put once at the root of the shell.
    func tracksInputKind(router: ShellRouter) -> some View {
        #if os(iOS)
        background(InputKindProbe(router: router))
        #elseif os(macOS)
        background(InputKindMonitor(router: router))
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Watches every touch of the window without taking part: a recognizer that only looks at the touches that begin (a
/// direct one is a finger or the Pencil, an indirect pointer one a mouse or trackpad) and then fails, at once, and a hover
/// recognizer for the pointer moving over the window. A tap recognizer of the secondary button takes the right click and
/// the trackpad's two-finger click.
private struct InputKindProbe: UIViewRepresentable {
    let router: ShellRouter

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.router = router
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) { view.router = router }
}

private final class ProbeView: UIView, UIGestureRecognizerDelegate {
    weak var router: ShellRouter?
    private var recognizers: [UIGestureRecognizer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        recognizers.forEach { $0.view?.removeGestureRecognizer($0) }
        recognizers = []
        guard let window else { return }
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered))
        hover.cancelsTouchesInView = false
        hover.delegate = self
        let secondary = UITapGestureRecognizer(target: self, action: #selector(secondaryClicked))
        secondary.buttonMaskRequired = .secondary
        secondary.cancelsTouchesInView = false
        secondary.delegate = self
        recognizers = [TouchKindRecognizer(), hover, secondary]
        recognizers.forEach(window.addGestureRecognizer)
    }

    /// The pointer moved over the window (not merely there when a view appeared under it); the Pencil hovering above the
    /// screen (a height above it) is not the pointer.
    @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
        guard hover.state == .changed, hover.zOffset == 0 else { return }
        ControllerGlyphs.shared.note(.pointer)
    }

    /// A right click or a two-finger click: the context menu of the item under the pointer. Never a finger's tap
    /// (``gestureRecognizer(_:shouldReceive:)``).
    @objc private func secondaryClicked(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, let router, let window else { return }
        ControllerGlyphs.shared.note(.pointer)
        let point = tap.location(in: window)
        Task { await router.secondaryClick(at: point) }
    }

    // The pointer's hover reaches every other recognizer as well (the buttons' own pointer effects)
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // The tap of the secondary button takes only the pointer's touches (``ItemTouch/takesSecondaryClick(indirect:)``): UIKit
    // checks its button mask on indirect input only, so every finger's tap would be a secondary click
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard g is UITapGestureRecognizer else { return true }
        return ItemTouch.takesSecondaryClick(indirect: touch.type == .indirectPointer)
    }
}

final class TouchKindRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        MainActor.assumeIsolated { began(indirect: touches.contains { $0.type == .indirectPointer }) }
        state = .failed
    }

    /// A touch began: a finger or the Pencil (touch), or the system pointer's click (pointer).
    @MainActor func began(indirect: Bool) {
        ControllerGlyphs.shared.note(indirect ? .pointer : .touch)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    #if DEBUG
    /// The demo harness's `touch` and `click` commands: a touch begins on every window that holds a probe, through the
    /// probe's recognizer (nothing changes where it is not installed). Returns how many windows had one.
    @MainActor @discardableResult static func debugBegin(indirect: Bool) -> Int {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        let probes = windows.flatMap { $0.gestureRecognizers ?? [] }.compactMap { $0 as? TouchKindRecognizer }
        probes.forEach { $0.began(indirect: indirect) }
        return probes.count
    }
    #endif
}
#elseif os(macOS)
/// Notes the pointer when the mouse moves, clicks or scrolls in the app, and takes a right click (or a Control-click)
/// over an item for its context menu.
private struct InputKindMonitor: NSViewRepresentable {
    let router: ShellRouter

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.router = router
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) { view.router = router }
}

private final class MonitorView: NSView {
    weak var router: ShellRouter?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        monitor.map(NSEvent.removeMonitor)
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            let secondary = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            let (location, windowNumber) = (event.locationInWindow, event.windowNumber)
            let taken = MainActor.assumeIsolated {
                ControllerGlyphs.shared.note(.pointer)
                return secondary && self?.secondaryClick(at: location, windowNumber: windowNumber) == true
            }
            return taken ? nil : event
        }
    }

    /// A right click or a Control-click at [location] in the window numbered [windowNumber], over an item (or beside an open
    /// layer's) of this window: the router's, and the event goes no further (a Control-click would also activate the item).
    /// Over the stream it is the PC's mouse.
    private func secondaryClick(at location: CGPoint, windowNumber: Int) -> Bool {
        guard let router, let window, window.windowNumber == windowNumber, let content = window.contentView else { return false }
        let local = content.convert(location, from: nil)
        // SwiftUI's global space has its origin at the top left of the window's content
        let point = CGPoint(x: local.x, y: content.isFlipped ? local.y : content.bounds.height - local.y)
        guard let focus = router.pointerFocus, focus.item(at: point) != nil || router.layers.isOpen else { return false }
        Task { await router.secondaryClick(at: point) }
        return true
    }
}
#endif
