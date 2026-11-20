import DelosData
import DelosInput
import SwiftUI

// The filter strip, the filter sheet and the chips of the Artwork screen (`FilterStrip`, `FilterSheetLayer` and `FilterChip`
// of ArtworkScreen.kt / FilterModal.kt of DELOS for Android).

// MARK: Gliding focus ring

/// Which element has the focus, where its layout bounds are (in ``ChipGlideHost``'s space, without its focus scale) and the
/// scale it is at: the ring grows and shrinks with it (a press squeezes the element), on the same spring.
private struct ChipGlideTarget: Equatable {
    var id: UUID
    var frame: CGRect
    var scale: Double
}

private struct ChipGlideKey: PreferenceKey {
    static var defaultValue: ChipGlideTarget? { nil }
    static func reduce(value: inout ChipGlideTarget?, nextValue: () -> ChipGlideTarget?) { value = nextValue() ?? value }
}

/// How a gliding ring looks: the scale the focused element grows to (its layout bounds times [scale]), the ring's width, and
/// whether the element has a soft glow under it.
struct GlideLook: Equatable, Sendable {
    let scale: Double
    /// Stage px.
    let ring: Double
    let glow: Bool

    /// The chips of the filter strip and the sheet (`FocusRing(3f, 3f)`, `focusScale = 1.05f`, no glow).
    static let chip = GlideLook(scale: 1.05, ring: 3, glow: false)
    /// The toolbar's pills (`PillButton(compact = true)`: scale 1.08, ring 4, the glow of `focusLook`).
    static let pill = GlideLook(scale: 1.08, ring: 4, glow: true)
    /// The space between neighbouring pills (``FocusSpacing``): twice the reach of a focused pill up to ``pillMaxWidth``
    /// wide and the clear space.
    static let pillMaxWidth = 400.0, pillGap = 56.0
    /// The space between neighbouring chips of the Artwork screen, up to ``chipMaxWidth`` wide in any language (the longest,
    /// a sort chip of the strip, is about 370).
    static let chipMaxWidth = 400.0, chipGap = 40.0

    /// How far the focused element's ring reaches beyond its own layout bounds on each side (stage px): half of the growth
    /// and the band the ring lies in, which is twice its width.
    func reach(width: Double) -> Double { width * (scale - 1) / 2 + 2 * ring }
}

extension EnvironmentValues {
    /// The look of the ``ChipGlideHost`` an element is in; nil outside one (the element draws its own focus look).
    @Entry var glideLook: GlideLook?
}

/// The one focus ring of a row of chips or pills (`RowGlideHost(ring = FocusRing(3f, 3f), corner = 999f, focusScale = 1.05f,
/// fill = null, glow = null)`): it glides from element to element (520 ms on the glide curve) instead of each fading its own,
/// which showed two rings at once while the focus moved (one fading out, one fading in, and the one of the focused pill
/// reaching the pill beside it); the first focus and reduced motion do not glide, and when the focus leaves the elements it
/// waits 70 ms for the next one, then fades.
struct ChipGlideHost<Content: View>: View {
    var look = GlideLook.chip
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.glideLook, look)
            .coordinateSpace(name: "chipGlide")
            .backgroundPreferenceValue(ChipGlideKey.self) { target in ChipGlideRing(target: target, look: look) }
    }
}

/// Where the gliding ring is (`RowGlideMotion` of DELOS for Android): on the focused element's bounds as they are now, plus a
/// carry (what the ring still trails each edge by) that runs out on the glide curve. Not an animation of the ring's frame: an
/// element that moves while the ring glides to it (its row scrolls it into view) takes the ring along, instead of every moved
/// frame starting the glide anew, and at rest the ring is exactly on the element.
struct RingGlide: Equatable {
    /// What the ring trails the element's left, top, right and bottom edge by when the glide starts (points).
    var left = 0.0, top = 0.0, right = 0.0, bottom = 0.0
    /// When the glide started (seconds since the reference date).
    var start = 0.0
    /// How long it runs (seconds).
    var length = Self.duration

    /// A row's glide (`Motion.rowFocus`).
    static let duration = Motion.rowFocus / 1000
    /// The prototype's `--ease-glide` (`Motion.Glide`): it overshoots a little.
    static let curve = CubicBezier(0.3, 1.22, 0.42, 1)

    /// A glide that starts at [time] with the ring at [from] and ends on [to] [duration] seconds later.
    init(from: CGRect, to: CGRect, at time: Double, duration: Double = Self.duration) {
        left = from.minX - to.minX
        top = from.minY - to.minY
        right = from.maxX - to.maxX
        bottom = from.maxY - to.maxY
        start = time
        length = duration
    }

