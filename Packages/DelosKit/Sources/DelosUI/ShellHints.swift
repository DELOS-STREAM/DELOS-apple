import DelosInput
import Foundation

/// What the focused screen says about its own buttons beyond what its kind implies (`FocusTracker.adjustable` and the
/// screen's reset action of DELOS for Android): Settings and the app settings set it as the focus moves.
struct ScreenHints: Equatable, Sendable {
    /// The focused row changes its value with left and right (the adjust hint).
    var adjustable = false
    /// X resets the focused row to the profile's value (an app setting that is custom).
    var resetsRow = false
    /// A filter sheet is open (the artwork's or the library's): its own buttons, reset and done or close.
    var sheetOpen = false
    /// The home screen's label for Y ("Filter", "Filter • 2 active"); nil: the library has nothing to filter.
    var filterLabel: String?
    /// What A does on the focused item of the Artwork screen (the hint bar's A button): the screen sets it as the focus moves.
    var artworkSouth = ArtworkSouth.useImage
}

/// The button hints of the shell (`hints` in DELOS for Android's `Shell.kt`, the prototype's `updateHints`): by screen and
/// layer, which buttons do what. The home screen's filter hint and the Artwork screen's are here too.
enum ShellHints {
    enum Layer: Equatable, Sendable {
        /// A context menu; [root]: its first level (B closes it), else B goes back one level.
        case context(root: Bool)
        case dialog
    }

    struct Context: Sendable {
        var screen: Screen
        var layer: Layer?
        var sideMenu = false
        /// The portal into a PC is up: nil when it is not, else whether B can cancel it.
        var portalCancellable: Bool?
        var canGoBack = false
        /// The focused item has a context menu (the right menu button and X open it).
        var hasContextMenu = false
        var screenHints = ScreenHints()
    }

    /// The hints for the kind of input in use: the controller's own, or what the other kinds do (``adapt(_:to:)``).
    @MainActor static func hints(_ c: Context, kind: InputKind = ControllerGlyphs.shared.kind) -> [Hint] {
        adapt(padHints(c), to: kind)
    }

    /// The hints written for a controller, turned into the ones of [kind]. The rules (docs/ARCHITECTURE.md, "Input kind"):
    /// - controller: unchanged;
    /// - touch: only the primary action stays, with the tap symbol (every other action has a control on the screen), and a
    ///   tappable hint (the library's Filter), which the bar draws as a glass pill with its symbol;
    /// - pointer (mouse, trackpad): the same, with the pointer symbol;
    /// - keyboard: Return for the primary action, Esc for back, the arrows for the adjust cue; the buttons with no key
    ///   (tabs, menu buttons, X, Y) are dropped.
    nonisolated static func adapt(_ hints: [Hint], to kind: InputKind) -> [Hint] {
        func map(_ hint: Hint, _ button: HintButton?) -> Hint? {
            button.map { Hint(button: $0, label: hint.label, shortLabel: hint.shortLabel) }
        }
        switch kind {
        case .controller: return hints
        case .touch, .pointer:
            let primary: HintButton = kind == .touch ? .tap : .click
            // A tappable hint (Filter) stays: it is the control on the screen, as a glass pill with its symbol
            return hints.compactMap { $0.tappable ? $0 : map($0, $0.button == .pad(.south) ? primary : nil) }
        case .keyboard:
            return hints.compactMap { hint -> Hint? in
                if hint.tappable { return hint }
                switch hint.button {
                case .pad(.south): return map(hint, .key(.returnKey))
                case .pad(.east): return map(hint, .key(.escape))
                case .adjust: return map(hint, .key(.arrows))
                default: return nil
                }
            }
        }
    }

