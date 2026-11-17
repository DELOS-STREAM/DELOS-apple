import DelosData
import SwiftUI

// The filter strip, the filter sheet and the chips of the Artwork screen (`FilterStrip`, `FilterSheetLayer` and `FilterChip`
// of ArtworkScreen.kt / FilterModal.kt of DELOS for Android).

// MARK: Gliding focus ring

/// The frame (in ``ChipGlideHost``'s space) of the chip that has the focus.
private struct ChipGlideKey: PreferenceKey {
    static var defaultValue: CGRect? { nil }
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

/// The one focus ring of a row of chips (`RowGlideHost(ring = FocusRing(3f, 3f), corner = 999f, focusScale = 1.05f, fill = null,
/// glow = null)`): it glides from chip to chip (520 ms on the glide curve) instead of each chip fading its own; the first
/// focus and reduced motion do not glide, and when the focus leaves the chips it waits 70 ms for the next one, then fades.
struct ChipGlideHost<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .coordinateSpace(name: "chipGlide")
            .backgroundPreferenceValue(ChipGlideKey.self) { frame in GlideRing(target: frame) }
    }
}

private struct GlideRing: View {
    let target: CGRect?
    @State private var previous: CGRect?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced

    var body: some View {
        Group {
            if let frame = target ?? previous {
                // The ring sits 3 px outside the chip as it grows by 5 %, and is 3 px wide
                let grown = CGSize(width: frame.width * ArtChipLook.focusScale, height: frame.height * ArtChipLook.focusScale)
                let outside = stage.px(2 * ArtChipLook.ring)
                Capsule()
                    .strokeBorder(colors.accent.color, lineWidth: stage.px(ArtChipLook.ring))
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

enum ArtChipLook {
    static let focusScale = 1.05
    static let ring = 3.0
}

private struct ChipScaleState: Equatable {
    let focused: Bool
    let pressed: Bool
}

private struct ChipFocus: ViewModifier {
    let focused: Bool
    @Environment(\.reducedMotion) private var reduced
    @Environment(\.pressed) private var pressed

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ChipGlideKey.self, value: focused ? proxy.frame(in: .named("chipGlide")) : nil)
                }
            }
            .scaleEffect(focusScale(focused: focused, pressed: pressed, focus: ArtChipLook.focusScale))
            .animation(.focusScale(pressed: pressed, reduced: reduced), value: ChipScaleState(focused: focused, pressed: pressed))
            .zIndex(focused ? 1 : 0)
    }
}

// MARK: Pieces

/// A selectable chip (`FilterChip`): filled with the accent while chosen, glass otherwise; the gliding ring marks the cursor.
struct ArtChip: View {
    let label: String
    let selected: Bool
    let focused: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        Text(label)
            .font(DelosFonts.figtree(stage.tpx(24), .semibold))
            .foregroundStyle((selected ? colors.onAccent : colors.text).color)
            .lineLimit(1)
            .padding(.horizontal, stage.px(30))
            .padding(.vertical, stage.px(12))
            .frame(minHeight: stage.px(60))
            .background {
                if selected {
                    Capsule().fill(colors.accent.color)
                } else {
                    GlassShape(Capsule(), tint: colors.surface).overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                }
            }
            .modifier(ChipFocus(focused: focused))
    }
}

/// A removable chip of the filter strip (`FilterStripChip`): its label and the symbol of what A does.
struct ArtStripChip: View {
    let label: String
    let icon: String
    let focused: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(10)) {
            Text(label)
                .font(DelosFonts.figtree(stage.tpx(20), .semibold))
                .foregroundStyle(colors.text.color)
                .lineLimit(1)
            SymbolView(symbol: icon, size: 22, color: colors.text2)
        }
        .padding(.horizontal, stage.px(20))
        .frame(height: stage.px(44))
        .background { Capsule().fill(colors.surface2.color).overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1))) }
        .modifier(ChipFocus(focused: focused))
    }
}

/// The accent count of active filters on the Filter pill (`CountBadge`).
struct ArtCountBadge: View {
    let count: Int
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        Text("\(count)")
            .font(DelosFonts.figtree(stage.tpx(18), .bold))
            .foregroundStyle(colors.onAccent.color)
            .frame(width: stage.px(32), height: stage.px(32))
            .background(Circle().fill(colors.accent.color))
    }
}