    /// No glide: the ring is on the element.
    init() {}

    /// The share of the carry still left at [time]: 1 when the glide starts, 0 once it is over (below 0 while it overshoots).
    func rest(at time: Double) -> Double {
        1 - Self.curve((time - start) / length)
    }

    /// The ring's bounds (before the focus scale) at [time], while the element is at [frame].
    func rect(on frame: CGRect, at time: Double) -> CGRect {
        let rest = rest(at: time)
        let minX = frame.minX + left * rest, minY = frame.minY + top * rest
        let maxX = frame.maxX + right * rest, maxY = frame.maxY + bottom * rest
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// The ring around [rect] grown around its center to [scale] times its size, its stroke's middle [outset] beyond that. Only
/// the scale animates (the element's spring); the bounds are those of the moment.
private struct GlideRingShape: Shape {
    var rect: CGRect
    var scale: Double
    var outset: Double

    var animatableData: Double {
        get { scale }
        set { scale = newValue }
    }

    func path(in _: CGRect) -> Path {
        let dx = rect.width * (scale - 1) / 2 + outset, dy = rect.height * (scale - 1) / 2 + outset
        return Capsule().path(in: rect.insetBy(dx: -dx, dy: -dy))
    }
}

private struct ChipGlideRing: View {
    let target: ChipGlideTarget?
    let look: GlideLook
    /// The element the ring is on (kept while the ring fades, so a quick next focus glides from there).
    @State private var holder: ChipGlideTarget?
    @State private var glide = RingGlide()
    /// The ring is gliding: the timeline redraws it every frame until the glide is over.
    @State private var gliding = false
    @State private var glides = 0
    /// The scale the ring is drawn at: it starts at 1 with the element, which grows on its spring, so the ring hugs it all
    /// the way instead of leading it at the full size.
    @State private var scale = 1.0
    @State private var faded = true
    @State private var fade: Task<Void, Never>?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced

    var body: some View {
        Group {
            if let holder {
                TimelineView(.animation(paused: !gliding)) { context in
                    // The ring lies a gap of its own width outside the element as it grows, and is that wide; at rest it is
                    // on the element's bounds themselves
                    GlideRingShape(
                        rect: gliding ? glide.rect(on: holder.frame, at: context.date.timeIntervalSinceReferenceDate) : holder.frame,
                        scale: scale, outset: stage.px(1.5 * look.ring))
                        .stroke(colors.accent.color, lineWidth: stage.px(look.ring))
                }
                .opacity(target == nil ? 0 : 1)
                .animation(
                    target == nil
                        ? .timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000).delay(0.07)
                        : .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.12),
                    value: target != nil)
            }
        }
        .task(id: glides) {
            guard gliding else { return }
            try? await Task.sleep(for: .seconds(RingGlide.duration))
            if !Task.isCancelled { gliding = false }
        }
        .onChange(of: target, initial: true) { _, now in
            guard let now else {
                // The focus left the elements: after the fade the ring is gone, and the next focus starts it afresh
                fade = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    if !Task.isCancelled { faded = true }
                }
                return
            }
            fade?.cancel()
            if let from = holder, from.id != now.id {
                if faded || reduced {
                    glide = RingGlide()
                } else {
                    // From where the ring is drawn now (mid-glide too) to the new element
                    let time = Date.timeIntervalSinceReferenceDate
                    glide = RingGlide(from: glide.rect(on: from.frame, at: time), to: now.frame, at: time)
                    gliding = true
                    glides += 1
                }
            }
            holder = now
            if faded {
                // A new focus: the ring appears at the element's size at rest and grows with it
                faded = false
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { scale = 1 }
            }
            // The element's frame moves with every frame of a scroll of its row: only a new scale starts the spring
            if scale != now.scale {
                withAnimation(.focusScale(pressed: now.scale < 1, reduced: reduced)) { scale = now.scale }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ChipScaleState: Equatable {
    let focused: Bool
    let pressed: Bool
}

/// The focus look of an element in a ``ChipGlideHost``: it reports its layout bounds to the host's ring, grows by the host's
/// scale and, above its neighbours, has the pills' glow; the ring is the host's, not its own.
struct ChipFocus: ViewModifier {
    let focused: Bool
    @Environment(\.glideLook) private var host
    @Environment(\.reducedMotion) private var reduced
    @Environment(\.pressed) private var pressed
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    /// Who the element is to the ring: a new one is glided to, the same one followed.
    @State private var id = UUID()

    func body(content: Content) -> some View {
        let look = host ?? .chip
        content
            .shadow(color: focused && look.glow ? colors.glow.color : .clear, radius: look.glow ? stage.px(25) : 0, y: stage.px(18))
            .animation(.focusRing(focused: focused), value: focused)
            .scaleEffect(focusScale(focused: focused, pressed: pressed, focus: look.scale))
            .animation(.focusScale(pressed: pressed, reduced: reduced), value: ChipScaleState(focused: focused, pressed: pressed))
            // Read outside the scale: inside it the frame grew with the element's spring, so the ring got a new target on
            // every frame of it (each one starting the glide again: it arrived in a few frames) and at rest was the focus scale
            // too big, as it scales the bounds itself
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ChipGlideKey.self,
                        value: focused ? ChipGlideTarget(
                            id: id, frame: proxy.frame(in: .named("chipGlide")),
                            scale: focusScale(focused: focused, pressed: pressed, focus: look.scale)) : nil)
                }
            }
            .zIndex(focused ? 1 : 0)
    }
}

