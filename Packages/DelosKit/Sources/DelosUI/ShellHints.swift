import DelosInput
import Foundation

/// What the focused screen says about its own buttons beyond what its kind implies (`FocusTracker.adjustable` and the
/// screen's reset action of DELOS for Android): Settings and the app settings set it as the focus moves.
struct ScreenHints: Equatable, Sendable {
    /// The focused row changes its value with left and right (the adjust hint).
    var adjustable = false
    /// Options opens something on the focused settings row (``RowOptions``): its list of values, its slider, or the menu of a
    /// custom app setting.
    var rowOptions = false
    /// A filter sheet is open (the artwork's or the library's): its own buttons, reset and done or close.
    var sheetOpen = false
    /// The home screen's label for Y ("Filter", "Filter • 2 active"); nil: the library has nothing to filter.
    var filterLabel: String?
    /// What A does on the focused item of the Artwork screen (the hint bar's A button): the screen sets it as the focus moves.
    var artworkSouth = ArtworkSouth.useImage
    /// The Artwork screen of one of DELOS's own entries: A and B both go back.
    var artworkBuiltIn = false
    /// The result of a failed stream is up (`shell.result`): Select and Back to library.
    var streamResult = false
    /// The Settings screen's search is open (`Screen.SettingsSearch`): Select and Back.
    var settingsSearch = false
    /// The popover of the focused row is open (Android's `shell.picker`): a list of values or a slider.
    var rowPopup: RowPopupKind?
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
        /// The side menu's focused row changes its value with left and right (Theme, Background): the adjust hint.
        var sideMenuAdjustable = false
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
    /// - pointer (mouse, trackpad): the primary action with the click, the right menu button (the context menu) with the
    ///   secondary click, and the tappable hint as a pill;
    /// - keyboard: every button with its key (``KeyCap/of(_:)``: Return, Esc, Tab, O, F, [ and ], the arrows), the tappable
    ///   hint too (a key is pressed, not the pill); X and the right menu button are both O, so it shows once.
    nonisolated static func adapt(_ hints: [Hint], to kind: InputKind) -> [Hint] {
        func map(_ hint: Hint, _ button: HintButton?) -> Hint? {
            button.map { Hint(button: $0, label: hint.label, shortLabel: hint.shortLabel) }
        }
        switch kind {
        case .controller: return hints
        case .touch:
            // A tappable hint (Filter) stays: it is the control on the screen, as a glass pill with its symbol
            return hints.compactMap { $0.tappable ? $0 : map($0, $0.button == .pad(.south) ? .tap : nil) }
        case .pointer:
            return hints.compactMap { hint -> Hint? in
                if hint.tappable { return hint }
                switch hint.button {
                case .pad(.south): return map(hint, .click)
                case .pad(.menuRight): return map(hint, .secondaryClick)
                default: return nil
                }
            }
        case .keyboard:
            var shown = Set<KeyCap>()
            return hints.compactMap { hint -> Hint? in
                guard let cap = hint.key ?? KeyCap.of(hint.button), shown.insert(cap).inserted else { return nil }
                return map(hint, .key(cap))
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
        switch c.screenHints.rowPopup {
        case .options?: return [select, hint(.east, L("shell_hint_close"))]
        case .slider?: return [adjust, hint(.south, L("shell_hint_done")), hint(.east, L("shell_hint_close"))]
        case nil: break
        }
        if c.sideMenu { return (c.sideMenuAdjustable ? [adjust] : []) + [hint(.south, L("shell_hint_change")), hint(.east, L("shell_hint_close"))] }
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
                // The library's filter sheet (Android's `Layer.Filters`): Y applies the choices, B drops them. On a keyboard Space
                // toggles a chip and Return applies (`HomeScreen.captureSheet`)
                return [
                    Hint(button: .pad(.south), label: L("shell_hint_select"), key: .space), hint(.west, L("shell_hint_reset")),
                    Hint(button: .pad(.north), label: L("shell_hint_apply"), key: .returnKey), hint(.east, L("shell_hint_close")),
                ]
            }
            let filter = c.screenHints.filterLabel.map { [Hint(button: .pad(.north), label: $0, tappable: true, icon: Symbols.filter)] } ?? []
            return [hint(.south, L("shell_hint_start"))] + filter + [menu] + optionsHint
        case .settings:
            if c.screenHints.settingsSearch { return [select, back] }
            return adjustHint + tabs + [hint(.north, L("shell_hint_search")), hint(.south, L("shell_hint_change"))]
                + (c.screenHints.rowOptions ? [options] : []) + [back]
        case .start: return [hint(.south, L("shell_hint_connect")), menu] + optionsHint
        case .boot: return [select] + (c.canGoBack ? [back] : [])
        case .createProfile: return [select, back]
        case .pair: return [select, back] + optionsHint
        case .pin, .pairCode: return [hint(.east, L("shell_hint_cancel"))]
        case .stream:
            return c.screenHints.streamResult
                ? [select, hint(.east, L("shell_hint_back_to_library"), short: L("shell_hint_back"))] : []
        case .oscPreview: return []
        case .debugInfo: return adjustHint + [select, back]
        case .artwork:
            if c.screenHints.artworkBuiltIn { return [hint(.south, L("shell_hint_back")), back] }
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
            return adjustHint + tabs + [hint(.south, L("shell_hint_change"))] + (c.screenHints.rowOptions ? [options] : []) + [back]
        case .profile, .devices: return [select, back, menu]
        }
    }

    /// Whether left and right change [row]'s value: a slider or a list of values of a row that is available.
    static func adjustable(_ row: SettingRow?) -> Bool {
        guard let row, row.enabled else { return false }
        switch row.value {
        case .slider, .choice: return true
        case .toggle, .action, .text, .appSettings, .info: return false
        }
    }

    /// The note on the left of the home screen's bar: how many apps the PC has.
    @MainActor static func libraryNote(apps: Int, pc: String) -> String {
        String.localizedStringWithFormat(Bundle.module.localizedString(forKey: "shell_home_apps_on_pc", value: nil, table: nil), apps, pc)
    }
}
