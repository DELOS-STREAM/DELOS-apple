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

/// The part of the window's height (top inclusive, bottom exclusive, pixels) where the open-the-menu swipe may start.
public struct SwipeZone: Equatable, Sendable {
    public var top: CGFloat
    public var bottom: CGFloat

    public init(top: CGFloat, bottom: CGFloat) {
        self.top = top
        self.bottom = bottom
    }
}

/// The swipe up that opens the stream menu (`StreamMenuSwipe` of DELOS for Android). It starts in a band above the bottom
/// edge, not at the edge itself: the strip the system keeps there for its own gesture (the home indicator) stays out of it.
public enum StreamMenuSwipe {
    /// The band's share of the window's height, and how far up from the start the swipe has to go.
    public static let band = 0.18
    public static let distance = 0.12
    /// A flat minimum for the strip at the edge, in points: a screen without a home indicator reports no inset.
    public static let minDeadEdge = 24.0

    /// The band in a window [height] pixels high whose bottom [gestureInset] pixels are the system's, with the strip at least
    /// [minDeadEdge] pixels.
    public static func zone(height: CGFloat, gestureInset: CGFloat, minDeadEdge: CGFloat) -> SwipeZone {
        let bottom = max(height - max(gestureInset, minDeadEdge), 0)
        return SwipeZone(top: min(height * (1 - band), bottom), bottom: bottom)
    }

    public static func starts(_ zone: SwipeZone, y: CGFloat) -> Bool { y >= zone.top && y < zone.bottom }

    /// Up by ``distance`` of the height from the start, and more up than sideways.
    public static func opens(start: CGPoint, now: CGPoint, height: CGFloat) -> Bool {
        let up = start.y - now.y
        return up >= height * distance && up > abs(now.x - start.x)
    }
}

/// The touches of the swipe that opens the stream menu (``StreamMenuSwipe``): a touch starting in the band belongs to the
/// swipe for as long as it lasts and never reaches the PC; the menu opens once, when it has gone far enough up.
public struct MenuSwipe: Sendable {
    private var tracking: [Int: CGPoint] = [:]
    private var fired: Set<Int> = []

    public init() {}

    /// Whether the touch starting at [point] belongs to the swipe.
    public mutating func began(_ id: Int, at point: CGPoint, zone: SwipeZone) -> Bool {
        guard StreamMenuSwipe.starts(zone, y: point.y) else { return false }
        tracking[id] = point
        return true
    }

    /// Whether the touch belongs to the swipe; `open` once, when it went far enough up.
    public mutating func moved(_ id: Int, to point: CGPoint, height: CGFloat) -> (owned: Bool, open: Bool) {
        guard let start = tracking[id] else { return (false, false) }
        if !fired.contains(id), StreamMenuSwipe.opens(start: start, now: point, height: height) {
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
