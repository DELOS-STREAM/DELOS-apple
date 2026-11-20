import CoreGraphics
import DelosInput
import Observation
import SwiftUI

/// A row of a context menu (`MenuItem` of DELOS for Android). A [danger] row is red and its focus plate turns red:
/// choosing it is the confirmation, there is no dialog. An item with [children] opens them inside the same card (B goes
/// back one level) and has no action.
struct MenuItem {
    let icon: String
    let label: String
    var danger = false
    var children: [MenuItem]?
    var action: @MainActor () -> Void = {}
}

/// The color of a menu header's icon tile (`HeaderTint`).
enum HeaderTint {
    /// The theme's main color.
    case accent
    /// The game's main color.
    case color(RGBA)
    /// A game's: its cover's main color once worked out, the theme's accent while the interface does not take the games' colors
    /// or the cover is grey, the placeholder art's hue while the game has no cover, a neutral chip for the short time between
    /// a cover's decoding and its colors (`gameHeaderTint` and `HeaderTint.Pending` of DELOS for Android).
    case cover(hostID: String, appID: Int, placeholderHue: Double)
}

/// What a menu says about its subject above its title (`MenuHeader`): an icon tile in the subject's color, a [status]
/// line (a green dot before it while [running]) and one line of [meta]. Menus without a header show just the title.
struct MenuHeader {
    let status: String
    var tint = HeaderTint.accent
    var running = false
    var meta: String?
}

/// A context menu for the focused element (`ContextMenu`): the right menu button, X or a long press opens it. With
/// [below] the card opens under the element with its caret on top (a menu that belongs to a PC or a button) instead of
/// beside it.
struct ContextMenu {
    let title: String
    let items: [MenuItem]
    var header: MenuHeader?
    var below = false
    /// With [below]: never above the element (`placeContextMenu`'s `underOnly`), for an element under a heading.
    var underOnly = false
    /// The row focused when the menu opens: a menu that is the confirmation of a destructive choice starts on the safe row.
    var initialRow = 0
}

/// A field of a dialog (`DialogField`).
struct DialogField {
    let icon: String
    var initial = ""
    var placeholder = ""
    var maxLength = 24
    /// A secret (Android's `password`): the value is hidden.
    var secret = false
    /// An address (Android's `KeyboardType.Uri`): no capitals, the URL keyboard.
    var address = false
}

/// A small dialog (`DialogSpec`): title, note, fields and a confirm button. [onConfirm] gets the values and returns
/// whether the dialog may close.
struct DialogSpec {
    let title: String
    let note: String
    let fields: [DialogField]
    let confirm: String
    let onConfirm: @MainActor ([String]) -> Bool
}

/// The layers above the current screen (`Layer` and the layer half of `ShellState` in DELOS for Android): a context menu,
/// a dialog or the recording of the stream menu's buttons, one at a time. An open layer has its own focus and takes every
/// controller and keyboard command; the screen's focus stays where it was, so the element a menu belongs to keeps its focus
/// look and has the focus again when the layer closes.
@MainActor
@Observable
final class Layers {
    enum Layer {
        /// [anchor]: the frame of the element the menu belongs to, in global points (nil: no element).
        case context(ContextMenu, anchor: CGRect?)
        case dialog(DialogSpec)
        /// Records the stream menu's buttons (`ButtonCaptureLayer`): every controller button is the capture's.
        case buttonCapture(MenuButtonCapture)
    }

    private(set) var layer: Layer?
    /// The submenus of the open context menu, as the index of the opened item at each level (empty: the menu itself).
    private(set) var menuPath: [Int] = []
    /// The focus inside the open layer; a new one for each layer and each submenu level.
    private(set) var focus = FocusModel()
    /// Where the open context menu's caret points, as a fraction of the layer: the card shrinks back into it.
    var menuTip = CGPoint(x: 0.5, y: 0.5)
    @ObservationIgnored var feedback: Feedback?
    /// Counts every layer that opened or closed: what the layers' appearance animates on.
    private(set) var generation = 0
    /// The element frame the last context menu opened at, in global points.
    private(set) var menuAnchor: CGRect?

    var isOpen: Bool { layer != nil }

    /// Opens the context menu of the focused item of [model] at its frame; false when it has none.
    @discardableResult
    func openContextMenu(of model: FocusModel) -> Bool {
        guard let (menu, frame) = model.contextMenu() else { return false }
        open(.context(menu, anchor: frame), focus: Self.rowID(menu.initialRow))
        return true
    }

    func openDialog(_ spec: DialogSpec) {
        open(.dialog(spec), focus: DialogLayer.firstFocus(spec))
    }

