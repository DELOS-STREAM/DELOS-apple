import CoreGraphics
#if os(iOS)
import SwiftUI
import UIKit
#endif

/// A finger's press on an item (docs/ARCHITECTURE.md, "Press and hover"): the squeeze shows from the moment the finger
/// touches down and holds while it rests (a long press too, until the context menu opens), and lets go when the finger
/// lifts, the touch is cancelled or a drag takes the touch over (it moved past [slop]: the row's scroll, a cover's swipe).
/// A touch that would only focus the item (``ItemTouch/focusOnly``) has no squeeze. Apart from UIKit so the rules are
/// tested.
struct TouchPress: Equatable {
    /// How far a finger moves before its touch counts as a drag (points).
    static let slop = 10.0
    private(set) var pressed = false
    private var origin: CGPoint?

    /// Whether a tap there squeezes the item: everything but a first tap that only focuses it.
    static func squeezes(_ touch: ItemTouch) -> Bool { touch != .focusOnly }

    /// A finger touched down at [point]; [squeezes]: ``squeezes(_:)`` for the item now.
    mutating func began(at point: CGPoint, squeezes: Bool) {
        origin = point
        pressed = squeezes
    }

    /// The finger moved to [point]: past the slop a drag has taken the touch over.
    mutating func moved(to point: CGPoint) {
        guard pressed, let origin else { return }
        if hypot(point.x - origin.x, point.y - origin.y) > Self.slop { pressed = false }
    }

    /// The finger lifted or the touch was cancelled.
    mutating func ended() {
        pressed = false
        origin = nil
    }
}

#if os(iOS)
/// Watches a finger's touch on an item for ``TouchPress`` without ever recognizing: the item's tap, long press, swipe and
/// the scroll view around keep the touch. [squeezes] is asked as the finger touches down; [onChange] gets the press.
struct TouchPressGesture: UIGestureRecognizerRepresentable {
    let squeezes: @MainActor () -> Bool
    let onChange: @MainActor (Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> TouchPressRecognizer {
        TouchPressRecognizer()
    }

    func updateUIGestureRecognizer(_ recognizer: TouchPressRecognizer, context: Context) {
        recognizer.squeezes = squeezes
        recognizer.onChange = onChange
    }
}

@MainActor
final class TouchPressRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var squeezes: @MainActor () -> Bool = { false }
    var onChange: @MainActor (Bool) -> Void = { _ in }
    private var press = TouchPress()

    init() {
        super.init(target: nil, action: nil)
        delegate = self
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, let touch = touches.first, press.pressed == false else {
            update { $0.ended() }
            return
        }
        let point = touch.location(in: nil)
        update { $0.began(at: point, squeezes: squeezes()) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: nil)
        update { $0.moved(to: point) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        update { $0.ended() }
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        update { $0.ended() }
        state = .failed
    }

    override func reset() {
        super.reset()
        update { $0.ended() }
    }

    private func update(_ change: (inout TouchPress) -> Void) {
        let before = press.pressed
        change(&press)
        if press.pressed != before { onChange(press.pressed) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.type == .direct
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
#endif
