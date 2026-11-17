import DelosData
import DelosInput
import SwiftUI

// The library filter (`FilterModal.kt` of DELOS for Android): a centered glass panel with the genre, theme, HDR support and
// duration chips and the live count, Reset and Done in its footer. The choices apply at once.

/// What the filter sheet needs from the home screen.
struct LibraryFilterState {
    let filters: MetadataFilters
    /// The metadata of every game of the library, in the library's order (nil: not known yet).
    let games: [GameMetadata?]
    /// How many of them the filters let through.
    let matching: Int
}

/// Where the focus goes in the sheet, and which section a focused item belongs to.
enum LibraryFilterIDs {
    static func genre(_ id: Int?) -> String { "filter-genre-\(id.map(String.init) ?? "all")" }
    static func theme(_ id: Int?) -> String { "filter-theme-\(id.map(String.init) ?? "all")" }
    static func hdr(_ filter: HDRFilter) -> String { "filter-hdr-\(filter.rawValue)" }
    static func length(_ filter: LengthFilter) -> String { "filter-length-\(filter.rawValue)" }
    static let reset = "filter-reset"
    static let done = "filter-done"
    /// The home screen's filter button.
    static let button = "library-filter"
    /// The reset row of the filtered-empty state.
    static let emptyReset = "filter-empty-reset"

    /// The option the focus starts on: the selected genre (it must be one of the chips), else "All".
    static func start(_ filters: MetadataFilters, genres: [GameGenre]) -> String {
        genre(filters.genreID.flatMap { id in genres.contains { $0.id == id } ? id : nil })
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
    let onChange: (MetadataFilters) -> Void
    let onReset: () -> Void
    let onClose: () -> Void
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
                    LibraryChipGlideHost {
                        VStack(alignment: .leading, spacing: stage.px(34 * k)) {
                            section(0, Symbols.genreUnknown, L("filters_section_genre")) {
                                chip(L("filters_all"), selected: filters.genreID == nil, id: LibraryFilterIDs.genre(nil), count: games.count) {
                                    change { $0.genreID = nil }
                                }
                                ForEach(genres, id: \.id) { genre in
                                    chip(TagLook.genreName(genre), selected: filters.genreID == genre.id, id: LibraryFilterIDs.genre(genre.id),
                                         icon: TagLook.genreIcon(genre.id), count: genreCounts[genre.id] ?? 0) {
                                        change { $0.genreID = genre.id }
                                    }
                                }
                            }
                            divider
                            // Without any theme in the library there is nothing to choose (a theme that was chosen stays visible)
                            if !themes.isEmpty || filters.themeID != nil {
                                section(1, Symbols.themes, L("filters_section_theme")) {
                                    chip(L("filters_all"), selected: filters.themeID == nil, id: LibraryFilterIDs.theme(nil), count: games.count) {
                                        change { $0.themeID = nil }
                                    }
                                    ForEach(themes, id: \.id) { theme in
                                        chip(TagLook.themeName(theme), selected: filters.themeID == theme.id, id: LibraryFilterIDs.theme(theme.id),
                                             icon: TagLook.themeIcon(theme.id), count: themeCounts[theme.id] ?? 0) {
                                            change { $0.themeID = theme.id }
                                        }
                                    }
                                }
                                divider
                            }
                            section(2, Symbols.hdrOn, L("filters_section_hdr")) {
                                ForEach([HDRFilter.any, .hdr, .sdr, .unknown], id: \.self) { option in
                                    chip(LibraryFilter.hdrLabel(option), selected: filters.hdr == option, id: LibraryFilterIDs.hdr(option),
                                         icon: LibraryFilter.hdrIcon(option)) {
                                        change { $0.hdr = option }
                                    }
                                }
                            }
                            divider
                            section(3, Symbols.completionTime, L("filters_section_duration")) {
                                ForEach([LengthFilter.any, .under10, .from10To30, .from30To60, .over60, .unknown], id: \.self) { option in
                                    chip(LibraryFilter.lengthLabel(option), selected: filters.length == option, id: LibraryFilterIDs.length(option)) {
                                        change { $0.length = option }
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
                // What does not fit is cut at the scroll area's edge (the rows keep 12 px at each side for their ring)
                .frame(height: min(contentHeight, scrollMax))
                .onChange(of: focus.focused) { _, now in
                    guard let section = LibraryFilterIDs.section(of: now) else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("filter-section-\(section)", anchor: .center) }
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
        var next = state.filters
        edit(&next)
        onChange(next)
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
        HStack(spacing: stage.px(24)) {
            Spacer(minLength: 0)
            if active {
                FocusItem(id: LibraryFilterIDs.reset, model: focus, clickCue: nil, action: onReset) { focused in
                    pill(L("filters_reset"), Symbols.reset, focused: focused, primary: false)
                }
            } else {
                pill(L("filters_reset"), Symbols.reset, focused: false, primary: false).opacity(0.4)
            }
            FocusItem(id: LibraryFilterIDs.done, model: focus, clickCue: .back, action: onClose) { focused in
                pill(L("filters_done"), Symbols.check, focused: focused, primary: true)
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
        VStack(alignment: .leading, spacing: stage.px(22 * k)) {
            HStack(spacing: stage.px(18)) {
                SymbolView(symbol: icon, size: 32, color: colors.accent2, filled: true)
                    .frame(width: stage.px(60 * k), height: stage.px(60 * k))
                    .background(Circle().fill(colors.accent.opacity(0.18).color))
                Text(title)
                    .font(DelosFonts.unbounded(stage.tpx(29)))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
            }
            FocusScroll(axis: .horizontal) {
                // The chips keep their own width: the row scrolls instead of squeezing a label
                HStack(spacing: stage.px(14 * k)) { chips() }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, stage.px(12))
                    .padding(.vertical, stage.px(12))
            }
            .scrollClipDisabled()
        }
        .id("filter-section-\(index)")
    }

    private func chip(_ label: String, selected: Bool, id: String, icon: String? = nil, count: Int? = nil, action: @escaping () -> Void) -> some View {
        FocusItem(id: id, model: focus, action: action) { focused in
            LibraryFilterChip(label: label, selected: selected, focused: focused, icon: icon, count: count)
        }
    }
}

/// A selectable chip (`FilterChip`): filled with the accent while chosen, glass otherwise, with its icon and the number of
/// games it holds; the gliding ring marks the cursor.
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
                GlassShape(Capsule(), tint: colors.surface).overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
            }
        }
        .modifier(LibraryChipFocus(focused: focused))
    }
}

// MARK: Gliding focus ring

/// The frame (in ``LibraryChipGlideHost``'s space) of the chip that has the focus.
private struct LibraryChipGlideKey: PreferenceKey {
    static var defaultValue: CGRect? { nil }
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

private struct LibraryChipFocus: ViewModifier {
    let focused: Bool
    @Environment(\.reducedMotion) private var reduced
    @Environment(\.pressed) private var pressed

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: LibraryChipGlideKey.self, value: focused ? proxy.frame(in: .named("libraryChipGlide")) : nil)
                }
            }
            .scaleEffect(focusScale(focused: focused, pressed: pressed, focus: GlideLook.chip.scale))
            .animation(.focusScale(pressed: pressed, reduced: reduced), value: [focused, pressed])
            .zIndex(focused ? 1 : 0)
    }
}

