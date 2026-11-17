#if os(macOS)
import CoreGraphics
import DelosInput
import Foundation
@testable import DelosUI

/// The D-pad graph of a screen: the items its real views registered with their real frames, walked with the same
/// ``FocusModel`` the app moves the focus with (``FocusGeometry`` and the items' own `moves`).
@MainActor
struct FocusGraph {
    let model: FocusModel
    let frames: [AnyHashable: CGRect]
    static let directions: [FocusDirection] = [.up, .down, .left, .right]

    init(model: FocusModel, frames: [AnyHashable: CGRect]) {
        self.model = model
        self.frames = frames
    }

    var ids: [AnyHashable] { frames.keys.sorted { "\($0)" < "\($1)" } }

    /// Where [direction] leads from [id]; nil when the focus would stay.
    func move(from id: AnyHashable, _ direction: FocusDirection) -> AnyHashable? {
        model.focus(id)
        guard model.handle(direction.command) else { return nil }
        return model.focused
    }

    /// Every item the D-pad reaches from [start], [start] included.
    func reachable(from start: AnyHashable) -> Set<AnyHashable> {
        var seen: Set<AnyHashable> = [start]
        var queue = [start]
        while let id = queue.popLast() {
            for direction in Self.directions {
                if let next = move(from: id, direction), seen.insert(next).inserted { queue.append(next) }
            }
        }
        return seen
    }

    /// The edges, one line per item (for reading a screen's graph).
    var dump: String {
        ids.map { id in
            let f = frames[id]!
            let edges = Self.directions.map { d in "\(d)->\(move(from: id, d).map { "\($0)" } ?? "-")" }.joined(separator: " ")
            return "  \(id) [\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))] \(edges)"
        }.joined(separator: "\n")
    }

    /// The problems of the graph, each a sentence naming the items: an empty list is a screen the D-pad can use.
    /// - Parameters:
    ///   - initial: the item the screen opens with.
    ///   - bounds: the window; every item must be wholly inside it unless it is in [scrolled] (a list that scrolls).
    ///   - scrolled: the items that may lie outside the window (rows of a scrolling list).
    ///   - allowOverlap: pairs of items that are meant to overlap (a pill drawn over a cover).
    func problems(initial: AnyHashable?, bounds: CGRect, scrolled: (AnyHashable) -> Bool = { _ in false },
                  allowOverlap: (AnyHashable, AnyHashable) -> Bool = { _, _ in false }) -> [String] {
        var found: [String] = []
        guard !frames.isEmpty else { return ["no item registered"] }
        guard let initial, frames[initial] != nil else {
            return ["the initial focus \(String(describing: initial)) is not an item of the screen (\(ids))"]
        }
        let reach = reachable(from: initial)
        let missing = Set(frames.keys).subtracting(reach)
        if !missing.isEmpty { found.append("not reachable from \(initial) by the D-pad: \(missing.map { "\($0)" }.sorted())") }
        // Nothing may lead into a place that cannot be left
        for id in reach {
            let back = reachable(from: id)
            if !back.contains(initial) { found.append("\(id) is a dead end: no way back to \(initial)") }
        }
        if frames.count > 1 {
            for id in ids where Self.directions.allSatisfy({ move(from: id, $0) == nil }) { found.append("\(id) cannot move at all") }
        }
        for (id, frame) in frames {
            if frame.width < 1 || frame.height < 1 { found.append("\(id) has no size: \(frame)") }
            if !scrolled(id), !bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame) { found.append("\(id) lies outside the window \(bounds): \(frame)") }
        }
        let list = ids
        for (i, a) in list.enumerated() {
            for b in list[(i + 1)...] where !allowOverlap(a, b) {
                let cut = frames[a]!.intersection(frames[b]!)
                guard !cut.isNull, cut.width > 1, cut.height > 1 else { continue }
                let smaller = min(frames[a]!.width * frames[a]!.height, frames[b]!.width * frames[b]!.height)
                if cut.width * cut.height > smaller * 0.2 { found.append("\(a) and \(b) overlap: \(frames[a]!) \(frames[b]!)") }
            }
        }
        return found
    }
}

extension FocusDirection {
    var command: MenuCommand {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }
}
#endif
