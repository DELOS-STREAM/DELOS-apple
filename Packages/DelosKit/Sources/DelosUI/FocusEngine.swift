import DelosInput
import Observation
import SwiftUI

/// A direction of focus movement.
public enum FocusDirection: Sendable {
    case up, down, left, right
}

/// Picks the item the focus moves to: the nearest item whose center lies beyond the current one in the direction,
/// measured along the direction plus twice the sideways offset, so an item straight ahead wins over a closer one off
/// to the side. Nil when nothing lies in that direction (the focus stays).
public enum FocusGeometry {
    public static func next<ID: Hashable>(from current: CGRect, direction: FocusDirection, candidates: [ID: CGRect]) -> ID? {
        let origin = CGPoint(x: current.midX, y: current.midY)
        var best: (id: ID, score: CGFloat)?
        for (id, frame) in candidates {
            let dx = frame.midX - origin.x
            let dy = frame.midY - origin.y
            let (ahead, side): (CGFloat, CGFloat) = switch direction {
            case .left: (-dx, dy)
            case .right: (dx, dy)
            case .up: (-dy, dx)
            case .down: (dy, dx)
            }
            guard ahead > 0.5 else { continue }
            let score = ahead + 2 * abs(side)
            if best == nil || score < best!.score { best = (id, score) }
        }
        return best?.id
    }
}

/// The focus of one screen on iPhone, iPad and Mac, where a game controller does not move SwiftUI's focus: the items
/// report their frames, ``MenuInput`` reports commands, and the model moves the focus with ``FocusGeometry``.
/// On tvOS the system focus engine is used instead (``FocusItem``).
@MainActor
@Observable
public final class FocusModel {
    public private(set) var focused: AnyHashable?
    @ObservationIgnored private var frames: [AnyHashable: CGRect] = [:]
    @ObservationIgnored private var actions: [AnyHashable: @MainActor () -> Void] = [:]
    @ObservationIgnored private var moves: [AnyHashable: [FocusDirection: AnyHashable]] = [:]
    @ObservationIgnored private var menus: [AnyHashable: @MainActor () -> ContextMenu?] = [:]

    public init(initial: AnyHashable? = nil) {
        focused = initial
    }

    public func focus(_ id: AnyHashable) {
        focused = id
    }

    /// - Parameters:
    ///   - moves: where a direction leads from this item instead of the nearest item that way (a grid whose rows
    ///     continue in the next row).
    ///   - menu: the item's context menu, built when it opens.
    func register(
        _ id: AnyHashable, frame: CGRect, moves: [FocusDirection: AnyHashable] = [:], menu: (@MainActor () -> ContextMenu?)? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        frames[id] = frame
        actions[id] = action
        self.moves[id] = moves
        menus[id] = menu
        if focused == nil { focused = id }
    }

    func unregister(_ id: AnyHashable) {
        frames[id] = nil
        actions[id] = nil
        moves[id] = nil
        menus[id] = nil
        if focused == id { focused = frames.keys.first }
    }

    /// The focused item's context menu and its frame (global points); nil when it has none.
    func contextMenu() -> (ContextMenu, CGRect)? {
        guard let focused, let frame = frames[focused], let menu = menus[focused]?() else { return nil }
        return (menu, frame)
    }

    /// Handles a command: moves the focus or activates the focused item. Returns false when nothing happened.
    @discardableResult
    public func handle(_ command: MenuCommand) -> Bool {
        let direction: FocusDirection
        switch command {
        case .up: direction = .up
        case .down: direction = .down
        case .left: direction = .left
        case .right: direction = .right
        case .accept:
            guard let focused, let action = actions[focused] else { return false }
            action()
            return true
        case .back, .previousTab, .nextTab, .menu, .options, .toastAction:
            return false
        }
        guard let focused, let current = frames[focused] else {
            self.focused = frames.keys.first
            return self.focused != nil
        }
        if let target = moves[focused]?[direction], frames[target] != nil {
            self.focused = target
            return true
        }
        var others = frames
        others[focused] = nil
        guard let next = FocusGeometry.next(from: current, direction: direction, candidates: others) else { return false }
        self.focused = next
        return true
    }
}

/// Makes a view a focusable item: on tvOS through the system focus engine, elsewhere through a ``FocusModel``.
/// The content gets whether it is focused.
public struct FocusItem<ID: Hashable, Content: View>: View {
    let id: ID
    let model: FocusModel
    let moves: [FocusDirection: AnyHashable]
    let menu: (@MainActor () -> ContextMenu?)?
    let action: @MainActor () -> Void
    let tap: (@MainActor () -> Void)?
    let content: (Bool) -> Content
    @Environment(Layers.self) private var layers: Layers?

    /// - Parameters:
    ///   - moves: where a direction leads from this item instead of the nearest item that way (iPhone, iPad and Mac;
    ///     on tvOS the system focus engine decides).
    ///   - tap: what a tap does after focusing the item, when it is not [action] (A): a settings row's choice opens its
    ///     list on a tap, A steps it.
    public init(
        id: ID, model: FocusModel, moves: [FocusDirection: AnyHashable] = [:], action: @escaping @MainActor () -> Void,
        tap: (@MainActor () -> Void)? = nil, @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.init(id: id, model: model, moves: moves, menu: nil, action: action, tap: tap, content: content)
    }

    /// - Parameter menu: the item's context menu (the right menu button, X, or a long press on touch), built when it
    ///   opens so it shows what is true then.
    init(
        id: ID, model: FocusModel, moves: [FocusDirection: AnyHashable] = [:], menu: (@MainActor () -> ContextMenu?)?,
        action: @escaping @MainActor () -> Void, tap: (@MainActor () -> Void)? = nil, @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.id = id
        self.model = model
        self.moves = moves
        self.menu = menu
        self.action = action
        self.tap = tap
        self.content = content
    }

    #if os(tvOS)
    @FocusState private var systemFocused: Bool
    public var body: some View {
        content(systemFocused)
            .focusable()
            .focused($systemFocused)
            .onChange(of: systemFocused) { _, now in if now { model.focus(AnyHashable(id)) } }
            // The model moves the focus too (to the next step of a form, or the first item of a screen)
            .onChange(of: model.focused) { _, now in if now == AnyHashable(id) { systemFocused = true } }
            .onAppear { if model.focused == AnyHashable(id) { systemFocused = true } }
            // The Siri Remote's select is A, not a touch
            .onTapGesture(perform: action)
    }
    #else
    public var body: some View {
        let item = content(model.focused == AnyHashable(id))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                model.register(AnyHashable(id), frame: frame, moves: moves, menu: menu, action: action)
            }
            .onDisappear { model.unregister(AnyHashable(id)) }
            .contentShape(Rectangle())
            .onTapGesture {
                model.focus(AnyHashable(id))
                (tap ?? action)()
            }
        if menu != nil {
            // A long press is the touch way to the context menu; simultaneous, so a scroll view around still scrolls
            item.simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                model.focus(AnyHashable(id))
                layers?.openContextMenu(of: model)
            })
        } else {
            item
        }
    }
    #endif
}
