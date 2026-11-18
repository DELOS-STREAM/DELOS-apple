import Foundation
import Observation

/// A row of a popover page (`MenuRow` of DELOS for Android, StreamMenuPopover.kt:449-560): its icon, label and value, the help
/// the page shows while it is focused, what A or a tap does, and for a slider or a choice what a left or right press does.
struct StreamMenuRow: Identifiable {
    enum Value {
        /// Opens a page or does something at once; shows a chevron.
        case action
        /// A slider in its own unit ([divisor] makes it readable: the bitrate in kbit/s shows Mbit/s); [minText] is what it
        /// reads at its lowest value instead of the number ("0 % (off)").
        case slider(value: Int, range: ClosedRange<Int>, step: Int, unit: String, divisor: Int = 1, minText: String? = nil)
        /// On or off; A or a tap flips it (`RowValue.Toggle`).
        case toggle(Bool)
        /// ◀ [label] ▶: left and right (and A) step through the values; a tap on the focused row lists [options] with
        /// [selected] checked (`RowValue.Choice`).
        case choice(label: String, options: [String], selected: Int)
        /// A value and a chevron; A or a tap acts (`RowValue.Text`). An empty value reads "Not set".
        case text(String)
    }

    let id: String
    let icon: String
    let label: String
    let value: Value
    var enabled = true
    let help: String
    /// A or a tap.
    let activate: @MainActor () -> Void
    /// Sets a slider's value (the touch and drag of the slider, and the steps below), or picks a choice's option by its index.
    var set: (@MainActor (Int) -> Void)?
    /// A choice's step to the left (-1) or right (+1) (`RowValue.Choice.onStep`).
    var step: (@MainActor (Int) -> Void)?
    /// Replaces the value with a check and this word ("Active", "Problem").
    var confirmation: String?

    /// The slider's numbers for its touch popup and its text, nil for another row.
    var sliderSpec: SliderSpec? {
        guard case let .slider(value, range, step, unit, divisor, minText) = value else { return nil }
        return SliderSpec(value: value, min: range.lowerBound, max: range.upperBound, step: step, divisor: divisor, unit: unit, minText: minText)
    }

    /// The value one press of left (-1) or right (+1) leads to, on the slider's grid within its range: [steps] steps when a
    /// held key has accelerated.
    func stepped(_ direction: Int, steps: Int = 1) -> Int? {
        sliderSpec.map { $0.stepped(from: $0.value, by: direction * steps) }
    }

    /// How many steps one key repeat moves a slider: one at first, then more the longer the key is held, up to a fortieth of
    /// the slider's range (`sliderAcceleration`).
    func acceleration(repeatCount: Int) -> Int {
        guard let spec = sliderSpec else { return 1 }
        return HoldRepeat.steps(spec, repeatCount: repeatCount)
    }

    /// What a tap does (StreamMenuPopover.kt:474-482): a disabled row refuses; a choice or slider row opens its popup once
    /// it has the focus (the first tap only focuses it); any other row acts.
    enum Tap: Equatable { case refuse, focus, popup, activate }

    func tap(wasFocused: Bool) -> Tap {
        guard enabled else { return .refuse }
        switch value {
        case .choice(_, let options, _) where !options.isEmpty && set != nil: return wasFocused ? .popup : .focus
        case .slider where set != nil: return wasFocused ? .popup : .focus
        default: return .activate
        }
    }

    /// The row as a settings row, for the touch popups the settings screens share (``RowPopover``).
    var settingRow: SettingRow? {
        let shared: SettingValue
        switch value {
        case let .choice(label, options, selected): shared = .choice(label: label, options: options, selected: selected)
        case let .slider(value, range, step, unit, divisor, _): shared = .slider(value: value, range: range, step: step, divisor: divisor, unit: unit)
        default: return nil
        }
        return SettingRow(id: id, tab: .stream, section: "", icon: icon, label: label, value: shared, help: help, enabled: enabled)
    }

