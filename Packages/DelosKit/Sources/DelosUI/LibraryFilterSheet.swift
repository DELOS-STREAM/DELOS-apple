import DelosData
import DelosInput
import SwiftUI

// The library filter (`FilterModal.kt` of DELOS for Android): a centered glass panel with the genre, theme, HDR support and
// duration chips and the live count, Reset and "Show N apps" in its footer. A chip toggles its value; values in one row
// combine with OR, rows with AND. The library changes only when the choices are confirmed (the pill, Y, Return on a chip).

/// What the filter sheet needs from the home screen.
struct LibraryFilterState {
    /// The choices of the open sheet (not applied yet).
    let filters: MetadataFilters
    /// The metadata of every game of the library, in the library's order (nil: not known yet).
    let games: [GameMetadata?]
    /// How many of them the choices let through.
    let matching: Int
}

/// Where the focus goes in the sheet, and which section a focused item belongs to.
enum LibraryFilterIDs {
    static func genre(_ id: Int?) -> String { "filter-genre-\(id.map(String.init) ?? "all")" }
    static func theme(_ id: Int?) -> String { "filter-theme-\(id.map(String.init) ?? "all")" }
    static func hdr(_ filter: HDRFilter?) -> String { "filter-hdr-\(filter?.rawValue ?? "any")" }
    static func length(_ filter: LengthFilter?) -> String { "filter-length-\(filter?.rawValue ?? "any")" }
    static let reset = "filter-reset"
    static let show = "filter-show"
    /// The reset row of the filtered-empty state.
    static let emptyReset = "filter-empty-reset"

    /// The option the focus starts on: the first selected genre among the chips, else "All".
    static func start(_ filters: MetadataFilters, genres: [GameGenre]) -> String {
        genre(genres.first { filters.genres.contains($0.id) }?.id)
    }

    /// The section (0 genre, 1 theme, 2 HDR, 3 duration) the item [id] is in; nil for the footer's buttons.
    static func section(of id: AnyHashable?) -> Int? {
        guard let id = id as? String else { return nil }
        for (index, prefix) in ["filter-genre-", "filter-theme-", "filter-hdr-", "filter-length-"].enumerated() where id.hasPrefix(prefix) { return index }
        return nil
    }
}

struct LibraryFilterSheet: View {
    let state: LibraryFilterState
    let focus: FocusModel
    /// Changes the choices in place: a second press before the sheet is drawn again builds on the first.
    let onEdit: ((inout MetadataFilters) -> Void) -> Void
    let onReset: () -> Void
    let onConfirm: () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @State private var contentHeight = 0.0
    @State private var headerHeight = 0.0
    @State private var footerHeight = 0.0

    /// The compact stage's smaller numbers (`cpx`).
    private var k: Double { stage.compactScale }