    @MainActor private static func padHints(_ c: Context) -> [Hint] {
        func hint(_ role: GlyphRole, _ label: String, short: String? = nil) -> Hint {
            Hint(button: .pad(role), label: label, shortLabel: short)
        }
        let adjust = Hint(button: .adjust, label: L("shell_hint_adjust"))
        let options = hint(.menuRight, L("shell_hint_options"))
        let select = hint(.south, L("shell_hint_select"))
        let back = hint(.east, L("shell_hint_back"))
        let tabs = [hint(.leftShoulder, L("shell_hint_previous_tab")), hint(.rightShoulder, L("shell_hint_next_tab"))]
        let menu = hint(.menuLeft, L("shell_hint_menu"))
        if let cancellable = c.portalCancellable { return cancellable ? [hint(.east, L("shell_hint_cancel"))] : [] }
        if c.sideMenu { return [adjust, hint(.south, L("shell_hint_change")), hint(.east, L("shell_hint_close"))] }
        switch c.layer {
        case .context(let root)?: return [select, hint(.east, L(root ? "shell_hint_close" : "shell_hint_back"))]
        case .dialog?: return [select, hint(.east, L("shell_hint_cancel"))]
        case nil: break
        }
        let adjustHint = c.screenHints.adjustable ? [adjust] : []
        let optionsHint = c.hasContextMenu ? [options] : []
        switch c.screen {
        case .home:
            if c.screenHints.sheetOpen {
                // The same as the Artwork screen's sheet (Android's sheet hints): Y is Done, not a second Close
                return [hint(.south, L("shell_hint_choose")), hint(.west, L("shell_hint_reset_filters"), short: L("shell_hint_reset")),
                        hint(.north, L("shell_hint_done")), hint(.east, L("shell_hint_close"))]
            }
            let filter = c.screenHints.filterLabel.map { [Hint(button: .pad(.north), label: $0, tappable: true, icon: Symbols.filter)] } ?? []
            return [hint(.south, L("shell_hint_start"))] + filter + [menu] + optionsHint
        case .settings: return adjustHint + tabs + [hint(.north, L("shell_hint_search")), hint(.south, L("shell_hint_change")), back]
        case .start: return [hint(.south, L("shell_hint_connect")), menu] + optionsHint
        case .boot: return [select] + (c.canGoBack ? [back] : [])
        case .createProfile: return [select, back]
        case .pair: return [select, back] + optionsHint
        case .pin, .pairCode: return [hint(.east, L("shell_hint_cancel"))]
        case .stream: return []
        case .artwork:
            if c.screenHints.sheetOpen {
                return [
                    hint(.south, L("shell_hint_choose")), hint(.west, L("shell_hint_reset_filters"), short: L("shell_hint_reset")),
                    hint(.north, L("shell_hint_done")), hint(.east, L("shell_hint_close")),
                ]
            }
            let south: Hint
            switch c.screenHints.artworkSouth {
            case .useImage: south = hint(.south, L("shell_hint_use_image"), short: L("shell_hint_choose"))
            case .select: south = select
            case .searchName: south = hint(.south, L("shell_hint_search_name"), short: L("shell_hint_search"))
            case .filter: south = hint(.south, L("shell_hint_filter"))
            case .resetFilters: south = hint(.south, L("shell_hint_reset_filters"), short: L("shell_hint_reset"))
            case .changeFilters: south = hint(.south, L("filters_art_change"), short: L("shell_hint_filter"))
            }
            // X is the search by name here and resets the filters only inside the sheet, which has its own buttons above
            return tabs + [south, hint(.west, L("shell_hint_search_name"), short: L("shell_hint_search")), hint(.north, L("shell_hint_filter")), back]
        case .appSettings:
            return adjustHint + [hint(.south, L("shell_hint_change"))]
                + (c.screenHints.resetsRow ? [hint(.west, L("shell_hint_reset_to_profile"), short: L("shell_hint_reset"))] : [])
                + optionsHint + [back]
        case .profile, .devices: return [select, back, menu]
        }
    }

    /// Whether left and right change [row]'s value: a slider or a list of values of a row that is available.
    static func adjustable(_ row: SettingRow?) -> Bool {
        guard let row, row.enabled else { return false }
        switch row.value {
        case .slider, .choice: return true
        case .toggle, .action, .appSettings, .info: return false
        }
    }

    /// The note on the left of the home screen's bar: how many apps the PC has.
    @MainActor static func libraryNote(apps: Int, pc: String) -> String {
        String.localizedStringWithFormat(Bundle.module.localizedString(forKey: "shell_home_apps_on_pc", value: nil, table: nil), apps, pc)
    }
}
