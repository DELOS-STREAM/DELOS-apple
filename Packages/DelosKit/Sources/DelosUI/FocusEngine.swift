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
    @ObservationIgnored private var cues: [AnyHashable: Cue?] = [:]

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
        cue: Cue? = .select, action: @escaping @MainActor () -> Void
    ) {
        frames[id] = frame
        actions[id] = action
        cues[id] = cue
        self.moves[id] = moves
        menus[id] = menu
        if focused == nil { focused = id }
    }

    func unregister(_ id: AnyHashable) {
        frames[id] = nil
        actions[id] = nil
        moves[id] = nil
        menus[id] = nil
        cues[id] = nil
        guard focused == id else { return }
        // A screen that leaves unregisters all its items one after the other: its focus must stay on the item it had, for
        // the way back. So the focus moves on only if other items are still there once the layout has settled.
        Task { [weak self] in
            guard let self, focused == id, frames[id] == nil, let next = frames.keys.first else { return }
            focused = next
        }
    }

    /// The cue of A on the focused item (``FocusItem/init(id:model:moves:clickCue:action:tap:content:)``): SELECT unless
    /// the item names another or none. Whoever routes A plays it with ``Feedback/activate(_:_:)``.
    var acceptCue: Cue? {
        guard let focused, let cue = cues[focused] else { return .select }
        return cue
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
    /// True for a moment after the item was activated (``Motion/pressHold``): it squeezes to ``Motion/pressScale``.
    @Entry var pressed = false
}

/// What a scroll view that follows the focus gives its items: ``FocusItem`` asks for itself to be brought into view when
/// it gains the focus (a controller or the Siri Remote moves the focus; a custom focus does not scroll on its own).
@MainActor
final class FocusReveal {
    var scrollTo: ((AnyHashable, Bool) -> Void)?
    private var pending: AnyHashable?

    func reveal(_ id: AnyHashable, animated: Bool) {
        if let scrollTo { scrollTo(id, animated) } else { pending = id }
    }

    func attach(_ scroll: @escaping (AnyHashable, Bool) -> Void) {
        scrollTo = scroll
        guard let id = pending else { return }
        pending = nil
        scroll(id, false)
    }
}

extension EnvironmentValues {
    @Entry var focusReveal: FocusReveal?
}

/// A scroll view whose focused item stays in view: the item is centered, so the next one always peeks in at the edge
/// (Android's focus margin). Not animated for reduced motion.
struct FocusScroll<Content: View>: View {
    var axis: Axis.Set = .horizontal
    /// The cut edges' fades in stage pixels (top, bottom) of a vertical scroll view that continues beyond them.
    var fades: (top: Double, bottom: Double)?
    @ViewBuilder let content: () -> Content
    @State private var reveal = FocusReveal()
    @Environment(\.reducedMotion) private var reducedMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(axis, showsIndicators: false) { content() }
                .modifier(OptionalFades(fades: fades))
                .environment(\.focusReveal, reveal)
                .onAppear {
                    reveal.attach { id, animated in
                        if animated && !reducedMotion {
                            withAnimation(Motion.out(Motion.rowFocus)) { proxy.scrollTo(id, anchor: .center) }
                        } else {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
        }
    }
}

private struct OptionalFades: ViewModifier {
    let fades: (top: Double, bottom: Double)?

