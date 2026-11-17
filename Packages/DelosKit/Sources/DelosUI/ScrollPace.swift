import SwiftUI

/// How fast the focus is moving, for the scroll that follows it. A held arrow moves the focus every 50 ms
/// (``MenuInput``): 200 to 520 ms animations started that often overlap and lag behind the focus, so a fast move
/// scrolls in one short linear step and a single press glides.
struct ScrollPace {
    enum Pace: Equatable {
        /// A single move: the screen's own animation.
        case single
        /// Moves in quick succession (a held key): one short step.
        case held
    }

    /// A move that follows the last one by less than this is part of a hold. The repeat comes every 50 ms and the
    /// first one 500 ms after the press, so a tap that is quicker than this is a fast tapper, and glides in steps too.
    static let heldWithin: TimeInterval = 0.12
    /// The step of a held move.
    static let heldStep: Animation = .linear(duration: 0.05)

    private var last = Date.distantPast

    /// Notes a move at [now] and says how fast the focus moves.
    mutating func move(at now: Date = .now) -> Pace {
        defer { last = now }
        return now.timeIntervalSince(last) < Self.heldWithin ? .held : .single
    }

    /// The animation of a move: [single] for a single press, the short step while held.
    mutating func animation(_ single: Animation, at now: Date = .now) -> Animation {
        move(at: now) == .held ? Self.heldStep : single
    }
}
