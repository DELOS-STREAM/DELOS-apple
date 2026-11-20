import DelosInput
import Observation
import SwiftUI

/// A direction of focus movement.
public enum FocusDirection: Sendable {
    case up, down, left, right
}

/// Picks the item the focus moves to, as Android's focus finder does (`FocusFinder`, which Compose's focus search follows):
/// a candidate lies beyond the current item in the direction, by its far edge; one in the beam (it overlaps the current item
/// on the other axis, so it is straight ahead) beats any that is not; among those the weight `13 * major² + minor²` decides, the
/// major axis being the gap between the facing edges and the minor one the offset of the centers. Sideways, an item outside the
/// beam counts only when it is nearly straight ahead (at most a quarter as far aside as ahead), else it is another row and the
/// direction leads nowhere: Right at the end of a row never jumps to a button above or a cover below. Nil when nothing qualifies
/// (the focus stays). Ties go to the smaller id, so the answer never depends on the order of a dictionary.
public enum FocusGeometry {
    private static let edge: CGFloat = 0.5

    public static func next<ID: Hashable>(from current: CGRect, direction: FocusDirection, candidates: [ID: CGRect]) -> ID? {
        var best: (id: ID, inBeam: Bool, weight: CGFloat)?
        for (id, frame) in candidates {
            guard let (major, minor, inBeam, ahead, side) = measure(frame, from: current, direction) else { continue }
            // Sideways, an item outside the beam must lie more ahead than aside: it is another row otherwise. Up and down may
            // lead to an item off to the side (the navigation is centered above content that is not)
            if !inBeam, direction == .left || direction == .right, side * 4 > ahead { continue }
            let weight = 13 * major * major + minor * minor
            if let best {
                if best.inBeam != inBeam {
                    if !inBeam { continue }
                } else if weight > best.weight || (weight == best.weight && "\(id)" >= "\(best.id)") {
                    continue
                }
            }
            best = (id, inBeam, weight)
        }
        return best?.id
    }

    /// How [frame] lies from [current] in [direction]: the gap between the facing edges (at least 1), the offset of the centers
    /// on the other axis, whether the two overlap on that axis, and the centers' distance along and across the direction.
    /// Nil when it is not beyond the current item in that direction.
    private static func measure(_ frame: CGRect, from current: CGRect, _ direction: FocusDirection)
        -> (major: CGFloat, minor: CGFloat, inBeam: Bool, ahead: CGFloat, side: CGFloat)?
    {
        let dx = frame.midX - current.midX, dy = frame.midY - current.midY
        switch direction {
        case .right:
            guard frame.maxX > current.maxX + edge, frame.midX > current.midX + edge, frame.minX > current.minX + edge || current.maxX <= frame.minX + edge
            else { return nil }
            return (max(frame.minX - current.maxX, 1), abs(dy), overlap(frame.minY, frame.maxY, current.minY, current.maxY), dx, abs(dy))
        case .left:
            guard frame.minX < current.minX - edge, frame.midX < current.midX - edge, frame.maxX < current.maxX - edge || current.minX >= frame.maxX - edge
            else { return nil }
            return (max(current.minX - frame.maxX, 1), abs(dy), overlap(frame.minY, frame.maxY, current.minY, current.maxY), -dx, abs(dy))
        case .down:
            guard frame.maxY > current.maxY + edge, frame.midY > current.midY + edge, frame.minY > current.minY + edge || current.maxY <= frame.minY + edge
            else { return nil }
            return (max(frame.minY - current.maxY, 1), abs(dx), overlap(frame.minX, frame.maxX, current.minX, current.maxX), dy, abs(dx))
        case .up:
            guard frame.minY < current.minY - edge, frame.midY < current.midY - edge, frame.maxY < current.maxY - edge || current.minY >= frame.maxY - edge
            else { return nil }
            return (max(current.minY - frame.maxY, 1), abs(dx), overlap(frame.minX, frame.maxX, current.minX, current.maxX), -dy, abs(dx))
        }
    }

    private static func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> Bool { a1 > b0 + edge && a0 < b1 - edge }
}

