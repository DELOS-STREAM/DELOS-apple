import DelosInput
import SwiftUI

/// The bottom bar (`HintBar` of DELOS for Android's `shell/ui/Bars.kt`): an optional note on the left, the button hints on
/// the right, 92 px high with 72 px at the sides and 34 px between the hints. The buttons are the connected controller's
/// (``GlyphButton``). A compact stage fits as much of the note and the hints as the width holds (``HintFit``): the least
/// important hints lose their labels first.
struct HintBar: View {
    let hints: [Hint]
    var note: String?
    var noteLabel: String?
    /// How far above the bottom edge of the window the bar's middle is, in points (``HintBarLayout``): nil keeps the bar
    /// on the bottom safe edge.
    var centerFromBottom: CGFloat?
    /// A tappable hint was pressed (touch, pointer).
    var onTap: ((Hint) -> Void)?
    @State private var widths: [String: Double] = [:]
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced

    private static let height = 92.0, inset = 72.0, gap = 34.0, compactGap = 28.0, noteGap = 34.0

    var body: some View {
        let side = Self.inset + stage.safe.leading, sideEnd = Self.inset + stage.safe.trailing
        Group {
            if stage.compact { compactBody(side: side, sideEnd: sideEnd) } else { regularBody }
        }
        .frame(maxWidth: .infinity)
        .frame(height: stage.px(Self.height))
        .padding(.leading, stage.px(Self.inset + stage.safe.leading))
        .padding(.trailing, stage.px(Self.inset + stage.safe.trailing))
        .padding(.bottom, centerFromBottom.map { max($0 - stage.px(Self.height) / 2, 0) } ?? stage.px(stage.safe.bottom))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var regularBody: some View {
        HStack(spacing: stage.px(Self.gap)) {
            if note != nil { noteView(withLabel: noteLabel != nil) }
            Spacer(minLength: 0)
            ForEach(hints, id: \.self) { cell($0, .full) }
        }
    }

    private func compactBody(side: Double, sideEnd: Double) -> some View {
        let variants = noteVariants
        let items = hints.enumerated().map { i, hint in
            HintFitItem(
                rank: HintFit.rank(hint.button), bare: widths["h\(i)bare"] ?? 0,
                short: hint.shortLabel.flatMap { _ in widths["h\(i)short"] }.flatMap { $0 < (widths["h\(i)full"] ?? 0) ? $0 : nil },
                full: widths["h\(i)full"] ?? 0, group: HintFit.group(hint.button))
        }
        let available = stage.width - side - sideEnd
        let fit = HintFit.fitBar(
            noteWidths: variants.indices.map { widths["n\($0)"] ?? 0 }, noteGap: Self.noteGap, items: items,
            hintGap: Self.compactGap, available: available)
        return HStack(spacing: stage.px(Self.compactGap)) {
            if let i = fit.note { noteView(withLabel: variants[i]) }
            Spacer(minLength: 0)
            ForEach(Array(hints.enumerated()), id: \.offset) { i, hint in cell(hint, fit.details[i]) }
        }
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(variants.enumerated()), id: \.offset) { i, with in measured(noteView(withLabel: with), "n\(i)") }
                ForEach(Array(hints.enumerated()), id: \.offset) { i, hint in
                    measured(cell(hint, .bare), "h\(i)bare")
                    measured(cell(hint, .short), "h\(i)short")
                    measured(cell(hint, .full), "h\(i)full")
                }
            }
            .hidden()
            .accessibilityHidden(true)
        }
    }

    /// The note variants, fullest first: with its label, then alone (`noteVariants`).
    private var noteVariants: [Bool] {
        guard note != nil else { return [] }
        return noteLabel != nil ? [true, false] : [false]
    }

    private func measured(_ view: some View, _ key: String) -> some View {
        view.fixedSize()
            .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { widths[key] = $0 / stage.scale }
    }

    /// The note: its small label, then the sentence, on one baseline.
    private func noteView(withLabel: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: stage.px(20)) {
            if withLabel, let noteLabel {
                Text(noteLabel)
                    .font(DelosFonts.figtree(stage.tpx(20), .semibold))
                    .tracking(stage.tpx(20) * 0.14)
                    .foregroundStyle(colors.accent3.color)
            }
            Text(note ?? "")
                .font(DelosFonts.figtree(stage.tpx(21)))
                .foregroundStyle(colors.text3.color)
                .lineLimit(1)
        }
    }

    /// One hint: its button and, by `detail`, its full label, its short label or nothing. A tappable hint is a glyphless pill
    /// that takes touches while no controller is the input (``ControllerGlyphs/kind``), and fades into the hint when one is.
    @ViewBuilder private func cell(_ hint: Hint, _ detail: HintDetail) -> some View {
        let pill = hint.tappable && ControllerGlyphs.shared.kind != .controller
        let label = detail == .short ? hint.shortLabel ?? hint.label : hint.label
        Group {
            if pill {
                Button { onTap?(hint) } label: {
                    Text(label)
                        .font(DelosFonts.figtree(stage.tpx(21), .semibold))
                        .foregroundStyle(colors.text.color)
                        .lineLimit(1)
                        .padding(.horizontal, stage.px(24))
                        .frame(height: stage.px(44))
                        .background {
                            GlassShape(Capsule(), tint: colors.surface)
                                .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: Motion.popFromScale)))
            } else {
                HStack(spacing: stage.px(12)) {
                    GlyphButton(button: hint.button)
                    if detail != .bare {
                        Text(label)
                            .font(DelosFonts.figtree(stage.tpx(21)))
                            .foregroundStyle(colors.text2.color)
                            .lineLimit(1)
                    }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(reduced ? .easeOut(duration: Motion.fade / 1000) : Motion.out(Motion.rowIn), value: pill)
        .accessibilityElement(children: .combine)
    }
}

/// Where the hint bar sits: its middle is the midpoint between the lowest edge of the screen's content and the bottom edge
/// of the stage, so the bar has the same air above and below it (the iPad's bar crowded the covers when it was
/// anchored at the bottom safe edge). The lowest edge of the content is the library row's bottom, ring and glow
/// included, on the home screen; the other screens keep their content above the same line (the home's distance from the
/// bottom edge at the design height), so the bar sits at the same height on all of them. The glyphs never go lower than
/// the bottom safe edge. All in stage pixels (``HintBarLayout/rowBottom(scale:safeTop:stageHeight:)`` too).
enum HintBarLayout {
    /// The glyph's height: it must clear the bottom safe edge.
    static let glyph = 38.0

    /// The bottom of the home's covers with their focus ring (`HomeLayout`).
    static func rowBottom(scale: Double, safeTop: Double, stageHeight: Double) -> Double {
        HomeLayout(scale: scale, safeTop: safeTop, stageHeight: stageHeight).coverTop + HomeLayout.coverHeight
            + HomeLayout.ringReach(HomeLayout.coverHeight)
    }

    /// The content line of the screens without the library row: as far above the stage's bottom as the home's row is at
    /// the design height and interface scale 1.
    static func defaultContentBottom(stageHeight: Double) -> Double {
        stageHeight - (HomeLayout.designHeight - rowBottom(scale: 1, safeTop: 0, stageHeight: HomeLayout.designHeight))
    }

    /// The distance of the bar's middle from the bottom of the stage. [contentBottom]: nil for the default line.
    /// [zoom]: the interface scale that zooms the bar (its glyph grows with it).
    static func centerFromBottom(stageHeight: Double, safeBottom: Double, contentBottom: Double?, zoom: Double = 1) -> Double {
        let bottom = contentBottom ?? defaultContentBottom(stageHeight: stageHeight)
        let middle = (stageHeight - bottom) / 2
        return max(middle, safeBottom + glyph * zoom / 2)
    }
}

/// The hint bar of the shell, placed by ``HintBarLayout`` and zoomed by the interface scale.
struct ShellHintBar: View {
    let hints: [Hint]
    var note: String?
    var noteLabel: String?
    /// The library row is on the screen.
    var libraryRow = false
    var onTap: ((Hint) -> Void)?
    @Environment(\.stage) private var stage

    var body: some View {
        let contentBottom = libraryRow
            ? HintBarLayout.rowBottom(scale: stage.textScale, safeTop: stage.safe.top, stageHeight: stage.height) : nil
        let center = HintBarLayout.centerFromBottom(
            stageHeight: stage.height, safeBottom: stage.safe.bottom, contentBottom: contentBottom, zoom: stage.textScale)
        HintBar(hints: hints, note: note, noteLabel: noteLabel, centerFromBottom: stage.px(center), onTap: onTap)
            // The interface scale zooms the whole bar
            .modifier(ZoomedBar())
    }
}