    /// What VoiceOver reads as the row's value: the confirmation word, the slider's number, On or Off, the choice, the text.
    var accessibilityValue: String {
        if let confirmation { return confirmation }
        switch value {
        case .action: return ""
        case let .slider(number, _, _, _, _, _): return sliderSpec?.label(number) ?? "\(number)"
        case .toggle(let on): return L(on ? "common_on" : "common_off")
        case .choice(let label, _, _): return label
        case .text(let text): return text.isEmpty ? L("stream_menu_not_set") : text
        }
    }

    /// VoiceOver's swipe up and down steps the row as left and right do: a choice or a slider that can change.
    var adjustable: Bool {
        guard enabled else { return false }
        switch value {
        case .choice: return step != nil
        case .slider: return set != nil
        default: return false
        }
    }

    /// One step of an adjustable row, -1 or +1.
    @MainActor func adjust(_ direction: Int) {
        if let step {
            step(direction)
        } else if let next = stepped(direction) {
            set?(next)
        }
    }
}

/// A text choice of the Send keys or Commands page: one pill in a row that scrolls when they do not fit.
struct StreamMenuPill: Identifiable {
    let id: String
    let label: String
    let help: String
    let run: @MainActor () -> Void
}

/// What a page shows: rows, or one row of pills (an empty row says [empty]).
enum StreamMenuContent {
    case rows([StreamMenuRow])
    case pills([StreamMenuPill], empty: String?)

    /// The focus ids of the page's items, in order (after the back circle).
    var ids: [String] {
        switch self {
        case .rows(let rows): rows.map { StreamMenuState.rowID($0.id) }
        case .pills(let pills, _): pills.map { StreamMenuState.pillID($0.id) }
        }
    }
}

/// Which page of the popover is open and what has the focus in it (`StreamMenuRoot` of DELOS for Android, the part that is
/// no animation). The dock keeps the screen's own focus; the popover has one of its own, a new one for each page, so the
/// focus cannot leave it and the tile that opened it keeps its focus look.
@MainActor
@Observable
final class StreamMenuState {
    private(set) var page = MenuPage.main
    /// The popover's focus: a new one for each page.
    private(set) var focus = FocusModel()
    /// The page of the popover that is open or was open last: it stays drawn while the popover animates out.
    private(set) var shownPage = MenuPage.more
    /// Counts every page that opened: a new page is a new card content.
    private(set) var session = 0
    /// The page was reached while a popover was open (it morphs), not from the dock.
    private(set) var morph = false
    @ObservationIgnored private var openedAt = Date.distantPast
    /// The frames of the open page's rows in the menu's space, points (where a row's popup points).
    @ObservationIgnored var rowFrames: [String: CGRect] = [:]
    /// How long after a page opened its focus ignores A: the press that opened it is not a choice.
    static let acceptGrace: TimeInterval = 0.3

    static let backID = "popover-back"
    nonisolated static func rowID(_ id: String) -> String { "row-\(id)" }
    nonisolated static func pillID(_ id: String) -> String { "pill-\(id)" }

    var isOpen: Bool { page != .main }

    func swallowsAccept(at now: Date = .now) -> Bool {
        now.timeIntervalSince(openedAt) < Self.acceptGrace
    }

    /// Shows [next] with the focus on [first] (the page's first item, or the row that opened the page above it).
    func open(_ next: MenuPage, focusing first: String, at now: Date = .now) {
        morph = page != .main && next != .main
        page = next
        if next != .main { shownPage = next }
        session += 1
        openedAt = now
        focus = FocusModel(initial: first)
    }

    /// Goes where [exit] says: another page with the focus on its row, or the dock.
    func go(_ exit: PageExit, focusing first: String?, at now: Date = .now) {
        if exit.page == .main {
            close()
        } else {
            open(exit.page, focusing: first ?? Self.backID, at: now)
        }
    }

    func close() {
        guard page != .main else { return }
        morph = false
        page = .main
        session += 1
    }
}