    /// Records the stream menu's buttons; [onRecorded] gets the combination once all of its buttons are let go. Without a
    /// press for ten seconds, or after a tap anywhere, the layer closes unchanged.
    func openButtonCapture(onRecorded: @escaping @MainActor (Set<ShortcutButton>) -> Void) {
        let capture = MenuButtonCapture { [weak self] buttons in
            self?.close()
            if let buttons { onRecorded(buttons) }
        }
        open(.buttonCapture(capture), focus: AnyHashable("button-capture"))
        capture.start()
    }

    /// Opens a menu a chosen menu item leads to (a list of matches after "Search"), at the frame the last menu had.
    func openContextMenu(_ menu: ContextMenu, anchor: CGRect?) {
        open(.context(menu, anchor: anchor), focus: Self.rowID(menu.initialRow))
    }

    /// When the layer opened: an A, Return or click within ``acceptGrace`` of it is the press that opened it (a double
    /// press or double click), not a choice.
    @ObservationIgnored private var openedAt = Date.distantPast
    static let acceptGrace: TimeInterval = 0.3

    func swallowsAccept(at now: Date = .now) -> Bool {
        now.timeIntervalSince(openedAt) < Self.acceptGrace
    }

    private func open(_ next: Layer, focus first: AnyHashable) {
        openedAt = .now
        feedback?.play(.open)
        menuPath = []
        focus = FocusModel(initial: first)
        if case .context(_, let anchor) = next { menuAnchor = anchor }
        layer = next
        generation += 1
    }

    func close() {
        guard let closing = layer else { return }
        layer = nil
        menuPath = []
        generation += 1
        // A recording that closes any other way ends unchanged and gives the controllers back
        if case .buttonCapture(let capture) = closing { capture.cancel() }
    }

    /// B: a submenu goes back to its parent, with the focus on the row that opened it; otherwise the layer closes.
    func back() {
        feedback?.play(.back)
        if case .context = layer, let last = menuPath.last {
            menuPath = MenuPath.back(menuPath)
            focus = FocusModel(initial: Self.rowID(last))
        } else {
            close()
        }
    }

    /// A row of the open menu was chosen: a submenu opens in the same card, an action closes the menu and runs.
    func choose(_ index: Int) {
        guard case let .context(menu, _) = layer else { return }
        if let deeper = MenuPath.open(menu.items, menuPath, index) {
            menuPath = deeper
            focus = FocusModel(initial: Self.rowID(0))
            return
        }
        let items = MenuPath.items(menu.items, menuPath)
        guard items.indices.contains(index) else { return }
        close()
        items[index].action()
    }

    /// A controller or keyboard command while a layer is open: it never reaches the screen behind it.
    func handle(_ command: MenuCommand, at now: Date = .now) {
        guard let layer else { return }
        // Every button may be wanted for the stream menu's combination: the recording has them all
        if case .buttonCapture = layer { return }
        switch command {
        case .back:
            back()
        case .options:
            // The button that opened the menu closes it, submenus and all
            if case .context = layer { dismiss() }
        case .accept:
            guard !swallowsAccept(at: now) else { return }
            if let feedback { feedback.activate(focus.acceptCue) { focus.handle(.accept) } } else { focus.handle(.accept) }
        case .up, .down:
            if focus.handle(command) { feedback?.play(.move) }
        case .left, .right:
            if case .dialog = layer, focus.handle(command) { feedback?.play(.move) }
        case .previousTab, .nextTab, .menu, .toastAction, .mute:
            break
        }
    }

    /// A tap beside the layer or the button that opened a menu: the layer closes, submenus and all. A tap during the
    /// recording of the stream menu's buttons ends it unchanged, without a sound (`ButtonCaptureLayer`).
    func dismiss() {
        if case .buttonCapture = layer {
            close()
            return
        }
        feedback?.play(.back)
        close()
    }

    /// The focus id of row [index] of the open menu.
    static func rowID(_ index: Int) -> AnyHashable { AnyHashable("menu-row-\(index)") }
}

/// The scrim under a layer (`Scrim` of DELOS for Android): it fades in over ``Motion/scrim`` ms and out over
/// ``Motion/exit`` ms with CSS `ease`; a tap on it closes the layer. The context menu's is the [light] one that only dims
/// (4, 8, 16 at 26 %); every other layer's is the theme's scrim token, and the screen beneath it blurs
/// (``LayerBackdropBlur``). While a touch drag moves the side menu, [progress] is its opening progress: the scrim follows
/// it instead of fading in and out.
struct LayerScrim: View {
    var light = false
    var progress: Double? = nil
    let onTap: @MainActor () -> Void
    @Environment(\.delosColors) private var colors

