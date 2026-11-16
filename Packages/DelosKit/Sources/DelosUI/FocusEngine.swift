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
        guard focused == id else { return }
        // A screen that leaves unregisters all its items one after the other: its focus must stay on the item it had, for
        // the way back. So the focus moves on only if other items are still there once the layout has settled.
        Task { [weak self] in
            guard let self, focused == id, frames[id] == nil, let next = frames.keys.first else { return }
            focused = next
        }
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

extension EnvironmentValues {
    /// The focus of the layer or the side menu that is open (tvOS): the items of every other focus cannot take the
    /// system focus meanwhile. Nil: nothing is open.
    @Entry var modalFocus: FocusModel?
}

extension EnvironmentValues {
    /// The focus scope of the root (tvOS): items name their model's focused item as the preferred one in it.
    @Entry var focusNamespace: Namespace.ID?
}

/// Marks the item as the preferred default focus of the root's scope, when there is one.
private struct PreferredFocus: ViewModifier {
    let preferred: Bool
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        #if os(tvOS)
        if let namespace { content.prefersDefaultFocus(preferred, in: namespace) } else { content }
        #else
        content
        #endif
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
    @Environment(\.modalFocus) private var modalFocus
    @Environment(\.focusNamespace) private var scope

    /// A layer or the side menu is open and it is not this item's: the item cannot take the system focus.
    private var blocked: Bool { modalFocus != nil && modalFocus !== model }

    /// Asks the focus engine for the focus on this item, and again a moment later: it ignores a request made while the
    /// item has just appeared or the item that had the focus is going away (a layer opened), and then keeps the old
    /// focus until the next press.
    private func requestFocus() {
        guard model.focused == AnyHashable(id) else { return }
        systemFocused = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if model.focused == AnyHashable(id), !blocked { systemFocused = true }
        }
    }

    public var body: some View {
        // The element a layer belongs to keeps its focus look while the layer has the system focus
        let item = content(systemFocused || (blocked && model.focused == AnyHashable(id)))
            // The frames and actions are registered as on the other platforms: a context menu is placed beside its
            // item, and the root's commands (Play/Pause, a controller's X) open the focused item's menu
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                model.register(AnyHashable(id), frame: frame, moves: moves, menu: menu, action: action)
            }
            .onDisappear { model.unregister(AnyHashable(id)) }
            .focusable(!blocked)
            .focusEffectDisabled()
            .focused($systemFocused)
            .modifier(PreferredFocus(preferred: model.focused == AnyHashable(id) && !blocked, namespace: scope))
            .onChange(of: systemFocused) { _, now in if now { model.focus(AnyHashable(id)) } }
            // The model moves the focus too (to the next step of a form, or the first item of a screen)
            .onChange(of: model.focused) { _, now in if now == AnyHashable(id) { systemFocused = true } }
            // When the layer closes, the item that had the focus gets it back
            .onChange(of: blocked) { _, now in if !now { requestFocus() } }
            .onAppear { requestFocus() }
            // The Siri Remote's select is A, not a touch
            .onTapGesture(perform: action)
        if menu != nil {
            // A long press on the Siri Remote's touch surface opens the context menu, as Play/Pause does at the root
            item.onLongPressGesture(minimumDuration: 0.6) {
                model.focus(AnyHashable(id))
                layers?.openContextMenu(of: model)
            }
        } else {
            item
        }
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


extension View {
    /// tvOS: the view spans the full width and is a focus section, so Up or Down from an item beside it reaches the items
    /// inside: the focus engine only moves to a view that overlaps the focused one along the other axis, and the top
    /// navigation, the profile chip and the tabs are narrower than the items below them. No effect elsewhere.
    @ViewBuilder func tvFocusSection() -> some View {
        #if os(tvOS)
        frame(maxWidth: .infinity).focusSection()
        #else
        self
        #endif
    }
}