extension FocusGeometry {
    /// The candidate nearest to [rect] (by the distance of the centers), or without a rect the first in reading order: the
    /// top one, the leftmost of those at the same height. Ties go to the smaller id, so the result never depends on the
    /// order a dictionary hands its keys out.
    public static func fallback<ID: Hashable>(near rect: CGRect?, candidates: [ID: CGRect]) -> ID? {
        func key(_ pair: (key: ID, value: CGRect)) -> (Double, Double, String) {
            if let rect {
                let dx = pair.value.midX - rect.midX, dy = pair.value.midY - rect.midY
                return (Double(dx * dx + dy * dy), Double(pair.value.minY), "\(pair.key)")
            }
            return (Double(pair.value.minY.rounded()), Double(pair.value.minX), "\(pair.key)")
        }
        return candidates.min { a, b in
            let (ka, kb) = (key(a), key(b))
            return ka < kb
        }?.key
    }

    /// The candidate under the pointer at [point] (global points): of those whose frame holds it, the smallest (an item laid
    /// over a bigger one is the one seen), ties to the smaller id. Nil over no item.
    public static func item<ID: Hashable>(at point: CGPoint, candidates: [ID: CGRect]) -> ID? {
        candidates.filter { $0.value.contains(point) }.min { a, b in
            let (sa, sb) = (a.value.width * a.value.height, b.value.width * b.value.height)
            return sa != sb ? sa < sb : "\(a.key)" < "\(b.key)"
        }?.key
    }
}

/// The focus of one screen on iPhone, iPad and Mac, where a game controller does not move SwiftUI's focus: the items
/// report their frames, ``MenuInput`` reports commands, and the model moves the focus with ``FocusGeometry``.
/// On tvOS the system focus engine is used instead (``FocusItem``).
@MainActor
@Observable
public final class FocusModel {
    /// The focused item. A view that reads it is redrawn at every move of the focus; an item asks ``isFocused(_:)`` instead.
    public private(set) var focused: AnyHashable?
    @ObservationIgnored private var frames: [AnyHashable: CGRect] = [:]
    @ObservationIgnored private var actions: [AnyHashable: @MainActor () -> Void] = [:]
    @ObservationIgnored private var moves: [AnyHashable: [FocusDirection: AnyHashable]] = [:]
    @ObservationIgnored private var menus: [AnyHashable: @MainActor () -> ContextMenu?] = [:]
    @ObservationIgnored private var cues: [AnyHashable: Cue?] = [:]
    @ObservationIgnored private var flags: [AnyHashable: FocusFlag] = [:]
    /// The restoring group of each item that is in one (``restoreFocus(in:items:)``) and the item of each group that had the
    /// focus last.
    @ObservationIgnored private var groups: [AnyHashable: AnyHashable] = [:]
    @ObservationIgnored private var lastInGroup: [AnyHashable: AnyHashable] = [:]

    public init(initial: AnyHashable? = nil) {
        focused = initial
    }

    public func focus(_ id: AnyHashable) {
        watchingForFirst = false
        move(to: id)
    }

    /// Whether [id] has the focus. Observes only that item's own state: a move of the focus redraws the item that loses it
    /// and the one that gains it, not every item of the screen (a row of covers re-evaluated as a whole at every step of a
    /// held arrow costs the frames of its scroll).
    func isFocused(_ id: AnyHashable) -> Bool {
        if let flag = flags[id] { return flag.on }
        // The stored value, unobserved: the asking view must not depend on every move of the focus
        let flag = FocusFlag(on: _focused == id)
        flags[id] = flag
        return flag.on
    }

    /// Moves the focus to [id]; nothing changes, and nothing is redrawn, when it is there already.
    private func move(to id: AnyHashable?) {
        guard focused != id else { return }
        if let old = focused { flags[old]?.on = false }
        focused = id
        if let id {
            flags[id]?.on = true
            if let group = groups[id] { lastInGroup[group] = id }
        }
    }

