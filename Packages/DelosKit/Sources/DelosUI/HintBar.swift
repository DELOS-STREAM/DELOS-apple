import SwiftUI

/// The bottom bar (`HintBar` of DELOS for Android's `shell/ui/Bars.kt`): an optional note on the left, the button hints on
/// the right, 92 px high with 72 px at the sides and 34 px between the hints. The buttons are the connected controller's
/// (``GlyphButton``). A compact stage fits as much of the note and the hints as the width holds (``HintFit``): the least
/// important hints lose their labels first.
struct HintBar: View {
    let hints: [Hint]
    var note: String?
    var noteLabel: String?
    @State private var widths: [String: Double] = [:]
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

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
        .padding(.bottom, stage.px(stage.safe.bottom))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
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

    /// One hint: its button and, by `detail`, its full label, its short label or nothing.
    private func cell(_ hint: Hint, _ detail: HintDetail) -> some View {
        HStack(spacing: stage.px(12)) {
            GlyphButton(button: hint.button)
            if detail != .bare {
                Text(detail == .short ? hint.shortLabel ?? hint.label : hint.label)
                    .font(DelosFonts.figtree(stage.tpx(21)))
                    .foregroundStyle(colors.text2.color)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