// MARK: Pieces

/// A selectable chip (`FilterChip`): filled with the accent while chosen, a flat surface otherwise (the sheet it sits on is
/// glass already: twenty more glass layers on it, over the grid, cost the sheet its smoothness); the gliding ring marks the
/// cursor.
struct ArtChip: View, Equatable {
    let label: String
    let selected: Bool
    let focused: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    nonisolated static func == (a: ArtChip, b: ArtChip) -> Bool {
        a.label == b.label && a.selected == b.selected && a.focused == b.focused
    }

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
                    Capsule().fill(colors.surface2.color).overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                }
            }
            .modifier(ChipFocus(focused: focused))
            .accessibilityAddTraits(selected ? .isSelected : [])
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
        .background { GlassShape(Capsule(), tint: colors.surface2).overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1))) }
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
                        GlassShape(Capsule(), tint: tint.opacity(0.14), share: 1)
                            .overlay(Capsule().strokeBorder(tint.opacity(0.45).color, lineWidth: stage.px(1)))
                    }
                if refreshing { RingSpinner(size: 26) }
                if !filters.active {
                    Text(filters.sort.first)
                        .font(DelosFonts.figtree(stage.tpx(21)))
                        .foregroundStyle(colors.text3.color)
                        .lineLimit(1)
                } else {
                    // The chips keep the focus spacing between them; the result line keeps its 12
                    HStack(spacing: stage.px(GlideLook.chipGap)) {
                        ForEach(ArtFilterRules.chips(filters), id: \.self) { chip in
                            FocusItem(id: Self.chipID(chip), model: focus, action: { onClear(chip) }) { focused in
                                ArtStripChip(label: chip.label, icon: Symbols.close, focused: focused)
                            }
                        }
                        FocusItem(id: Self.resetID, model: focus, action: onReset) { focused in
                            ArtStripChip(label: L("filters_art_chips_reset"), icon: Symbols.reset, focused: focused)
                        }
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
        VStack(alignment: .leading, spacing: stage.px(GlideLook.pillGap)) {
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
                // Reset and Done share one ring that glides between them, and are far enough apart for it
                ChipGlideHost(look: .pill) {
                    HStack(spacing: stage.px(GlideLook.pillGap)) {
                        resetPill(active: filters.active)
                        FocusItem(id: Self.doneID, model: focus, clickCue: .back, action: onClose) { focused in
                            ToolbarPill(label: L("filters_art_done"), icon: Symbols.check, focused: focused, glyph: .north)
                        }
                    }
                }
            }
            .padding(.bottom, stage.px(8))
            ChipGlideHost {
                // Each divider splits one full chip gap between the neighbouring rows.
                VStack(alignment: .leading, spacing: stage.px(GlideLook.chipGap / 2)) {
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
                ToolbarPill(label: L("filters_art_reset"), icon: Symbols.reset, focused: focused, glyph: .west)
            }
        } else {
            ToolbarPill(label: L("filters_art_reset"), icon: Symbols.reset, focused: false, glyph: .west).opacity(0.4)
        }
    }

    private func chip(_ label: String, selected: Bool, key: String, action: @escaping () -> Void) -> some View {
        FocusItem(id: Self.optionID(key), model: focus, action: action) { focused in
            ArtChip(label: label, selected: selected, focused: focused).equatable()
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
                HStack(spacing: stage.px(GlideLook.chipGap)) { options() }
                    .padding(.horizontal, stage.px(12))
                    .padding(.vertical, stage.px(12))
            }
            .scrollClipDisabled()
        }
        .padding(.vertical, stage.px(2))
    }
}