    var body: some View {
        let filters = state.filters
        let games = state.games
        let genres = LibraryFilter.genres(games)
        let themes = LibraryFilter.themes(games)
        let genreCounts = LibraryFilter.genreCounts(games)
        let themeCounts = LibraryFilter.themeCounts(games)
        let shape = RoundedRectangle(cornerRadius: stage.px(34), style: .continuous)
        // 820 at 1080: a taller stage gives the chips more room, a shorter one less (the compact one keeps clear of the bars)
        let maxHeight = max(stage.height - (stage.compact ? 220 : 260), 0)
        // The header, the footer and the panel's padding stay; the chips scroll in what is left (points)
        let chrome = headerHeight + footerHeight + stage.px(44 * k) + stage.px(44)
        let scrollMax = max(stage.px(maxHeight) - chrome, 0)
        VStack(spacing: 0) {
            header(filters)
                .padding(.horizontal, stage.px(12))
                .padding(.bottom, stage.px(26 * k))
                .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { headerHeight = $0 }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    ChipGlideHost {
                        VStack(alignment: .leading, spacing: stage.px(LibraryFilterLayout.sectionGap * k)) {
                            section(0, Symbols.genreUnknown, L("filters_section_genre")) {
                                chip(L("filters_all"), selected: filters.genres.isEmpty, id: LibraryFilterIDs.genre(nil), count: games.count) {
                                    change { $0.genres = [] }
                                }
                                ForEach(genres, id: \.id) { genre in
                                    chip(TagLook.genreName(genre), selected: filters.genres.contains(genre.id), id: LibraryFilterIDs.genre(genre.id),
                                         icon: TagLook.genreIcon(genre.id), count: genreCounts[genre.id] ?? 0) {
                                        change { $0.toggleGenre(genre.id) }
                                    }
                                }
                            }
                            divider
                            // Without any theme in the library there is nothing to choose (a theme that was chosen stays visible)
                            if !themes.isEmpty || !filters.themes.isEmpty {
                                section(1, Symbols.themes, L("filters_section_theme")) {
                                    chip(L("filters_all"), selected: filters.themes.isEmpty, id: LibraryFilterIDs.theme(nil), count: games.count) {
                                        change { $0.themes = [] }
                                    }
                                    ForEach(themes, id: \.id) { theme in
                                        chip(TagLook.themeName(theme), selected: filters.themes.contains(theme.id), id: LibraryFilterIDs.theme(theme.id),
                                             icon: TagLook.themeIcon(theme.id), count: themeCounts[theme.id] ?? 0) {
                                            change { $0.toggleTheme(theme.id) }
                                        }
                                    }
                                }
                                divider
                            }
                            section(2, Symbols.hdrOn, L("filters_section_hdr")) {
                                chip(L("filters_hdr_any"), selected: filters.hdr.isEmpty, id: LibraryFilterIDs.hdr(nil)) {
                                    change { $0.hdr = [] }
                                }
                                ForEach(HDRFilter.allCases, id: \.self) { option in
                                    chip(LibraryFilter.hdrLabel(option), selected: filters.hdr.contains(option), id: LibraryFilterIDs.hdr(option),
                                         icon: LibraryFilter.hdrIcon(option)) {
                                        change { $0.toggleHDR(option) }
                                    }
                                }
                            }
                            divider
                            // The last row: one press down reaches the pill that applies the choices, wherever the focus is in the row
                            section(3, Symbols.completionTime, L("filters_section_duration")) {
                                chip(L("filters_length_any"), selected: filters.length.isEmpty, id: LibraryFilterIDs.length(nil), down: LibraryFilterIDs.show) {
                                    change { $0.length = [] }
                                }
                                ForEach(LengthFilter.allCases, id: \.self) { option in
                                    chip(LibraryFilter.lengthLabel(option), selected: filters.length.contains(option), id: LibraryFilterIDs.length(option),
                                         down: LibraryFilterIDs.show) {
                                        change { $0.toggleLength(option) }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, stage.px(12))
                        .padding(.top, stage.px(24 * k))
                        .padding(.bottom, stage.px(48 * k))
                        .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { contentHeight = $0 }
                    }
                    .focusDrivenScroll()
                }
                // What does not fit is cut at the scroll area's edge (the rows keep 12 px at each side for their ring) and fades
                // where sections go on behind it (`fadeEdges(stage, chipScroll, 20f, 40f)`); only the edge with sections
                // behind it fades, and the mask reaches far beyond the sides, so no chip, label or ring at rest is dimmed or cut
                .scrollEdgeFade(.vertical, FadeEdges(start: FadeEdge(solid: 20), end: FadeEdge(solid: 40)))
                .frame(height: min(contentHeight, scrollMax))
                // The section of the focused chip glides to the middle; read apart, so a move of the focus does not rebuild
                // every chip of the sheet
                .onFocusChange(focus) { now in
                    guard let section = LibraryFilterIDs.section(of: now), !focus.pointerMoved else { return }
                    withAnimation(SettingsScrollMotion.animation(distance: 0)) { proxy.scrollTo("filter-section-\(section)", anchor: .center) }
                }
            }
            footer(active: filters.active)
                .padding(.top, stage.px(30 * k))
                .padding(.horizontal, stage.px(12))
                .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { footerHeight = $0 }
        }
        .padding(.horizontal, stage.px(40))
        .padding(.top, stage.px(44 * k))
        .padding(.bottom, stage.px(44))
        .frame(width: stage.px(stage.compact ? stage.width - 2 * 48 : min(1240, stage.width - 60)))
        .background {
            GlassShape(shape, tint: colors.surface3, role: .panel)
                .overlay(shape.strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                // box-shadow: 0 40px 100px -30px rgba(0, 0, 0, .7), like the dialogs
                .background { shape.fill(.black.opacity(0.7)).padding(stage.px(30)).blur(radius: stage.px(50)).offset(y: stage.px(40)) }
                // A tap on the panel stays on it; a tap beside it reaches the scrim
                .contentShape(shape)
                .onTapGesture {}
        }
    }

    private func change(_ edit: (inout MetadataFilters) -> Void) {
        onEdit(edit)
    }

    private func header(_ filters: MetadataFilters) -> some View {
        HStack(spacing: stage.px(24)) {
            Text(L("filters_title"))
                .font(DelosFonts.unbounded(stage.tpx(40)))
                .foregroundStyle(colors.text.color)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(LibraryFilter.resultLine(shown: state.matching, total: state.games.count, active: filters.active))
                .font(DelosFonts.figtree(stage.tpx(24), .semibold))
                .foregroundStyle((filters.active ? colors.accent3 : colors.text2).color)
                .lineLimit(1)
                .padding(.horizontal, stage.px(26))
                .padding(.vertical, stage.px(10))
                .background {
                    Capsule().fill((filters.active ? colors.accent.opacity(0.16) : colors.surface).color)
                        .overlay(Capsule().strokeBorder((filters.active ? colors.accent.opacity(0.45) : colors.line).color, lineWidth: stage.px(1)))
                }
        }
    }

    private func footer(active: Bool) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: stage.px(FocusSpacing.pillGap)) {
                if active {
                    FocusItem(id: LibraryFilterIDs.reset, model: focus, clickCue: nil, action: onReset) { focused in
                        pill(L("filters_reset"), Symbols.reset, focused: focused, primary: false)
                    }
                } else {
                    pill(L("filters_reset"), Symbols.reset, focused: false, primary: false).opacity(0.4)
                }
                // The confirm cue comes from [onConfirm], which also closes the sheet
                FocusItem(id: LibraryFilterIDs.show, model: focus, clickCue: nil, action: onConfirm) { focused in
                    pill(LibraryFilter.showLabel(matching: state.matching), Symbols.check, focused: focused, primary: true)
                }
            }
        }
    }

    @ViewBuilder private func pill(_ label: String, _ icon: String, focused: Bool, primary: Bool) -> some View {
        if stage.compact {
            ToolbarPill(label: label, icon: icon, focused: focused)
        } else {
            PillButton(label: label, icon: icon, primary: primary, focused: focused)
        }
    }

    private var divider: some View {
        Rectangle().fill(colors.line.color).frame(height: stage.px(1))
    }

    /// An icon on an accent disc and the section's name, then its chips in one row that scrolls sideways.
    private func section<Chips: View>(_ index: Int, _ icon: String, _ title: String, @ViewBuilder chips: @escaping () -> Chips) -> some View {
        VStack(alignment: .leading, spacing: stage.px(LibraryFilterLayout.headingGap * k)) {
            HStack(spacing: stage.px(18)) {
                SymbolView(symbol: icon, size: 32, color: colors.accent2, filled: true)
                    .frame(width: stage.px(LibraryFilterLayout.headingHeight * k), height: stage.px(LibraryFilterLayout.headingHeight * k))
                    .background(Circle().fill(colors.accent.opacity(0.18).color))
                Text(title)
                    .font(DelosFonts.unbounded(stage.tpx(29)))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
            }
            FocusScroll(axis: .horizontal) {
                // The chips keep their own width: the row scrolls instead of squeezing a label. Their gap does not shrink on a
                // compact stage, where the chips keep their height and their text
                HStack(spacing: stage.px(LibraryFilterLayout.chipGap)) { chips() }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, stage.px(12))
                    .padding(.vertical, stage.px(LibraryFilterLayout.chipPadding))
            }
            .scrollClipDisabled()
        }
        .id("filter-section-\(index)")
    }

    private func chip(
        _ label: String, selected: Bool, id: String, icon: String? = nil, count: Int? = nil, down: String? = nil, action: @escaping () -> Void
    ) -> some View {
        FocusItem(id: id, model: focus, moves: down.map { [.down: AnyHashable($0)] } ?? [:], action: action) { focused in
            LibraryFilterChip(label: label, selected: selected, focused: focused, icon: icon, count: count)
        }
    }
}

