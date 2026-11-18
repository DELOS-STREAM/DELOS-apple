import DelosCore
import Foundation

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