    /// Makes [items] a group that gives the focus back to the item of it that had the focus last whenever the focus enters
    /// it from outside by a direction (the library row: Down from the top navigation returns to the cover the focus went
    /// up from, not to the cover under the button). Calling it again replaces the group's items.
    func restoreFocus(in group: AnyHashable, items: [AnyHashable]) {
        groups = groups.filter { $0.value != group }
        for item in items { groups[item] = group }
        if let focused, groups[focused] == group { lastInGroup[group] = focused }
    }

    /// Where a move of the focus from [from] to [target] lands: the last focused item of [target]'s restoring group when the
    /// move enters that group from outside and that item is still there, else [target].
    func restored(_ target: AnyHashable, from: AnyHashable?) -> AnyHashable {
        guard let group = groups[target], from.flatMap({ groups[$0] }) != group, let last = lastInGroup[group],
              last != target, groups[last] == group, frames[last] != nil else { return target }
        return last
    }

    /// While set, the focus is on the first item in reading order of those registered so far (``focusFirstItem()``).
    @ObservationIgnored private var watchingForFirst = false

    /// The screen has nothing the first focus it was opened with could be (an empty or loading library): until the player moves
    /// the focus, or the screen focuses an item itself, the focus is on the first registered item in reading order. It follows
    /// the items as they register, so the answer does not depend on which one the layout reported first.
    func focusFirstItem() {
        watchingForFirst = true
        if let first = fallback(near: nil) { move(to: first) }
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
        if watchingForFirst, let first = fallback(near: nil) {
            move(to: first)
        } else if focused == nil {
            move(to: id)
        }
    }

    func unregister(_ id: AnyHashable) {
        let last = frames[id]
        frames[id] = nil
        actions[id] = nil
        moves[id] = nil
        menus[id] = nil
        cues[id] = nil
        guard focused == id else { return }
        // A screen that leaves unregisters all its items one after the other: its focus must stay on the item it had, for
        // the way back. So the focus moves on only if other items are still there once the layout has settled.
        Task { [weak self] in
            guard let self, focused == id, frames[id] == nil, let next = fallback(near: last) else { return }
            move(to: next)
        }
    }

    /// The item the focus falls to when the one it names is not there (the screen's first item is still being loaded, or the
    /// focused item was removed): the registered item nearest to [rect], else the first in reading order. Never an arbitrary
    /// one: the same screen gives the same answer every time.
    func fallback(near rect: CGRect?) -> AnyHashable? {
        FocusGeometry.fallback(near: rect, candidates: frames).map { AnyHashable($0) }
    }

    /// The items that are registered and where they are (global points): what the navigation audit's tests walk.
    var registeredFrames: [AnyHashable: CGRect] { frames }

    /// The cue of A on the focused item (``FocusItem/init(id:model:moves:clickCue:action:tap:content:)``): SELECT unless
    /// the item names another or none. Whoever routes A plays it with ``Feedback/activate(_:_:)``.
    var acceptCue: Cue? {
        guard let focused, let cue = cues[focused] else { return .select }
        return cue
    }

    /// Whether the focused item has a context menu (the hint bar's options hint). Reads ``focused``, so a view that asks is
    /// redrawn when the focus moves.
    var focusedHasMenu: Bool {
        guard let focused else { return false }
        return menus[focused] != nil
    }

    /// The focused item's context menu and its frame (global points); nil when it has none.
    func contextMenu() -> (ContextMenu, CGRect)? {
        guard let focused, let frame = frames[focused], let menu = menus[focused]?() else { return nil }
        return (menu, frame)
    }

    /// The item under the pointer at [point] (global points) and its frame; nil over none (``FocusGeometry/item(at:candidates:)``).
    func item(at point: CGPoint) -> (id: AnyHashable, frame: CGRect)? {
        guard let id = FocusGeometry.item(at: point, candidates: frames), let frame = frames[id] else { return nil }
        return (id, frame)
    }

    /// Whether [id] registered a context menu (it may still build none when it opens).
    func hasMenu(_ id: AnyHashable) -> Bool { menus[id] != nil }

