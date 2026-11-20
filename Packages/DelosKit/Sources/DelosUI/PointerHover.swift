import Foundation

/// The pointer moving over the focusable items (``FocusItem``, docs/ARCHITECTURE.md, "Pointer"): what tells a move of the
/// pointer from content moving under it, and how often the hover may play the move cue.
@MainActor
final class PointerHover {
    static let shared = PointerHover()

    /// Two move cues of the hover at least this far apart: a quick sweep over a row of covers is a few ticks, not a storm.
    static let cueGap: TimeInterval = 0.09

    /// Where the pointer was last seen over an item (global points).
    private var last: CGPoint?
    private var lastCue: Date?

    /// Whether the pointer itself moved to [point] (global points) since it was last seen over an item. A row that glides
    /// under a pointer at rest (the focus scrolled it) reports a new item at the same point, which must not take the focus:
    /// it would scroll again, and the row would run away under the pointer.
    func moved(to point: CGPoint) -> Bool {
        defer { last = point }
        guard let last else { return true }
        return abs(last.x - point.x) >= 0.5 || abs(last.y - point.y) >= 0.5
    }

    /// Whether a move of the focus by the hover at [now] plays the move cue (``cueGap``).
    func cues(at now: Date) -> Bool {
        if let lastCue, now.timeIntervalSince(lastCue) < Self.cueGap { return false }
        lastCue = now
        return true
    }
}
