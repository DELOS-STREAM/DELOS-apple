import DelosCore
import Foundation

/// What a touch on the stream does to the PC's mouse.
public enum PointerAction: Equatable, Sendable {
    /// Relative motion in pixels of the screen.
    case move(dx: Int16, dy: Int16)
    case click(MouseButton)
    /// Vertical wheel motion in 1/120 of a notch; positive scrolls up.
    case scroll(Int16)
}

/// The touch screen as a trackpad, the default touch mode of DELOS for Android (`TrackpadContext`): one finger moves
/// the pointer by its motion, a short tap clicks the left button, a tap of two fingers the right one, and two fingers
/// moving scroll. Positions are in pixels of the screen.
public struct TouchTrackpad: Sendable {
    /// A touch that moved less than this (pixels) and was shorter than ``tapTime`` is a tap (Android's thresholds).
    public static let tapMovement = 30.0
    public static let tapTime = 0.23
    /// Wheel units per pixel of two-finger motion (Android's `SCROLL_SPEED_FACTOR_Y`).
    public static let scrollFactor = 3.0

    private struct Finger {
        var last: CGPoint
        let start: CGPoint
    }

    private var fingers: [Int: Finger] = [:]
    /// The most fingers down at once in this gesture, its start, and whether it moved too far for a tap.
    private var maxFingers = 0
    private var startTime = 0.0
    private var moved = false
    private var remainder = CGPoint.zero

    public init() {}

    public mutating func began(_ id: Int, at point: CGPoint, time: TimeInterval) {
        if fingers.isEmpty {
            maxFingers = 0
            startTime = time
            moved = false
            remainder = .zero
        }
        fingers[id] = Finger(last: point, start: point)
        maxFingers = max(maxFingers, fingers.count)
    }

    public mutating func moved(_ id: Int, to point: CGPoint) -> [PointerAction] {
        guard var finger = fingers[id] else { return [] }
        let dx = point.x - finger.last.x, dy = point.y - finger.last.y
        finger.last = point
        fingers[id] = finger
        if hypot(point.x - finger.start.x, point.y - finger.start.y) >= Self.tapMovement { moved = true }
        guard moved else { return [] }
        switch fingers.count {
        case 1 where maxFingers == 1:
            remainder.x += dx
            remainder.y += dy
            let x = Int16(clamping: Int(remainder.x.rounded(.towardZero)))
            let y = Int16(clamping: Int(remainder.y.rounded(.towardZero)))
            remainder.x -= CGFloat(x)
            remainder.y -= CGFloat(y)
            return x == 0 && y == 0 ? [] : [.move(dx: x, dy: y)]
        case 2:
            // Each finger reports its own motion; half of each is the motion of the pair
            remainder.y += dy * Self.scrollFactor / 2
            let amount = Int16(clamping: Int(remainder.y.rounded(.towardZero)))
            remainder.y -= CGFloat(amount)
            return amount == 0 ? [] : [.scroll(amount)]
        default:
            return []
        }
    }

    public mutating func ended(_ id: Int, time: TimeInterval) -> [PointerAction] {
        guard fingers.removeValue(forKey: id) != nil, fingers.isEmpty else { return [] }
        guard !moved, time - startTime < Self.tapTime else { return [] }
        switch maxFingers {
        case 1: return [.click(.left)]
        case 2: return [.click(.right)]
        default: return []
        }
    }

    /// The system took the touches (a system gesture): nothing of them reaches the PC.
    public mutating func cancelled(_ id: Int) {
        fingers.removeValue(forKey: id)
        moved = true
    }
}

/// The swipe up from the bottom edge that opens the stream menu (`StreamMenu` of DELOS for Android, on by default): a
/// touch starting in the bottom 6 % of the screen belongs to the swipe and does not reach the PC; once it has gone
/// up 12 % of the height, the menu opens.
public struct MenuSwipe: Sendable {
    public static let edge = 0.06
    public static let distance = 0.12

    private var tracking: [Int: CGFloat] = [:]
    private var fired: Set<Int> = []

    public init() {}

    /// Whether the touch starting at `y` (of `height`) belongs to the swipe.
    public mutating func began(_ id: Int, y: CGFloat, height: CGFloat) -> Bool {
        guard y >= height * (1 - Self.edge) else { return false }
        tracking[id] = y
        return true
    }

    /// Whether the touch belongs to the swipe; `open` once, when it went far enough up.
    public mutating func moved(_ id: Int, y: CGFloat, height: CGFloat) -> (owned: Bool, open: Bool) {
        guard let start = tracking[id] else { return (false, false) }
        if start - y >= height * Self.distance, !fired.contains(id) {
            fired.insert(id)
            return (true, true)
        }
        return (true, false)
    }

    /// Whether the touch belonged to the swipe.
    public mutating func ended(_ id: Int) -> Bool {
        fired.remove(id)
        return tracking.removeValue(forKey: id) != nil
    }
}
