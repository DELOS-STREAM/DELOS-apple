import DelosInput
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension View {
    /// Tells ``ControllerGlyphs`` which kind of input the player uses, as it happens: a finger on the screen (touch), a
    /// mouse or trackpad (pointer). Keys and controllers are noted by ``MenuInput``. Put once at the root of the shell.
    func tracksInputKind() -> some View {
        #if os(iOS)
        background(InputKindProbe())
        #elseif os(macOS)
        background(InputKindMonitor())
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Watches every touch of the window without taking part: a recognizer that only looks at the touches that begin (a
/// direct one is a finger or the Pencil, an indirect pointer one a mouse or trackpad) and then fails, at once, and a hover
/// recognizer for the pointer moving over the window.
private struct InputKindProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView { ProbeView() }
    func updateUIView(_ view: ProbeView, context: Context) {}
}

private final class ProbeView: UIView, UIGestureRecognizerDelegate {
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
        recognizers = [TouchKindRecognizer(), hover]
        recognizers.forEach(window.addGestureRecognizer)
    }

    /// The pointer moved over the window (not merely there when a view appeared under it); the Pencil hovering above the
    /// screen (a height above it) is not the pointer.
    @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
        guard hover.state == .changed, hover.zOffset == 0 else { return }
        ControllerGlyphs.shared.note(.pointer)
    }

    // The pointer's hover reaches every other recognizer as well (the buttons' own pointer effects)
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
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
/// Notes the pointer when the mouse moves, clicks or scrolls in the app.
private struct InputKindMonitor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private final class MonitorView: NSView {
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        monitor.map(NSEvent.removeMonitor)
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { ControllerGlyphs.shared.note(.pointer) }
            return event
        }
    }
}
#endif