    var body: some View {
        Rectangle()
            .fill(light ? RGBA(red: 4 / 255, green: 8 / 255, blue: 16 / 255, alpha: 0.26).color : colors.scrim.color)
            .opacity(progress.map { min(max($0, 0), 1) } ?? 1)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .transition(progress != nil ? .identity : .asymmetric(
                insertion: .opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.scrim / 1000)),
                removal: .opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.exit / 1000))))
    }
}

/// The screen under a layer's scrim blurs by 6 stage pixels (`Modifier.backdropBlur(haze, 6f, scrim)` of `Scrim`), with the
/// scrim's fades; while a touch drag moves the side menu, by its opening [progress] of that.
struct LayerBackdropBlur: ViewModifier {
    let active: Bool
    var progress: Double? = nil
    @Environment(\.stage) private var stage

    func body(content: Content) -> some View {
        content
            .blur(radius: active ? stage.px(6) * CGFloat(progress.map { min(max($0, 0), 1) } ?? 1) : 0)
            .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: (active ? Motion.scrim : Motion.exit) / 1000), value: active)
    }
}

extension Layers {
    /// Whether the layer blurs the screen under its scrim: every layer but the context menu's light one and the button
    /// recording's plain scrim.
    var blursScreen: Bool {
        guard let layer else { return false }
        switch layer {
        case .context, .buttonCapture: return false
        case .dialog: return true
        }
    }
}

/// Shows the open layer over the screen (Android's `Scrim`, `ContextMenuLayer` and `DialogLayer` in the shell): a light
/// scrim under a context menu, the darker scrim under a dialog; a tap on the scrim closes the layer. The menu shrinks
/// back into its caret's tip, a dialog settles in from a slight scale and leaves the same way.
struct LayerHost: View {
    let layers: Layers
    let navigator: Navigator
    @Environment(\.reducedMotion) private var reducedMotion

    var body: some View {
        ZStack {
            if let layer = layers.layer {
                let isMenu = if case .context = layer { true } else { false }
                // The recording draws its own scrim, with its own fades
                if case .buttonCapture = layer {} else { LayerScrim(light: isMenu, onTap: layers.dismiss) }
                switch layer {
                case let .buttonCapture(capture):
                    ButtonCaptureLayer(capture: capture, onTap: layers.dismiss)
                        .id(layers.generation)
                        .transition(.opacity.animation(ButtonCaptureLayer.fade))
                case let .context(menu, anchor):
                    let tip = UnitPoint(x: layers.menuTip.x, y: layers.menuTip.y)
                    ContextMenuLayer(layers: layers, menu: menu, anchor: anchor)
                        .id(layers.generation)
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: reducedMotion ? Self.fade(Motion.exit)
                                : Self.fade(Motion.exit).combined(with: .scale(scale: Motion.popFromScale, anchor: tip).animation(Self.easeIn(Motion.exit)))))
                case let .dialog(spec):
                    DialogLayer(layers: layers, spec: spec, navigator: navigator)
                        .id(layers.generation)
                        .transition(.asymmetric(
                            insertion: reducedMotion ? Self.fade(Motion.fade)
                                : Self.fade(Motion.fade)
                                    .combined(with: .scale(scale: Motion.dialogFromScale).animation(Motion.out(Motion.popIn)))
                                    .combined(with: SlideByHeight(fraction: 1 / 25).animation(Motion.out(Motion.popIn))),
                            removal: reducedMotion ? Self.fade(Motion.exit)
                                : Self.fade(Motion.exit)
                                    .combined(with: .scale(scale: Motion.dialogFromScale).animation(Self.easeIn(Motion.exit)))
                                    .combined(with: SlideByHeight(fraction: 1 / 25).animation(Self.easeIn(Motion.exit)))))
                }
            }
        }
        .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.exit / 1000), value: layers.generation)
        // VoiceOver stays inside an open layer, and its escape gesture goes back as B does
        .accessibilityAddTraits(layers.layer == nil ? [] : .isModal)
        .accessibilityAction(.escape) { layers.back() }
    }

    private static func fade(_ ms: Double) -> AnyTransition {
        .opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: ms / 1000))
    }

    /// `--ease-in` over [ms] milliseconds: what leaves.
    static func easeIn(_ ms: Double) -> Animation { .timingCurve(0.5, 0, 0.75, 0, duration: ms / 1000) }
}

/// An element moves down by a fraction of its own height while it enters and leaves (`slideInVertically { it / 25 }`).
struct SlideByHeight: Transition {
    let fraction: Double

    func body(content: Content, phase: TransitionPhase) -> some View {
        content.visualEffect { view, proxy in
            view.offset(y: phase.isIdentity ? 0 : proxy.size.height * fraction)
        }
    }
}

extension Transition {
    func animation(_ animation: Animation) -> AnyTransition {
        AnyTransition(self).animation(animation)
    }
}