    /// Waits until [id]'s frame stops moving (the focus scrolled it into view: the library row glides the focused cover to
    /// its place), at most [limit]; a menu opened at once would stand where the item was before the scroll.
    func settled(_ id: AnyHashable, limit: Duration = .milliseconds(900)) async {
        let clock = ContinuousClock(), end = clock.now + limit
        var last = frames[id], still = 0
        while clock.now < end, still < 4 {
            try? await Task.sleep(for: .milliseconds(16))
            let now = frames[id]
            still = now == last ? still + 1 : 0
            last = now
        }
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
        watchingForFirst = false
        guard let focused, let current = frames[focused] else {
            move(to: fallback(near: nil))
            return self.focused != nil
        }
        if let target = moves[focused]?[direction], frames[target] != nil {
            move(to: target)
            return true
        }
        var others = frames
        others[focused] = nil
        guard let next = FocusGeometry.next(from: current, direction: direction, candidates: others) else { return false }
        move(to: restored(AnyHashable(next), from: focused))
        return true
    }
}

/// Whether one item has the focus (``FocusModel/isFocused(_:)``).
@MainActor
@Observable
private final class FocusFlag {
    var on: Bool

    init(on: Bool) {
        self.on = on
    }
}

extension EnvironmentValues {
    /// True for a moment after the item was activated (``Motion/pressHold``): it squeezes to ``Motion/pressScale``.
    @Entry var pressed = false
}

/// What a scroll view that follows the focus gives its items: ``FocusItem`` asks for itself to be brought into view when
/// it gains the focus (a controller or the Siri Remote moves the focus; a custom focus does not scroll on its own), with its
/// frame in the global space when it has been laid out.
@MainActor
final class FocusReveal {
    typealias Scroll = (_ id: AnyHashable, _ frame: CGRect?, _ animated: Bool) -> Void
    var scrollTo: Scroll?
    private var pending: AnyHashable?

    func reveal(_ id: AnyHashable, frame: CGRect?, animated: Bool) {
        if let scrollTo { scrollTo(id, frame, animated) } else { pending = id }
    }

    func attach(_ scroll: @escaping Scroll) {
        scrollTo = scroll
        guard let id = pending else { return }
        pending = nil
        scroll(id, nil, false)
    }
}

extension EnvironmentValues {
    @Entry var focusReveal: FocusReveal?
}

/// A scroll view whose focused item stays in view: the item is centered, so the next one always peeks in at the edge
/// (Android's focus margin). The scroll is one continuous glide on the spring of the focus-driven lists (``ScrollGlide``,
/// `FocusScroller` of DELOS for Android): every move of the focus retargets it and it keeps its speed, so a held arrow
/// glides on instead of stepping. Not animated for reduced motion. The focus is the only thing that scrolls it: the
/// content switches the keyboard scrolling of the scroll view off (``View/focusDrivenScroll()``). The edges fade where
/// content is scrolled away behind them (``FadeEdges``, stage pixels), the mask reaching [bleed] beyond them along the
/// axis and [outset] across it for the rings and glows of the items.
struct FocusScroll<Content: View>: View {
    var axis: Axis = .horizontal
    var fades = FadeEdges.row
    var bleed = 0.0
    var outset = 400.0
    @ViewBuilder let content: () -> Content
    @State private var reveal = FocusReveal()
    @State private var glide = ScrollGlide(pace: .list)
    @State private var position = ScrollPosition()
    @Environment(\.reducedMotion) private var reducedMotion
    @Environment(\.stage) private var stage

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) { content().focusDrivenScroll() }
                .scrollGlide(glide, axis: axis, position: $position)
                .scrollEdgeFade(axis, fades, bleed: bleed, outset: outset)
                .environment(\.focusReveal, reveal)
                .onAppear {
                    let glide = glide, horizontal = axis == .horizontal, unit = stage.scale
                    reveal.attach { id, frame, animated in
                        guard animated, !reducedMotion, let frame else {
                            glide.stop()
                            proxy.scrollTo(id, anchor: .center)
                            return
                        }
                        let view = glide.viewport
                        glide.glide(
                            to: horizontal
                                ? glide.geometry.centering(itemStart: frame.minX, itemEnd: frame.maxX, viewStart: view.minX, viewEnd: view.maxX)
                                : glide.geometry.centering(itemStart: frame.minY, itemEnd: frame.maxY, viewStart: view.minY, viewEnd: view.maxY),
                            unit: unit)
                    }
                }
        }
    }
}

