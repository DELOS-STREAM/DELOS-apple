import Foundation
import Observation

/// A row of a popover page (`MenuRow` of DELOS for Android): its icon, label and value, the help the page shows while it is
/// focused, what A or a tap does, and for a slider what a left or right press does.
struct StreamMenuRow: Identifiable {
    enum Value {
        /// Opens a page or does something at once; shows a chevron.
        case action
        case slider(value: Int, range: ClosedRange<Int>, step: Int, unit: String)
    }

    let id: String
    let icon: String
    let label: String
    let value: Value
    var enabled = true
    let help: String
    /// A or a tap.
    let activate: @MainActor () -> Void
    /// Sets a slider's value (the touch and drag of the slider, and the steps below).
    var set: (@MainActor (Int) -> Void)?

    /// The value one press of left (-1) or right (+1) leads to, on the slider's grid within its range: [steps] steps when a
    /// held key has accelerated.
    func stepped(_ direction: Int, steps: Int = 1) -> Int? {
        guard case let .slider(value, range, step, _) = self.value else { return nil }
        let next = value + direction * steps * step
        let snapped = range.lowerBound + Int((Double(next - range.lowerBound) / Double(step)).rounded()) * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    /// How many steps one key repeat moves a slider: one at first, then more the longer the key is held, up to a fortieth of
    /// the slider's range (`sliderAcceleration`).
    func acceleration(repeatCount: Int) -> Int {
        guard case let .slider(_, range, step, _) = value else { return 1 }
        let steps = (range.upperBound - range.lowerBound) / step
        let wanted = repeatCount < 8 ? 1 : repeatCount < 20 ? 5 : repeatCount < 35 ? 10 : 50
        return min(wanted, max(1, steps / 40))
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