/// The one focus ring of the sheet's rows of chips (`RowGlideHost(ring = FocusRing(3f, 3f), corner = 999f, focusScale = 1.05f)`):
/// it glides from chip to chip, also from one row to the next, instead of each chip fading its own. The first focus and
/// reduced motion do not glide, and when the focus leaves the chips it waits 70 ms for the next one, then fades.
struct LibraryChipGlideHost<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .coordinateSpace(name: "libraryChipGlide")
            .backgroundPreferenceValue(LibraryChipGlideKey.self) { frame in LibraryChipGlideRing(target: frame) }
    }
}

private struct LibraryChipGlideRing: View {
    let target: CGRect?
    @State private var previous: CGRect?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced

    var body: some View {
        Group {
            if let frame = target ?? previous {
                let grown = CGSize(width: frame.width * GlideLook.chip.scale, height: frame.height * GlideLook.chip.scale)
                let outside = stage.px(2 * GlideLook.chip.ring)
                Capsule()
                    .strokeBorder(colors.accent.color, lineWidth: stage.px(GlideLook.chip.ring))
                    .frame(width: grown.width + 2 * outside, height: grown.height + 2 * outside)
                    .position(x: frame.midX, y: frame.midY)
                    .animation(reduced ? nil : .timingCurve(0.3, 1.22, 0.42, 1, duration: SettingsPlateGeometry.duration), value: target)
                    .opacity(target == nil ? 0 : 1)
                    .animation(
                        target == nil
                            ? .timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000).delay(0.07)
                            : .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.12),
                        value: target != nil)
            }
        }
        .onChange(of: target, initial: true) { _, frame in if let frame { previous = frame } }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: Home button

/// The filter button of the home screen, at the title row's end: the glass pill of the Artwork toolbar with the filter
/// symbol, its name, the number of criteria and Y's glyph; on a compact stage the symbol and the number alone.
struct LibraryFilterButton: View {
    let count: Int
    let focused: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    static let height = 64.0

    /// The width the title leaves free for the button and the air before it, stage pixels.
    static func reserve(compact: Bool) -> Double { compact ? 64 + 24 + 32 : 340 }

    var body: some View {
        HStack(spacing: stage.px(12)) {
            SymbolView(symbol: Symbols.filter, size: 30, color: colors.text, filled: focused || count > 0)
            if !stage.compact {
                Text(L("filters_hint"))
                    .font(DelosFonts.figtree(stage.tpx(24), .semibold))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
            }
            if count > 0 { ArtCountBadge(count: count) }
            if !stage.compact { GlyphButton(.north, size: 32) }
        }
        .padding(.horizontal, stage.px(stage.compact ? 16 : 28))
        .frame(minWidth: stage.px(Self.height), minHeight: stage.px(Self.height), maxHeight: stage.px(Self.height))
        .background {
            GlassShape(Capsule(), tint: colors.surface)
                .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
        .focusLook(focused, scale: 1.08, ring: 4, glowBlur: 50, glowY: 18)
        .accessibilityLabel(L("filters_hint"))
    }
}