/// Calls an action at each move of a model's focus from a view of its own (``View/onFocusChange(_:perform:)``).
private struct FocusChangeObserver: View {
    let model: FocusModel
    let action: (AnyHashable?) -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: model.focused) { _, now in action(now) }
    }
}

extension View {
    /// Calls [perform] with the new focus at each move of [model]'s focus. The focus is read in a view of its own, so the
    /// view this is put on does not depend on it: a screen that only scrolls along is not rebuilt, with all its items, at
    /// every step of a held arrow.
    func onFocusChange(_ model: FocusModel, perform: @escaping (AnyHashable?) -> Void) -> some View {
        background(FocusChangeObserver(model: model, action: perform))
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
    let tap: (@MainActor (_ wasFocused: Bool) -> Void)?
    let clickCue: Cue?
    let content: (Bool) -> Content
    /// The item holds a text field (``holdingField()``).
    private var holdsField = false
    /// A first tap only focuses the item (``focusingOnFirstTap()``).
    private var firstTapFocuses = false
    @Environment(Layers.self) private var layers: Layers?
    @Environment(\.focusReveal) private var reveal
    @State private var pressed = false
    @State private var release: Task<Void, Never>?
    @Environment(\.modalFocus) private var modalFocus

    /// A layer or the side menu is open and it is not this item's: the item cannot take the focus (tvOS: the system
    /// focus; elsewhere the pointer's hover).
    private var blocked: Bool { modalFocus != nil && modalFocus !== model }

    /// - Parameters:
    ///   - moves: where a direction leads from this item instead of the nearest item that way (iPhone, iPad and Mac;
    ///     on tvOS the system focus engine decides).
    ///   - tap: what a tap does instead of [action] (A): it gets whether the item had the focus before the tap and plays its
    ///     own cue. A settings row's first tap only focuses it, its second changes it.
    ///   - clickCue: the cue of an activation (A or a tap), the same for both: SELECT, another for an item that goes
    ///     back or opens something, nil for one that is silent (or whose action plays its own: a cue played by the action
    ///     replaces this one, see ``Feedback/activate(_:_:)``).
    public init(
        id: ID, model: FocusModel, moves: [FocusDirection: AnyHashable] = [:], clickCue: Cue? = .select,
        action: @escaping @MainActor () -> Void, tap: (@MainActor (_ wasFocused: Bool) -> Void)? = nil, @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.init(id: id, model: model, moves: moves, menu: nil, clickCue: clickCue, action: action, tap: tap, content: content)
    }

    /// - Parameter menu: the item's context menu (the right menu button, X, or a long press on touch), built when it
    ///   opens so it shows what is true then.
    init(
        id: ID, model: FocusModel, moves: [FocusDirection: AnyHashable] = [:], menu: (@MainActor () -> ContextMenu?)?,
        clickCue: Cue? = .select, action: @escaping @MainActor () -> Void, tap: (@MainActor (_ wasFocused: Bool) -> Void)? = nil, @ViewBuilder content: @escaping (Bool) -> Content
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

    /// The item holds a text field: VoiceOver reaches the field itself instead of one button made of the item's content.
    func holdingField() -> Self {
        var item = self
        item.holdsField = true
        return item
    }

    /// Touch: a tap on the item while it has no focus only focuses it (the move cue), a tap on the focused item activates it
    /// as A does, so a tap meant to look at something never starts it. A pointer's click activates at once (its hover focused
    /// the item); A, keys and the long press are unchanged.
    func focusingOnFirstTap() -> Self {
        var item = self
        item.firstTapFocuses = true
        return item
    }

    /// What VoiceOver sees of the item (``FocusItemAccessibility``).
    private var accessibility: FocusItemAccessibility {
        FocusItemAccessibility(field: holdsField, menu: menu != nil, activate: {
            model.focus(AnyHashable(id))
            activate(action)
        }, openMenu: {
            model.focus(AnyHashable(id))
            layers?.openContextMenu(of: model)
        })
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

    /// The item gained the focus: its scroll view brings it into view, from where the item is laid out now.
    private func revealed(_ now: AnyHashable?, animated: Bool = true) {
        let key = AnyHashable(id)
        if now == key { reveal?.reveal(key, frame: model.registeredFrames[key], animated: animated) }
    }

    #if os(tvOS)
    @FocusState private var systemFocused: Bool
    @Environment(\.focusNamespace) private var scope

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
                // The focus engine moved the focus (the model did not ask for it): the move cue. Into a restoring group from
                // outside, the group's last focused item takes it instead (``FocusModel/restored(_:from:)``)
                let target = model.restored(AnyHashable(id), from: model.focused)
                if model.focused != target { layers?.feedback?.play(.move) }
                model.focus(target)
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
            .modifier(accessibility)
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
        // Only this item's own focus: a move redraws the item that loses the focus and the one that gains it
        let focused = model.isFocused(AnyHashable(id))
        let item = content(focused)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                model.register(AnyHashable(id), frame: frame, moves: moves, menu: menu, cue: clickCue, action: pressAction)
            }
            .onDisappear { model.unregister(AnyHashable(id)) }
            .contentShape(Rectangle())
            .onChange(of: focused) { _, now in if now { revealed(AnyHashable(id)) } }
            .onAppear { revealed(model.focused, animated: false) }
            .onTapGesture {
                let key = AnyHashable(id)
                // The pointer focused the item when it moved over it: a click is never only the first tap that focuses
                let wasFocused = model.focused == key || ControllerGlyphs.shared.kind == .pointer
                model.focus(key)
                if let tap {
                    pulse()
                    tap(wasFocused)
                } else if firstTapFocuses && !wasFocused {
                    layers?.feedback?.play(.move)
                } else {
                    activate(action)
                }
            }
            // The pointer moving over the item focuses it (docs/ARCHITECTURE.md, "Pointer"): global points, so content that
            // scrolls under a pointer at rest does not take the focus
            .onContinuousHover(coordinateSpace: .global) { phase in
                guard case .active(let point) = phase, !blocked, PointerHover.shared.moved(to: point) else { return }
                let key = AnyHashable(id)
                guard model.focused != key else { return }
                model.focus(key)
                if PointerHover.shared.cues(at: .now) { layers?.feedback?.play(.move) }
            }
            .modifier(accessibility)
            .environment(\.pressed, pressed)
            .id(id)
        if menu != nil {
            // A long press is the touch way to the context menu; simultaneous, so a scroll view around still scrolls. An item
            // that had no focus is scrolled into view first: the menu opens where the item comes to rest.
            item.simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                let key = AnyHashable(id), hadFocus = model.focused == key
                model.focus(key)
                if hadFocus {
                    layers?.openContextMenu(of: model)
                } else {
                    Task { @MainActor in
                        await model.settled(key)
                        guard model.focused == key else { return }
                        layers?.openContextMenu(of: model)
                    }
                }
            })
        } else {
            item
        }
    }
    #endif
}

/// What VoiceOver sees of a ``FocusItem``: one button made of the item's texts (icons are hidden, an icon-only item labels
/// itself), whose activation is A, so a settings row that a first tap only focuses changes at once. An item with a
/// context menu offers it as a named action; an item that holds a text field keeps the field reachable.
private struct FocusItemAccessibility: ViewModifier {
    let field: Bool
    let menu: Bool
    let activate: @MainActor () -> Void
    let openMenu: @MainActor () -> Void

    func body(content: Content) -> some View {
        if field {
            content.accessibilityElement(children: .contain)
        } else if menu {
            button(content).accessibilityAction(named: L("shell_hint_menu")) { openMenu() }
        } else {
            button(content)
        }
    }

    private func button(_ content: Content) -> some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { activate() }
    }
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
