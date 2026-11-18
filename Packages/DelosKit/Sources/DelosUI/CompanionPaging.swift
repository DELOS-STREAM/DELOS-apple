import SwiftUI

/*
 * Long lists on the companion (the special keys, the PC's commands, the More page of the stream menu), the port of
 * `CompanionPaging.kt` of DELOS for Android: they never scroll. The entries sit in a grid of buttons at least 64 px high
 * that takes as many columns and rows as the room allows; when they do not all fit, the grid shows one page of them and a
 * row of Previous / Next with "2 / 3" between them. The arithmetic is pure (``CompanionGridPaging``).
 */

/// The page of a grid (`GridPlan`, CompanionPaging.kt:33): how many [rows] one page has, its [perPage] entries, the number
/// of [pages], and whether the pager row takes the last row of the room.
struct CompanionGridPlan: Equatable, Sendable {
    let rows: Int
    let perPage: Int
    let pages: Int
    let pager: Bool
}

enum CompanionGridPaging {
    /// The gap between the buttons of a grid, in stage pixels.
    static let gap = 8.0
    /// What a button adds to its label's width, in fit pixels: its padding at both sides (a little over) and the gap to its icon.
    static let buttonChrome = 48.0
    /// The icon of a button and its gap, in fit pixels.
    static let iconFit = 48.0
    /// The least height of a list's grid: two rows of 64 px targets and the gap (`GRID_MIN`, CompanionStreamContent.kt:282).
    static let minHeight = 2 * CompanionFit.minTarget + gap

    /// The grid of [count] entries in a room of [height] with rows of [rowHeight] and [gap] between them, [columns] to a row
    /// (`GridPaging.plan`, CompanionPaging.kt:40-48). All entries when they fit; else the pager takes one row and the rest is
    /// the page (at least one row, so a page never has less than [columns] entries).
    static func plan(height: Double, rowHeight: Double, gap: Double, columns: Int, count: Int) -> CompanionGridPlan {
        let cols = max(columns, 1)
        func rowsIn(_ room: Double) -> Int { max(Int(((room + gap) / (rowHeight + gap)).rounded(.down)), 1) }
        let needed = max(Int((Double(count) / Double(cols)).rounded(.up)), 1)
        if rowsIn(height) >= needed { return CompanionGridPlan(rows: needed, perPage: max(count, 1), pages: 1, pager: false) }
        let rows = rowsIn(height - rowHeight - gap)
        let perPage = rows * cols
        return CompanionGridPlan(rows: rows, perPage: perPage, pages: max(Int((Double(count) / Double(perPage)).rounded(.up)), 1), pager: true)
    }

    /// How many columns (at most [max]) a grid in [width] can have so that the widest of [labelWidths] still fits one line of
    /// a button (`GridPaging.columns`, CompanionPaging.kt:54-58): the buttons add [chrome] to their label and [gap] separates
    /// them. One column when even two do not fit.
    static func columns(labelWidths: [Double], width: Double, gap: Double, chrome: Double, max: Int) -> Int {
        let widest = (labelWidths.max() ?? 0) + chrome
        if max >= 2 {
            for columns in stride(from: max, through: 2, by: -1) where (width - gap * Double(columns - 1)) / Double(columns) >= widest {
                return columns
            }
        }
        return 1
    }

    /// The entries of page [page] (clamped to the plan's pages) of [count] entries.
    static func range(page: Int, plan: CompanionGridPlan, count: Int) -> Range<Int> {
        let current = min(max(page, 0), plan.pages - 1)
        let start = min(current * plan.perPage, count)
        return start..<min(start + plan.perPage, count)
    }
}

/// One entry of a ``CompanionPagedGrid`` (`GridItem`, CompanionPaging.kt:62): a touch button that runs [run] (the stream
/// menu's own handler); [selected] gives it the accent outline.
struct CompanionGridEntry {
    let label: String
    var icon: String?
    var selected = false
    var enabled = true
    let run: @MainActor () -> Void
}

/// The entries as a grid that fills the room it gets (`PagedGrid`, CompanionPaging.kt:69-98): [maxColumns] at most, fewer
/// when the longest label does not fit, one page when everything fits and Previous / Next with the page count otherwise.
struct CompanionPagedGrid: View {
    let entries: [CompanionGridEntry]
    var maxColumns = 3
    @State private var page = 0
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        let fit = CompanionFitContext(stage: stage)
        let widths = entries.map { fit.metrics.width($0.label) + ($0.icon == nil ? 0 : CompanionGridPaging.iconFit) }
        let columns = CompanionGridPaging.columns(
            labelWidths: widths, width: fit.budget.innerWidth, gap: CompanionGridPaging.gap, chrome: CompanionGridPaging.buttonChrome, max: maxColumns)
        GeometryReader { proxy in
            let plan = CompanionGridPaging.plan(
                height: proxy.size.height / stage.scale, rowHeight: CompanionFit.minTarget, gap: CompanionGridPaging.gap, columns: columns,
                count: entries.count)
            let current = min(max(page, 0), plan.pages - 1)
            let shown = Array(entries[CompanionGridPaging.range(page: current, plan: plan, count: entries.count)])
            let rows = stride(from: 0, to: shown.count, by: columns).map { Array(shown[$0..<min($0 + columns, shown.count)]) }
            VStack(spacing: stage.px(CompanionGridPaging.gap)) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: stage.px(CompanionGridPaging.gap)) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, entry in
                            CompanionButton(
                                label: entry.label, icon: entry.icon, selected: entry.selected, enabled: entry.enabled, textSize: CompanionFit.minText,
                                action: entry.run)
                        }
                        ForEach(0..<(columns - row.count), id: \.self) { _ in Color.clear }
                    }
                    .frame(height: stage.px(CompanionFit.minTarget))
                }
                Spacer(minLength: 0)
                if plan.pager {
                    HStack(spacing: stage.px(CompanionGridPaging.gap)) {
                        CompanionButton(
                            label: L("companion_pager_previous"), icon: Symbols.chevronLeft, enabled: current > 0, textSize: CompanionFit.minText
                        ) { page = current - 1 }
                        Text(verbatim: "\(current + 1) / \(plan.pages)")
                            .font(DelosFonts.figtree(stage.tpx(CompanionFit.minText)).monospacedDigit())
                            .foregroundStyle(colors.text2.color)
                            .lineLimit(1)
                            .fixedSize()
                        CompanionButton(
                            label: L("companion_pager_next"), icon: Symbols.chevronRight, enabled: current < plan.pages - 1,
                            textSize: CompanionFit.minText
                        ) { page = current + 1 }
                    }
                    .frame(height: stage.px(CompanionFit.minTarget))
                }
            }
        }
    }
}
