import CoreText
import SwiftUI

/*
 * The touch building blocks of the companion's pages (`CompanionWidgets.kt` and `CompanionLayout.kt` of DELOS for
 * Android): the card whose blocks ``FitColumn`` lays out (the least important optional ones go when they do not all fit,
 * a filler takes what is left, so a page never overflows), headings, text, chips, the impact chips, big buttons, the hint
 * list, the slider, the stepper and the key that reports down and up. Every target is at least 64 stage pixels high and
 * every text at least 28.
 */

// MARK: - Fit

/// The fit of one page: its panel (fit pixels), the budgets and the measuring of text.
struct CompanionFitContext {
    let panel: CompanionPanel
    let budget: FitBudget
    let metrics: CoreTextMetrics

    init(stage: Stage) {
        // Text grows with the interface scale, so the panel has fewer fit pixels
        let panel = CompanionPanel(width: stage.width / stage.textScale, height: stage.height / stage.textScale)
        self.panel = panel
        budget = CompanionFit.budget(panel)
        metrics = CoreTextMetrics()
    }
}

/// Measures text the way the pages draw it, in fit pixels (stage pixels at the interface scale 1): Figtree at the smallest
/// text size, Unbounded SemiBold at the title size.
struct CoreTextMetrics: CompanionTextMetrics {
    private static func font(_ kind: FitText) -> CTFont {
        switch kind {
        case .body: font(family: "Figtree", size: CompanionFit.minText, weight: 0)
        case .title: font(family: "Unbounded", size: CompanionFit.titleSize, weight: 0.3)
        }
    }

    /// The bundled variable font [family] at [weight] (Core Text's weight trait: 0 regular, 0.3 semibold).
    private static func font(family: String, size: Double, weight: Double) -> CTFont {
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: family,
            kCTFontTraitsAttribute: [kCTFontWeightTrait: weight],
        ] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    private func frame(_ text: String, width: Double, kind: FitText) -> CTFrame {
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): Self.font(kind)])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: max(width, 1), height: 100_000), transform: nil)
        return CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
    }

    func lines(_ text: String, width: Double, kind: FitText) -> Int {
        guard !text.isEmpty else { return 0 }
        return CFArrayGetCount(CTFrameGetLines(frame(text, width: width, kind: kind)))
    }

    func width(_ text: String, kind: FitText) -> Double {
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): Self.font(kind)])
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
    }
}

/// What a block of a ``FitColumn`` says: its priority (lower goes first when the page is too tall; ``mandatory`` never
/// goes) and, for a flexible block, the least height it takes and its share of what is left.
struct FitBlock: Equatable {
    static let mandatory = Int.max
    var priority = mandatory
    var flexible = false
    var minHeight: CGFloat = 0
    var weight: CGFloat = 1
}

private struct FitBlockKey: LayoutValueKey {
    static let defaultValue = FitBlock()
}

extension View {
    /// The block is left out when the page is too tall; blocks of a lower [priority] go before it.
    func optional(_ priority: Int) -> some View { layoutValue(key: FitBlockKey.self, value: FitBlock(priority: priority)) }

    /// The block takes the height the fixed blocks leave (at least [minHeight] stage pixels, shared by [weight]).
    func fills(minHeight: CGFloat = 0, weight: CGFloat = 1, priority: Int = FitBlock.mandatory) -> some View {
        layoutValue(key: FitBlockKey.self, value: FitBlock(priority: priority, flexible: true, minHeight: minHeight, weight: weight))
    }
}

/// A column that never overflows (`FitColumn`, CompanionLayout.kt:66-100): the fixed blocks get their natural height, the
/// optional ones of the lowest priority are left out while the sum is taller than the column, and what is left goes to
/// the flexible blocks. A block left out is placed outside the card, which clips it.
struct FitColumn: Layout {
    var gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        if let height = proposal.height { return CGSize(width: width, height: height) }
        let heights = Self.natural(subviews, width: width)
        return CGSize(width: width, height: Self.used(heights, alive: heights.map { _ in true }, gap: gap))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let blocks = subviews.map { $0[FitBlockKey.self] }
        let natural = Self.natural(subviews, width: bounds.width)
        let alive = Self.alive(blocks: blocks, heights: natural, gap: gap, height: bounds.height)
        let spare = max(bounds.height - Self.used(natural, alive: alive, gap: gap), 0)
        var weights: CGFloat = 0
        for i in blocks.indices where alive[i] && blocks[i].flexible { weights += blocks[i].weight }
        var y = bounds.minY
        var first = true
        for i in subviews.indices {
            guard alive[i] else {
                subviews[i].place(at: CGPoint(x: bounds.minX, y: bounds.maxY + 10_000), proposal: ProposedViewSize(width: bounds.width, height: natural[i]))
                continue
            }
            if !first { y += gap }
            first = false
            var height = natural[i]
            if blocks[i].flexible, weights > 0 { height += spare * blocks[i].weight / weights }
            subviews[i].place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }

    /// The height each block asks for: a flexible block its least height, the others their natural one at [width].
    private static func natural(_ subviews: Subviews, width: CGFloat) -> [CGFloat] {
        subviews.map { subview -> CGFloat in
            let block = subview[FitBlockKey.self]
            return block.flexible ? block.minHeight : subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
    }

    /// The height the [alive] blocks take with the gaps between them.
    static func used(_ heights: [CGFloat], alive: [Bool], gap: CGFloat) -> CGFloat {
        var sum: CGFloat = 0
        var count = 0
        for i in heights.indices where alive[i] {
            sum += heights[i]
            count += 1
        }
        return sum + gap * CGFloat(max(count - 1, 0))
    }

    /// Which blocks stay: the optional ones of the lowest priority are dropped while the column is too tall.
    static func alive(blocks: [FitBlock], heights: [CGFloat], gap: CGFloat, height: CGFloat) -> [Bool] {
        var alive = Array(repeating: true, count: blocks.count)
        while used(heights, alive: alive, gap: gap) > height {
            guard let victim = blocks.indices.filter({ alive[$0] && blocks[$0].priority != FitBlock.mandatory })
                .min(by: { blocks[$0].priority < blocks[$1].priority }) else { break }
            alive[victim] = false
        }
        return alive
    }
}

/// The empty block that takes the height nothing else wants: it pushes what follows to the bottom of the card.
struct Filler: View {
    var body: some View { Color.clear.fills() }
}

// MARK: - Card

/// The strip layout of every page (`PageCard`): the outer margin, the glass card and the free footer line; its blocks are a
/// ``FitColumn``.
struct PageCard<Content: View>: View {
    @ViewBuilder let content: (CompanionFitContext) -> Content
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        let fit = CompanionFitContext(stage: stage)
        let shape = RoundedRectangle(cornerRadius: stage.px(30), style: .continuous)
        FitColumn(gap: stage.px(CompanionFit.gap(fit.panel))) { content(fit) }
            .padding(stage.px(CompanionFit.cardPadding(fit.panel)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(shape.fill(LinearGradient(colors: [colors.surface2.color, colors.surface.color], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(shape.strokeBorder(colors.line.color, lineWidth: stage.px(1)))
            .clipShape(shape)
            .padding(.horizontal, stage.px(CompanionFit.margin))
            .padding(.top, stage.px(CompanionFit.margin))
            .padding(.bottom, stage.px(CompanionFit.margin + CompanionFit.footer))
    }
}

/// The disc with an icon, the title in the display face and the small line under it (`PageHeading`).
struct PageHeading: View {
    let icon: String
    let title: String
    var subtitle: String?
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    /// The width the disc and its gap take from a title's line, in stage pixels (`HelpFit.HEADING_CHROME`).
    nonisolated static let chrome = 80.0

    var body: some View {
        HStack(spacing: stage.px(16)) {
            ZStack {
                Circle().fill(colors.accent.color)
                SymbolView(symbol: icon, size: 34, color: colors.onAccent, filled: true)
            }
            .frame(width: stage.px(64), height: stage.px(64))
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(DelosFonts.unbounded(stage.tpx(CompanionFit.titleSize)))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    BodyText(subtitle, color: colors.text2, maxLines: 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A run of text at the companion's body size (`BodyText`): [maxLines] is only a safety net under the budgets.
struct BodyText: View {
    let text: String
    var color: RGBA?
    var maxLines: Int?
    var weight: Font.Weight = .regular
    var size = CompanionFit.minText
    var alignment = TextAlignment.leading
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    init(_ text: String, color: RGBA? = nil, maxLines: Int? = nil, weight: Font.Weight = .regular, size: Double = CompanionFit.minText,
         alignment: TextAlignment = .leading) {
        self.text = text
        self.color = color
        self.maxLines = maxLines
        self.weight = weight
        self.size = size
        self.alignment = alignment
    }

    var body: some View {
        Text(verbatim: text)
            .font(DelosFonts.figtree(stage.tpx(size), weight).monospacedDigit())
            .foregroundStyle((color ?? colors.text).color)
            .lineLimit(maxLines)
            .lineSpacing(stage.tpx(size) * 0.2)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }
}

/// The small caps line over a block (`Eyebrow`): letter-spaced, never under the smallest text size.
struct CompanionEyebrow: View {
    let text: String
    var color: RGBA?
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        Text(verbatim: text.uppercased())
            .font(DelosFonts.figtree(stage.tpx(CompanionFit.minText), .semibold))
            .tracking(stage.tpx(CompanionFit.minText) * 0.12)
            .foregroundStyle((color ?? colors.text3).color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row of small glass chips (genres, filters).
struct ChipRow: View {
    let labels: [String]
    var color: RGBA?
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        HStack(spacing: stage.px(8)) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                let shape = RoundedRectangle(cornerRadius: stage.px(14), style: .continuous)
                Text(verbatim: label)
                    .font(DelosFonts.figtree(stage.tpx(CompanionFit.minText)))
                    .foregroundStyle((color ?? colors.text).color)
                    .lineLimit(1)
                    .padding(.horizontal, stage.px(12))
                    .padding(.vertical, stage.px(5))
                    .background(shape.fill(colors.surface3.color))
                    .overlay(shape.strokeBorder(colors.line.color, lineWidth: stage.px(1)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A rounded label (genre, HowLongToBeat, HDR): [icon] and [text] on a glass pill (`InfoPill`).
struct CompanionInfoPill: View {
    let text: String
    var icon: String?
    var color: RGBA?
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        HStack(spacing: stage.px(10)) {
            if let icon { SymbolView(symbol: icon, size: 32, color: color ?? colors.text2) }
            Text(verbatim: text).font(DelosFonts.figtree(stage.tpx(CompanionFit.minText))).foregroundStyle((color ?? colors.text2).color).lineLimit(1)
        }
        .padding(.horizontal, stage.px(22))
        .padding(.vertical, stage.px(10))
        .background(Capsule().fill(colors.surface.color))
        .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
    }
}

/// Fact rows in two columns: the label above its value on a tall panel, the value alone on a short one (`FactsGrid`).
struct FactsGrid: View {
    let facts: [(label: String, value: String)]
    let roomy: Bool
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        let rows = stride(from: 0, to: facts.count, by: 2).map { Array(facts[$0..<min($0 + 2, facts.count)]) }
        VStack(spacing: stage.px(8)) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, pair in
                HStack(alignment: .top, spacing: stage.px(24)) {
                    ForEach(Array(pair.enumerated()), id: \.offset) { _, fact in
                        VStack(alignment: .leading, spacing: 0) {
                            if roomy { BodyText(fact.label, color: colors.text2, maxLines: 1) }
                            BodyText(fact.value, maxLines: 1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if pair.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
    }
}

/// The three impact chips of a setting or a game, equal in width (`ImpactChips`): the axis and its bars; nil shows dashes
/// (no cost on the stream). An estimate, never a measurement.
struct CompanionImpactChips: View {
    let impact: SettingImpact?
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        HStack(spacing: stage.px(8)) {
            ForEach(Array(ImpactAxes.all.enumerated()), id: \.offset) { index, axis in
                let level = impact?.levels[index]
                let tint = level.map { $0 == .none ? colors.text3 : $0.color(colors) } ?? colors.text3
                let shape = RoundedRectangle(cornerRadius: stage.px(14), style: .continuous)
                HStack(spacing: stage.px(10)) {
                    Text(verbatim: axis.name).font(DelosFonts.figtree(stage.tpx(CompanionFit.minText))).foregroundStyle(colors.text2.color).lineLimit(1)
                    if let level { LevelBars(level: level, fill: tint) } else {
                        Text(verbatim: "\u{2013}").font(DelosFonts.figtree(stage.tpx(CompanionFit.minText))).foregroundStyle(colors.text3.color)
                    }
                }
                .padding(stage.px(6))
                .frame(maxWidth: .infinity)
                .background(shape.fill(tint.opacity(0.06).color))
                .overlay(shape.strokeBorder(tint.opacity(0.4).color, lineWidth: stage.px(1)))
            }
        }
    }
}

/// One to three filled bars, the rest faint (`LevelBars`).
struct LevelBars: View {
    let level: ImpactLevel
    let fill: RGBA
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        HStack(alignment: .bottom, spacing: stage.px(4)) {
            ForEach(1...3, id: \.self) { step in
                RoundedRectangle(cornerRadius: stage.px(3))
                    .fill((step <= level.rawValue ? fill : colors.text3.opacity(0.3)).color)
                    .frame(width: stage.px(9), height: stage.px(Double(12 + (step - 1) * 9)))
            }
        }
        .frame(height: stage.px(30), alignment: .bottom)
    }
}

// MARK: - Buttons

/// The look of a ``CompanionButton``.
enum CompanionButtonStyle: Hashable, Sendable { case primary, secondary, normal, danger }

/// A touch button of a page (`PageAction`): what it says, what it runs (the owner's own path) and how it looks. Equal by
/// what it shows, so a page's revision can hold it.
struct PageAction: Hashable {
    let label: String
    var style = CompanionButtonStyle.normal
    var icon: String?
    var enabled = true
    let run: @MainActor () -> Void

    static func == (a: PageAction, b: PageAction) -> Bool {
        a.label == b.label && a.style == b.style && a.icon == b.icon && a.enabled == b.enabled
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(label)
        hasher.combine(style)
        hasher.combine(icon)
        hasher.combine(enabled)
    }
}

/// A big touch button (`CompanionButton`): [icon] and [label] centred; [selected] gives it the accent outline.
struct CompanionButton: View {
    let label: String
    var style = CompanionButtonStyle.normal
    var icon: String?
    var selected = false
    var enabled = true
    var textSize = 32.0
    var maxLines = 1
    let action: @MainActor () -> Void
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        Button(action: action) {
            let (fill, content, line) = look
            let shape = RoundedRectangle(cornerRadius: stage.px(18), style: .continuous)
            HStack(spacing: stage.px(14)) {
                if let icon { SymbolView(symbol: icon, size: textSize + 6, color: content.opacity(enabled ? 1 : 0.4)) }
                if !label.isEmpty {
                    Text(verbatim: label)
                        .font(DelosFonts.figtree(stage.tpx(textSize), .semibold))
                        .foregroundStyle(content.opacity(enabled ? 1 : 0.4).color)
                        .multilineTextAlignment(.center)
                        .lineLimit(maxLines)
                }
            }
            .padding(.horizontal, stage.px(22))
            .frame(maxWidth: .infinity, minHeight: stage.px(CompanionFit.minTarget), maxHeight: .infinity)
            .background(shape.fill(fill.color))
            .overlay(shape.strokeBorder((selected ? colors.accent : line).color, lineWidth: stage.px(selected ? 3 : 1)))
            .contentShape(shape)
        }
        .buttonStyle(CompanionPressStyle())
        .disabled(!enabled)
    }

    private var look: (RGBA, RGBA, RGBA) {
        switch style {
        case .primary: (colors.accent, colors.onAccent, colors.accent)
        case .secondary: (colors.accent2.opacity(0.14), colors.accent2, colors.accent2.opacity(0.45))
        case .danger: (ImpactRed.value.opacity(0.13), ImpactRed.value, ImpactRed.value.opacity(0.5))
        case .normal: (colors.surface2, colors.text, colors.line)
        }
    }
}

/// The press of a companion button: it sinks 2 stage pixels and fades a little.
private struct CompanionPressStyle: ButtonStyle {
    @Environment(\.stage) private var stage

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .offset(y: configuration.isPressed ? stage.px(2) : 0)
    }
}

/// The buttons of one row, equal in width and 64 stage pixels high (`ActionRow`).
struct ActionRow: View {
    let actions: [PageAction]
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(8)) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                CompanionButton(label: action.label, style: action.style, icon: action.icon, enabled: action.enabled, textSize: CompanionFit.minText, action: action.run)
                    .frame(height: stage.px(CompanionFit.minTarget))
            }
        }
    }
}

/// The buttons of one row, equal in width; a label that does not fit one line wraps to a second and the row grows with
/// it (`WrappingActionRow`).
struct WrappingActionRow: View {
    let actions: [PageAction]
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(8)) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                CompanionButton(
                    label: action.label, style: action.style, icon: action.icon, enabled: action.enabled, textSize: CompanionFit.minText, maxLines: 2,
                    action: action.run)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Actions set apart by a rule above them, the destructive ones (Remove, Unpair) (`SeparatedActions`).
struct SeparatedActions: View {
    let actions: [PageAction]
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        VStack(spacing: stage.px(12)) {
            Rectangle().fill(colors.line.color).frame(height: stage.px(1))
            HStack(spacing: stage.px(8)) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    CompanionButton(label: action.label, style: .danger, icon: action.icon, enabled: action.enabled, textSize: CompanionFit.minText, action: action.run)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(height: stage.px(CompanionFit.minTarget))
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// The entries of the main hint bar: the button in the accent color and its word; [rest] more are on the main screen
/// (`HintList`).
struct HintList: View {
    let hints: [CompanionHint]
    let rest: Int
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: stage.px(6)) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                HStack(spacing: stage.px(16)) {
                    GlyphButton(button: hint.button, size: 32, disc: colors.accent, ink: colors.onAccent)
                        .frame(width: stage.px(56), alignment: .leading)
                    BodyText(hint.label, maxLines: 1)
                }
            }
            if rest > 0 { BodyText(L("companion_hints_more", rest), color: colors.text2, maxLines: 1) }
        }
    }
}

// MARK: - Slider, stepper, key

/// The value of a slider a finger at [fraction] (0…1) of its width stands for, snapped to [step] within [min]…[max]
/// (`snapSliderValue`).
func snapSliderValue(_ fraction: Double, min lower: Int, max upper: Int, step: Int) -> Int {
    let raw = Double(lower) + Swift.min(Swift.max(fraction, 0), 1) * Double(upper - lower)
    let snapped = lower + Int(((raw - Double(lower)) / Double(Swift.max(step, 1))).rounded()) * Swift.max(step, 1)
    return Swift.min(Swift.max(snapped, lower), upper)
}

/// A slider for a thumb (`TouchSlider`): a track that follows a drag and a tap, with a round knob. [onChange] gets every
/// value while dragging, [onCommit] the last one.
struct TouchSlider: View {
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    var enabled = true
    let onChange: @MainActor (Int) -> Void
    let onCommit: @MainActor (Int) -> Void
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fraction = Double(value - range.lowerBound) / Double(max(range.upperBound - range.lowerBound, 1))
            let knob = stage.px(52)
            ZStack(alignment: .leading) {
                Capsule().fill(colors.surface3.color).frame(height: stage.px(14))
                Capsule().fill(colors.accent.color).frame(width: width * min(max(fraction, 0), 1), height: stage.px(14))
                Circle().fill(colors.accent.color)
                    .overlay(Circle().strokeBorder(colors.bg.color, lineWidth: stage.px(5)))
                    .frame(width: knob, height: knob)
                    .offset(x: width * min(max(fraction, 0), 1) - knob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            #if !os(tvOS)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { onChange(at($0.location.x, width)) }
                .onEnded { onCommit(at($0.location.x, width)) }, isEnabled: enabled)
            #endif
        }
        .frame(height: stage.px(CompanionFit.minTarget + 16))
        .opacity(enabled ? 1 : 0.4)
    }

    private func at(_ x: CGFloat, _ width: CGFloat) -> Int {
        snapSliderValue(Double(x / width), min: range.lowerBound, max: range.upperBound, step: step)
    }
}

/// A stepper for a thumb (`Stepper`): − value +.
struct CompanionStepper<Value: View>: View {
    let onMinus: @MainActor () -> Void
    let onPlus: @MainActor () -> Void
    @ViewBuilder let value: () -> Value
    @Environment(\.stage) private var stage

    var body: some View {
        let side = stage.px(CompanionFit.minTarget + 16)
        HStack(spacing: stage.px(14)) {
            CompanionButton(label: "\u{2212}", textSize: 40, action: onMinus).frame(width: side, height: side)
            value().frame(maxWidth: .infinity)
            CompanionButton(label: "+", textSize: 40, action: onPlus).frame(width: side, height: side)
        }
    }
}

/// A key that reports the finger going down and coming up (`PressKey`): the PC needs both.
struct PressKey<Label: View>: View {
    var selected = false
    var accent = false
    let onDown: @MainActor () -> Void
    let onUp: @MainActor () -> Void
    @ViewBuilder let label: (_ pressed: Bool) -> Label
    @State private var pressed = false
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: stage.px(14), style: .continuous)
        label(pressed)
            .frame(maxWidth: .infinity, minHeight: stage.px(CompanionFit.minTarget), maxHeight: .infinity)
            .background(shape.fill((pressed ? colors.accent : accent || selected ? colors.accent.opacity(0.22) : colors.surface2).color))
            .overlay(shape.strokeBorder((selected ? colors.accent : colors.line).color, lineWidth: stage.px(selected ? 3 : 1)))
            .contentShape(shape)
            #if !os(tvOS)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    onDown()
                }
                .onEnded { _ in
                    pressed = false
                    onUp()
                })
            #endif
    }
}