/// The button a hint stands for (`GlyphButton`): a circle in the text color with the letter in the background color.
struct ArtGlyph: View {
    let letter: String
    var size = 32.0
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        Text(letter)
            .font(DelosFonts.figtree(stage.tpx(21 * size / 38), .heavy))
            .foregroundStyle(colors.bg.color)
            .frame(width: stage.px(size), height: stage.px(size))
            .background(Circle().fill(colors.text.color))
    }
}

// MARK: Strip

/// "10 of 41 covers" and the active filters as chips (A removes one, Reset removes them all); without a filter, the sort
/// (`FilterStrip`).
struct ArtworkFilterStrip: View {
    let tab: ArtworkTab
    let filters: ArtFilters
    let images: Int
    let total: Int?
    let refreshing: Bool
    let focus: FocusModel
    let onClear: (ActiveFilter) -> Void
    let onReset: () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    static func chipID(_ chip: ActiveFilter) -> String { "art-chip-\(chip)" }
    static let resetID = "art-chip-reset"

    var body: some View {
        let tint = filters.active ? colors.accent : colors.accent2
        ChipGlideHost {
            HStack(spacing: stage.px(12)) {
                Text(tab.resultLine(shown: images, total: total, all: !filters.active))
                    .font(DelosFonts.figtree(stage.tpx(20), .semibold))
                    .foregroundStyle(colors.accent3.color)
                    .lineLimit(1)
                    .padding(.horizontal, stage.px(20))
                    .padding(.vertical, stage.px(7))
                    .background {
                        Capsule().fill(tint.opacity(0.14).color)
                            .overlay(Capsule().strokeBorder(tint.opacity(0.45).color, lineWidth: stage.px(1)))
                    }
                if refreshing { RingSpinner(size: 26) }
                if !filters.active {
                    Text(filters.sort.first)
                        .font(DelosFonts.figtree(stage.tpx(21)))
                        .foregroundStyle(colors.text3.color)
                        .lineLimit(1)
                } else {
                    ForEach(ArtFilterRules.chips(filters), id: \.self) { chip in
                        FocusItem(id: Self.chipID(chip), model: focus, action: { onClear(chip) }) { focused in
                            ArtStripChip(label: chip.label, icon: Symbols.close, focused: focused)
                        }
                    }
                    FocusItem(id: Self.resetID, model: focus, action: onReset) { focused in
                        ArtStripChip(label: L("filters_art_chips_reset"), icon: Symbols.reset, focused: focused)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, stage.px(3))
        }
    }
}

// MARK: Sheet

/// What the filter sheet needs from its screen.
struct ArtworkFilterSheetState {
    let tab: ArtworkTab
    let filters: ArtFilters
    let images: Int?
    let total: Int?
    let refreshing: Bool
}

/// The filter sheet (Y or the Filter pill; `FilterSheetLayer`): a panel with the type, style, dimensions and sort options
/// of the tab's kind and the live count, Reset and Done in its header. The options apply at once.
struct ArtworkFilterSheet: View {
    let state: ArtworkFilterSheetState
    let focus: FocusModel
    let onChange: (ArtFilters) -> Void
    let onReset: () -> Void
    let onClose: () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    static let resetID = "art-sheet-reset"
    static let doneID = "art-sheet-done"
    static func optionID(_ key: String) -> String { "art-sheet-\(key)" }

    /// The option the focus starts on: the first row's selected one.
    static func startID(kind: ArtKind, filters: ArtFilters) -> String {
        optionID(ArtFilterRules.hasType(kind) ? "type:\(filters.type.rawValue)" : "style:\(filters.style ?? "")")
    }

    var body: some View {
        let kind = state.tab.kind
        let filters = state.filters
        let shape = RoundedRectangle(cornerRadius: stage.px(40), style: .continuous)
        VStack(alignment: .leading, spacing: stage.px(8)) {
            HStack(spacing: stage.px(24)) {
                Text(L("filters_art_title"))
                    .font(DelosFonts.unbounded(stage.tpx(34)))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
                if let images = state.images {
                    Text(state.tab.resultLine(shown: images, total: state.total, all: false))
                        .font(DelosFonts.figtree(stage.tpx(22), .semibold))
                        .foregroundStyle(colors.accent3.color)
                        .lineLimit(1)
                        .padding(.horizontal, stage.px(22))
                        .padding(.vertical, stage.px(8))
                        .background {
                            Capsule().fill(colors.accent.opacity(0.16).color)
                                .overlay(Capsule().strokeBorder(colors.accent.opacity(0.45).color, lineWidth: stage.px(1)))
                        }
                }
                if state.refreshing { RingSpinner(size: 30) }
                Spacer(minLength: 0)
                resetPill(active: filters.active)
                FocusItem(id: Self.doneID, model: focus, clickCue: .back, action: onClose) { focused in
                    ToolbarPill(label: L("filters_art_done"), icon: Symbols.check, focused: focused, glyph: "Y")
                }
            }
            .padding(.bottom, stage.px(8))
            ChipGlideHost {
                VStack(alignment: .leading, spacing: stage.px(6)) {
                    if ArtFilterRules.hasType(kind) {
                        row(icon: Symbols.movie, title: L("filters_art_row_type")) {
                            ForEach(ArtType.allCases, id: \.self) { type in
                                chip(type.label, selected: filters.type == type, key: "type:\(type.rawValue)") {
                                    var next = filters
                                    next.type = type
                                    onChange(next)
                                }
                            }
                        }
                        divider
                    }
                    row(icon: Symbols.style, title: L("filters_art_row_style")) {
                        chip(L("filters_art_any"), selected: filters.style == nil, key: "style:") {
                            var next = filters
                            next.style = nil
                            onChange(next)
                        }
                        ForEach(ArtFilterRules.styles(kind), id: \.self) { style in
                            chip(ArtworkFact.styleLabel(style), selected: filters.style == style, key: "style:\(style)") {
                                var next = filters
                                next.style = style
                                onChange(next)
                            }
                        }
                    }
                    if !ArtFilterRules.dimensions(kind).isEmpty {
                        divider
                        row(icon: Symbols.dimensions, title: L("filters_art_row_dimensions")) {
                            chip(L("filters_art_any"), selected: filters.dimensions == nil, key: "dimensions:") {
                                var next = filters
                                next.dimensions = nil
                                onChange(next)
                            }
                            ForEach(ArtFilterRules.dimensions(kind), id: \.self) { dimensions in
                                chip(ArtFilterRules.dimensionsLabel(dimensions), selected: filters.dimensions == dimensions, key: "dimensions:\(dimensions)") {
                                    var next = filters
                                    next.dimensions = dimensions
                                    onChange(next)
                                }
                            }
                        }
                    }
                    divider
                    row(icon: Symbols.sort, title: L("filters_art_row_sort")) {
                        ForEach(ArtSort.allCases, id: \.self) { sort in
                            chip(sort.label, selected: filters.sort == sort, key: "sort:\(sort.rawValue)") {
                                var next = filters
                                next.sort = sort
                                onChange(next)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, stage.px(40))
        .padding(.top, stage.px(26))
        .padding(.bottom, stage.px(22))
        .background {
            GlassShape(shape, tint: colors.surface3, role: .panel)
                .overlay(shape.strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                // A tap on the panel stays on it; a tap beside it reaches the scrim
                .contentShape(shape)
                .onTapGesture {}
        }
    }

    @ViewBuilder private func resetPill(active: Bool) -> some View {
        if active {
            FocusItem(id: Self.resetID, model: focus, clickCue: nil, action: onReset) { focused in
                ToolbarPill(label: L("filters_art_reset"), icon: Symbols.reset, focused: focused, glyph: "X")
            }
        } else {
            ToolbarPill(label: L("filters_art_reset"), icon: Symbols.reset, focused: false, glyph: "X").opacity(0.4)
        }
    }

    private func chip(_ label: String, selected: Bool, key: String, action: @escaping () -> Void) -> some View {
        FocusItem(id: Self.optionID(key), model: focus, action: action) { focused in
            ArtChip(label: label, selected: selected, focused: focused)
        }
    }

    private var divider: some View {
        Rectangle().fill(colors.line.color).frame(height: stage.px(1))
    }

    /// An icon on an accent disc and the row's name, then its options (`SheetRow`).
    private func row<Options: View>(icon: String, title: String, @ViewBuilder options: @escaping () -> Options) -> some View {
        HStack(spacing: stage.px(30)) {
            HStack(spacing: stage.px(18)) {
                SymbolView(symbol: icon, size: 28, color: colors.accent2, filled: true)
                    .frame(width: stage.px(52), height: stage.px(52))
                    .background(Circle().fill(colors.accent.opacity(0.18).color))
                Text(title)
                    .font(DelosFonts.unbounded(stage.tpx(26)))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
            }
            .frame(width: stage.px(270), alignment: .leading)
            FocusScroll(axis: .horizontal) {
                HStack(spacing: stage.px(14)) { options() }
                    .padding(.horizontal, stage.px(12))
                    .padding(.vertical, stage.px(12))
            }
            .scrollClipDisabled()
        }
        .padding(.vertical, stage.px(2))
    }
}
