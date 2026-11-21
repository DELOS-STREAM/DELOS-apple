#if os(iOS)
import DelosHost
import SwiftUI
import UIKit

/// Recognizes only a focused cover's upward drag. Horizontal intent fails before this recognizer begins, so the
/// enclosing scroll view retains its finger pan instead of competing with an already-recognized SwiftUI drag. Whether
/// the cover may swipe (it has the focus) is asked as the drag's axis is decided, so a cover focused a moment ago by a
/// tap, a controller or the pointer swipes at once.
struct CoverSwipeGesture: UIGestureRecognizerRepresentable {
    let app: HostApp
    let launcher: OverviewLauncher?
    let enabled: Bool
    let minimumDistance: CGFloat
    let threshold: CGFloat
    /// The most the cover rises on its rubber band (points).
    let cap: CGFloat

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
            launcher.drag(app, translation: recognizer.translation, slop: minimumDistance, cap: cap, threshold: threshold)
        case .ended:
            launcher.end(app, translation: recognizer.translation, velocityY: recognizer.velocityY, threshold: threshold)
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
    /// The finger's vertical speed as it lifted (points per second, negative: up).
    private(set) var velocityY = 0.0
    private var origin: CGPoint?
    private var tracker = SwipeVelocity()

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
        let point = touch.location(in: nil)
        origin = point
        tracker = SwipeVelocity()
        tracker.add(y: point.y, at: touch.timestamp)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let origin, let touch = touches.first else { return }
        let point = touch.location(in: nil)
        translation = CGSize(width: point.x - origin.x, height: point.y - origin.y)
        tracker.add(y: point.y, at: touch.timestamp)
        if state == .possible {
            switch CoverDragDirection.of(translation: translation, minimumDistance: minimumDistance) {
            case .undecided:
                break
            case .horizontalScroll:
                state = .failed
            case .verticalSwipe:
                state = translation.height < 0 && launcher?.canSwipe(app) == true ? .began : .failed
            }
        } else if hasBegun {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let origin, let touch = touches.first {
            let point = touch.location(in: nil)
            translation = CGSize(width: point.x - origin.x, height: point.y - origin.y)
            tracker.add(y: point.y, at: touch.timestamp)
            velocityY = tracker.velocity(at: touch.timestamp)
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
        velocityY = 0
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

/// A finger's vertical speed from its last moves: the travel over the last [window] seconds before it lifted; a finger
/// that rested longer than that before lifting has none.
struct SwipeVelocity {
    static let window = 0.1
    private var samples: [(y: Double, time: Double)] = []

    mutating func add(y: Double, at time: Double) {
        samples.append((y, time))
        // Only the recent moves count
        samples.removeAll { time - $0.time > Self.window * 2 }
    }

    /// Points per second (negative: up) at [time].
    func velocity(at time: Double) -> Double {
        let recent = samples.filter { time - $0.time <= Self.window }
        guard let first = recent.first, let last = recent.last, last.time - first.time > 0.004 else { return 0 }
        return (last.y - first.y) / (last.time - first.time)
    }
}
