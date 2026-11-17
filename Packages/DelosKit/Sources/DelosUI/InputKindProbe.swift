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
/// direct one is a finger or the Pencil, an indirect pointer one a mouse or trackpad) and then fails, at once.
private struct InputKindProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView { ProbeView() }
    func updateUIView(_ view: ProbeView, context: Context) {}
}

private final class ProbeView: UIView {
    private var recognizer: TouchKindRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        recognizer.map { $0.view?.removeGestureRecognizer($0) }
        recognizer = nil
        guard let window else { return }
        let next = TouchKindRecognizer()
        window.addGestureRecognizer(next)
        recognizer = next
    }
}

private final class TouchKindRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let indirect = touches.contains { $0.type == .indirectPointer }
        MainActor.assumeIsolated { ControllerGlyphs.shared.note(indirect ? .pointer : .touch) }
        state = .failed
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
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
