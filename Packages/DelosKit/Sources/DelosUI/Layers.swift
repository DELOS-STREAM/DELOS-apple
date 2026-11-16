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
}

/// A field of a dialog (`DialogField`).
struct DialogField {
    let icon: String
    var initial = ""
    var placeholder = ""
    var maxLength = 24
    /// A secret (Android's `password`): the value is hidden.
    var secret = false
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

/// The layers above the current screen (`Layer` and the layer half of `ShellState` in DELOS for Android): a context menu
/// or a dialog, one at a time. An open layer has its own focus and takes every controller and keyboard command; the
/// screen's focus stays where it was, so the element a menu belongs to keeps its focus look and has the focus again when
/// the layer closes.
@MainActor
@Observable
final class Layers {
    enum Layer {
        /// [anchor]: the frame of the element the menu belongs to, in global points (nil: no element).
        case context(ContextMenu, anchor: CGRect?)
        case dialog(DialogSpec)
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

    var isOpen: Bool { layer != nil }

    /// Opens the context menu of the focused item of [model] at its frame; false when it has none.
    @discardableResult
    func openContextMenu(of model: FocusModel) -> Bool {
        guard let (menu, frame) = model.contextMenu() else { return false }
        open(.context(menu, anchor: frame), focus: Self.rowID(0))
        return true
    }

    func openDialog(_ spec: DialogSpec) {
        open(.dialog(spec), focus: DialogLayer.firstFocus(spec))
    }

    private func open(_ next: Layer, focus first: AnyHashable) {
        feedback?.play(.open)
        menuPath = []
        focus = FocusModel(initial: first)
        layer = next
        generation += 1
    }

    func close() {
        guard layer != nil else { return }
        layer = nil
        menuPath = []
        generation += 1
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
    func handle(_ command: MenuCommand) {
        guard let layer else { return }
        switch command {
        case .back:
            back()
        case .options:
            // The button that opened the menu closes it, submenus and all
            if case .context = layer { dismiss() }
        case .accept:
            if let feedback { feedback.activate(focus.acceptCue) { focus.handle(.accept) } } else { focus.handle(.accept) }
        case .up, .down:
            if focus.handle(command) { feedback?.play(.move) }
        case .left, .right:
            if case .dialog = layer, focus.handle(command) { feedback?.play(.move) }
        case .previousTab, .nextTab, .menu, .toastAction:
            break
        }
    }

    /// A tap beside the layer or the button that opened a menu: the layer closes, submenus and all.
    func dismiss() {
        feedback?.play(.back)
        close()
    }

    /// The focus id of row [index] of the open menu.
    static func rowID(_ index: Int) -> AnyHashable { AnyHashable("menu-row-\(index)") }
}

/// Shows the open layer over the screen (Android's `Scrim`, `ContextMenuLayer` and `DialogLayer` in the shell): a light
/// scrim under a context menu, the darker scrim under a dialog; a tap on the scrim closes the layer. The menu shrinks
/// back into its caret's tip, a dialog settles in from a slight scale and leaves the same way.
struct LayerHost: View {
    let layers: Layers
    let navigator: Navigator
    @Environment(\.delosColors) private var colors
    @Environment(\.reducedMotion) private var reducedMotion

    var body: some View {
        ZStack {
            if let layer = layers.layer {
                let isMenu = if case .context = layer { true } else { false }
                Rectangle()
                    .fill(isMenu ? RGBA(red: 4 / 255, green: 8 / 255, blue: 16 / 255, alpha: 0.26).color : colors.scrim.color)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: layers.dismiss)
                    .transition(.opacity)
                switch layer {
                case let .context(menu, anchor):
                    let tip = UnitPoint(x: layers.menuTip.x, y: layers.menuTip.y)
                    ContextMenuLayer(layers: layers, menu: menu, anchor: anchor)
                        .id(layers.generation)
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: reducedMotion ? .opacity : .opacity.combined(with: .scale(scale: Motion.popFromScale, anchor: tip))))
                case let .dialog(spec):
                    DialogLayer(layers: layers, spec: spec, navigator: navigator)
                        .id(layers.generation)
                        .transition(reducedMotion ? .opacity
                            : .opacity.combined(with: .scale(scale: Motion.dialogFromScale)).combined(with: .offset(y: 24)))
                }
            }
        }
        .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.exit / 1000), value: layers.generation)
    }
}