/// The gaps of the filter sheet, stage pixels (``FocusSpacing``).
enum LibraryFilterLayout {
    /// The widest chip in any language: "4X" with IGDB's explanation, its icon and its count, about 740 px in Brazilian
    /// Portuguese at 1080.
    static let chipMaxWidth = 740.0
    /// Between two chips of a row: the gliding ring (``GlideLook/chip``, 5 % growth, 3 px ring 3 px out, not scaled)
    /// reaches 24.5 px beyond a chip as wide as ``chipMaxWidth``.
    static let chipGap = FocusSpacing.gap(reach: GlideLook.chip.reach(width: chipMaxWidth)).rounded(.up)
    /// Vertical chip clearance also includes the next section's heading, its gap and both rows' padding.
    static let sectionGap = 34.0, headingHeight = 60.0, headingGap = 22.0, chipPadding = 12.0
}

/// A selectable chip (`FilterChip`): filled with the accent while chosen, the flat surface tint otherwise, with its icon and
/// the number of games it holds; the gliding ring marks the cursor.
struct LibraryFilterChip: View {
    let label: String
    let selected: Bool
    let focused: Bool
    var icon: String?
    var count: Int?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        let content = selected ? colors.onAccent : colors.text
        HStack(spacing: stage.px(10)) {
            if let icon { SymbolView(symbol: icon, size: 28, color: content, filled: selected || focused) }
            Text(label)
                .font(DelosFonts.figtree(stage.tpx(24), .semibold))
                .foregroundStyle(content.color)
                .lineLimit(1)
                .fixedSize()
            if let count {
                Text("\(count)")
                    .font(DelosFonts.figtree(stage.tpx(22)))
                    .foregroundStyle(content.opacity(0.6).color)
            }
        }
        .padding(.horizontal, stage.px(30 * stage.compactScale))
        .padding(.vertical, stage.px(12 * stage.compactScale))
        .frame(minHeight: stage.px(60))
        .background {
            if selected {
                Capsule().fill(colors.accent.color)
            } else {
                // Android's `glass(surface)` is the flat tint inside an overlay (no backdrop there): a darker pill than the
                // panel with a faint 1 px line. Liquid glass would lift it brighter than the panel and rim it with light
                Capsule().fill(colors.surface.color).overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
            }
        }
        .modifier(ChipFocus(focused: focused))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