    func body(content: Content) -> some View {
        if let fades { content.scrollEdgeFades(top: fades.top, bottom: fades.bottom) } else { content }
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
    let clickCue: Cue?
    let content: (Bool) -> Content
    @Environment(Layers.self) private var layers: Layers?
    @Environment(\.focusReveal) private var reveal
    @State private var pressed = false
    @State private var release: Task<Void, Never>?

    /// - Parameters:
    ///   - moves: where a direction leads from this item instead of the nearest item that way (iPhone, iPad and Mac;
    ///     on tvOS the system focus engine decides).
    ///   - tap: what a tap does after focusing the item, when it is not [action] (A): a settings row's choice opens its
    ///     list on a tap, A steps it.
    ///   - clickCue: the cue of an activation (A or a tap), the same for both: SELECT, another for an item that goes
    ///     back or opens something, nil for one that is silent (or whose action plays its own: a cue played by the action
    ///     replaces this one, see ``Feedback/activate(_:_:)``).
    public init(
        id: ID, model: FocusModel, moves: [FocusDirection: AnyHashable] = [:], clickCue: Cue? = .select,
        action: @escaping @MainActor () -> Void, tap: (@MainActor () -> Void)? = nil, @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.init(id: id, model: model, moves: moves, menu: nil, clickCue: clickCue, action: action, tap: tap, content: content)
    }

    /// - Parameter menu: the item's context menu (the right menu button, X, or a long press on touch), built when it
    ///   opens so it shows what is true then.
    init(
        id: ID, model: FocusModel, moves: [FocusDirection: AnyHashable] = [:], menu: (@MainActor () -> ContextMenu?)?,
        clickCue: Cue? = .select, action: @escaping @MainActor () -> Void, tap: (@MainActor () -> Void)? = nil, @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.id = id
        self.model = model
        self.moves = moves
        self.menu = menu
        self.action = action
        self.tap = tap
        self.clickCue = clickCue
        self.content = content
    }

    /// The squeeze of an activation: held ``Motion/pressHold`` ms, a new activation restarts it.
    private func pulse() {
        release?.cancel()
        pressed = true
        release = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(Motion.pressHold)))
            guard !Task.isCancelled else { return }
            pressed = false
        }
    }

    /// What A does (the model's accept): the squeeze and the action; the cue is the router's (``FocusModel/acceptCue``).
    private var pressAction: @MainActor () -> Void {
        { pulse(); action() }
    }

    /// A tap or a click: the squeeze, the action, the same cue as A.
    private func activate(_ run: @MainActor () -> Void) {
        pulse()
        if let feedback = layers?.feedback {
            feedback.activate(clickCue) { run(); return true }
        } else {
            run()
        }
    }

    /// The item gained the focus: its scroll view brings it into view.
    private func revealed(_ now: AnyHashable?, animated: Bool = true) {
        if now == AnyHashable(id) { reveal?.reveal(AnyHashable(id), animated: animated) }
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
                model.register(AnyHashable(id), frame: frame, moves: moves, menu: menu, cue: clickCue, action: pressAction)
            }
            .onDisappear { model.unregister(AnyHashable(id)) }
            .focusable(!blocked)
            .focusEffectDisabled()
            .focused($systemFocused)
            .modifier(PreferredFocus(preferred: model.focused == AnyHashable(id) && !blocked, namespace: scope))
            .onChange(of: systemFocused) { _, now in
                guard now else { return }
                // The focus engine moved the focus (the model did not ask for it): the move cue
                if model.focused != AnyHashable(id) { layers?.feedback?.play(.move) }
                model.focus(AnyHashable(id))
            }
            // The model moves the focus too (to the next step of a form, or the first item of a screen)
            .onChange(of: model.focused) { _, now in
                if now == AnyHashable(id) { systemFocused = true }
                revealed(now)
            }
            // When the layer closes, the item that had the focus gets it back
            .onChange(of: blocked) { _, now in if !now { requestFocus() } }
            .onAppear {
                requestFocus()
                revealed(model.focused, animated: false)
            }
            // The Siri Remote's select is A, not a touch
            .onTapGesture { activate(action) }
            .environment(\.pressed, pressed)
            .id(id)
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
                model.register(AnyHashable(id), frame: frame, moves: moves, menu: menu, cue: clickCue, action: pressAction)
            }
            .onDisappear { model.unregister(AnyHashable(id)) }
            .contentShape(Rectangle())
            .onChange(of: model.focused) { _, now in revealed(now) }
            .onAppear { revealed(model.focused, animated: false) }
            .onTapGesture {
                model.focus(AnyHashable(id))
                activate(tap ?? action)
            }
            .environment(\.pressed, pressed)
            .id(id)
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
