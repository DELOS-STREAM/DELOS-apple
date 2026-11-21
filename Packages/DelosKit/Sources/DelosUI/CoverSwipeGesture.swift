#if os(iOS)
import DelosHost
import SwiftUI
import UIKit

/// Recognizes only a focused cover's upward drag. Horizontal intent fails before this recognizer begins, so the
/// enclosing scroll view retains its finger pan instead of competing with an already-recognized SwiftUI drag.
struct CoverSwipeGesture: UIGestureRecognizerRepresentable {
    let app: HostApp
    let launcher: OverviewLauncher?
    let enabled: Bool
    let minimumDistance: CGFloat
    let threshold: CGFloat

    func makeUIGestureRecognizer(context: Context) -> CoverSwipeRecognizer {
        let recognizer = CoverSwipeRecognizer(app: app, launcher: launcher, minimumDistance: minimumDistance)
        recognizer.isEnabled = enabled && launcher != nil
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: CoverSwipeRecognizer, context: Context) {
        recognizer.app = app
        recognizer.launcher = launcher
        recognizer.minimumDistance = minimumDistance
        recognizer.isEnabled = enabled && launcher != nil
    }

    func handleUIGestureRecognizerAction(_ recognizer: CoverSwipeRecognizer, context: Context) {
        guard let launcher else { return }
        switch recognizer.state {
        case .began, .changed:
            launcher.drag(app, translation: recognizer.translation, slop: minimumDistance)
        case .ended:
            launcher.end(app, translation: recognizer.translation, threshold: threshold)
        case .cancelled:
            launcher.cancel(app)
        default:
            break
        }
    }
}

@MainActor
final class CoverSwipeRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var app: HostApp
    weak var launcher: OverviewLauncher?
    var minimumDistance: CGFloat
    private(set) var translation = CGSize.zero
    private var origin: CGPoint?

    init(app: HostApp, launcher: OverviewLauncher?, minimumDistance: CGFloat) {
        self.app = app
        self.launcher = launcher
        self.minimumDistance = minimumDistance
        super.init(target: nil, action: nil)
        delegate = self
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard origin == nil, touches.count == 1, let touch = touches.first else {
            state = hasBegun ? .cancelled : .failed
            return
        }
        // Window coordinates stay stable while the cover itself follows the finger.
        origin = touch.location(in: nil)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let origin, let touch = touches.first else { return }
        let point = touch.location(in: nil)
        translation = CGSize(width: point.x - origin.x, height: point.y - origin.y)
        if state == .possible {
            switch CoverDragDirection.of(translation: translation, minimumDistance: minimumDistance) {
            case .undecided:
                break
            case .horizontalScroll:
                state = .failed
            case .verticalSwipe:
                state = translation.height < 0 && launcher?.canOpen(app) == true ? .began : .failed
            }
        } else if hasBegun {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let origin, let touch = touches.first {
            let point = touch.location(in: nil)
            translation = CGSize(width: point.x - origin.x, height: point.y - origin.y)
        }
        state = hasBegun ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = hasBegun ? .cancelled : .failed
    }

    override func reset() {
        super.reset()
        origin = nil
        translation = .zero
    }

    private var hasBegun: Bool { state == .began || state == .changed }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.type == .direct
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The scroll view must be free to begin while this recognizer is still deciding the drag's axis.
        other is UIPanGestureRecognizer && other.view is UIScrollView
    }
}
#endif
