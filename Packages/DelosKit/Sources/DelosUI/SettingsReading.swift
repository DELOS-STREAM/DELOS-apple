import SwiftUI

/// MarqueeText.kt:29–34,66–68 and AutoScrollingHelp.kt:48–59 (seconds / stage pixels).
enum SettingsReadingMotion {
    static let startDelay = 0.700
    static let loopDelay = 0.900
    static let speed = 56.0
    static let gap = 56.0
    static let helpFirstPause = 3.0
    static let helpEndPause = 2.5
    /// The compact dock's first pause (`AutoScrollingHelp.edgeFade`): time to read the text whole.
    static let dockFirstPause = 8.0

    static func marqueeOffset(elapsed: Double, width: Double) -> Double {
        guard width > 0, elapsed >= startDelay else { return 0 }
        let lap = width + gap
        let travel = lap / speed
        let phase = (elapsed - startDelay).truncatingRemainder(dividingBy: travel + loopDelay)
        return phase < travel ? phase * speed : 0
    }

    /// One initial reading pause, then alternating legs with a pause at each end; [travel] is the overflow.
    static func bounceOffset(elapsed: Double, travel: Double, speed: Double = SettingsReadingMotion.speed) -> Double {
        guard travel > 0, speed > 0, elapsed >= startDelay else { return 0 }
        let leg = travel / speed
        let phase = (elapsed - startDelay).truncatingRemainder(dividingBy: 2 * (leg + loopDelay))
        if phase < leg { return phase * speed }
        if phase < leg + loopDelay { return travel }
        if phase < 2 * leg + loopDelay { return travel - (phase - leg - loopDelay) * speed }
        return 0
    }

    static func helpDuration(overflow: Double) -> Double {
        min(max(overflow / 20, 1), 120)
    }
}

/// One line of text that always stays readable (`MarqueeText` of DELOS for Android). A fitting label is just text; an
/// overflowing one fades out at its right end and, while [active] (usually: its row is focused), scrolls round in a loop.
/// Only a scrolling label owns an active display clock.
struct MarqueeLabel: View {
    let text: String
    let active: Bool
    var bounce = false

    var body: some View {
        Text(text)
            .lineLimit(1)
            .hidden()
            .overlay(alignment: .leading) { MarqueeTrack(key: text, active: active, bounce: bounce) { Text(text) } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }
}

/// [MarqueeLabel] for any single-line [content] (`MarqueeContent` of DELOS for Android, one way round): the same fades,
/// scroll and reduced-motion rules. It is as wide as its content, or as the room it is offered when that is less. A new
/// [key] starts the scroll over.
struct MarqueeContent<Key: Equatable, Content: View>: View {
    let key: Key
    var active = true
    var bounce = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        MarqueeRoom { content().fixedSize() }
            .hidden()
            .overlay(alignment: .leading) { MarqueeTrack(key: key, active: active, bounce: bounce, content: content) }
    }
}

/// Takes its content's ideal width, or the width offered when that is less, and its content's ideal height.
private struct MarqueeRoom: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: min(proposal.width ?? ideal.width, ideal.width), height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: .unspecified)
    }
}

/// The visible part of a marquee, laid over the room it has: [content] at its natural width, cut and faded to the room
/// (MarqueeText.kt:29-34): still for 0.7 s, a lap of the content and a 56 px gap at 56 px a second, a 0.9 s pause, and
/// again. The left end fades in over 28 px only as the content moves away from its start (and out as the lap ends), the
/// right end of an overflowing content always fades over 36 px. A content that stops scrolling (focus lost, reduced
/// motion) or changes stands at its start again.
private struct MarqueeTrack<Key: Equatable, Content: View>: View {
    let key: Key
    let active: Bool
    let bounce: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced
    @State private var naturalWidth = 0.0
    @State private var started = Date.now

    var body: some View {
        GeometryReader { proxy in
            let overflow = naturalWidth > proxy.size.width + 0.5
            let scrolling = overflow && active && !reduced
            TimelineView(.animation(paused: !scrolling)) { clock in
                let travel = max(0, (naturalWidth - proxy.size.width) / stage.scale)
                let elapsed = clock.date.timeIntervalSince(started)
                let offset = !scrolling ? 0 : (bounce
                    ? SettingsReadingMotion.bounceOffset(elapsed: elapsed, travel: travel)
                    : SettingsReadingMotion.marqueeOffset(elapsed: elapsed, width: naturalWidth / stage.scale))
                let lap = naturalWidth / stage.scale + SettingsReadingMotion.gap
                let hiddenStart = scrolling ? stage.px(bounce ? offset : min(offset, lap - offset)) : 0
                let hiddenEnd = overflow ? (bounce ? stage.px(travel - offset) : stage.px(36)) : 0
                HStack(spacing: stage.px(SettingsReadingMotion.gap)) {
                    content().fixedSize()
                        .onGeometryChange(for: Double.self) { $0.size.width } action: { naturalWidth = $0 }
                    if scrolling && !bounce { content().fixedSize() }
                }
                .offset(x: -stage.px(offset))
                .frame(width: proxy.size.width, alignment: .leading)
                .modifier(EdgeFadeMask(
                    hiddenStart: hiddenStart, hiddenEnd: hiddenEnd, axis: .horizontal,
                    start: FadeEdge(solid: stage.px(28)), end: FadeEdge(solid: min(stage.px(36), proxy.size.width))))
                .clipped()
            }
            // The keys of MarqueeContent's LaunchedEffect: whether it scrolls, the content and its width
            .onChange(of: scrolling, initial: true) { _, _ in started = .now }
            .onChange(of: key) { _, _ in started = .now }
            .onChange(of: naturalWidth) { _, _ in started = .now }
        }
    }
}

/// Passive help loops at reading speed; reduced motion leaves a still, manually scrollable panel (`AutoScrollingHelp`).
/// [edgeFade] (stage px) is the compact dock's look: no padding above or below, and each edge fades only as far as the
/// content continues behind it (nothing at rest at the top, growing with the first pixels scrolled), and the first
/// pause is 8 s, to read the text whole.
struct AutoScrollingHelp<Content: View>: View {
    let identity: String
    /// The padding above and below the text, which is also the width of the fades at both ends (stage px).
    var inset = 24.0
    var edgeFade: Double?
    @ViewBuilder let content: () -> Content
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced
    @State private var position = ScrollPosition(y: 0)
    @State private var extent = Extent()

    private struct Extent: Equatable, Hashable {
        var content = 0.0
        var viewport = 0.0
        var overflow: Double { max(0, content - viewport) }
    }

    private struct Run: Hashable {
        let identity: String
        let extent: Extent
        let scale: Double
        let reduced: Bool
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content()
                .padding(.vertical, stage.px(edgeFade == nil ? inset : 0))
        }
        .scrollPosition($position)
        .scrollDisabled(!reduced)
        .onScrollGeometryChange(for: Extent.self) { geometry in
            Extent(content: geometry.contentSize.height, viewport: geometry.containerSize.height)
        } action: { _, value in extent = value }
        // Each edge fades as far as the text continues behind it: over [inset] (which is padding at rest), or in the dock over
        // [edgeFade]
        .scrollEdgeFade(.vertical, FadeEdges(edgeFade ?? inset), outset: 0)
        .task(id: Run(identity: identity, extent: extent, scale: stage.scale, reduced: reduced)) {
            var reset = Transaction(animation: nil)
            reset.disablesAnimations = true
            withTransaction(reset) { position.scrollTo(y: 0) }
            guard extent.overflow > 0, !reduced else { return }
            let duration = SettingsReadingMotion.helpDuration(overflow: extent.overflow / stage.scale)
            var firstPause = edgeFade == nil ? SettingsReadingMotion.helpFirstPause : SettingsReadingMotion.dockFirstPause
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(firstPause))
                    firstPause = SettingsReadingMotion.helpFirstPause
                    withAnimation(.linear(duration: duration)) { position.scrollTo(y: extent.overflow) }
                    try await Task.sleep(for: .seconds(duration + SettingsReadingMotion.helpEndPause))
                    withAnimation(.linear(duration: duration)) { position.scrollTo(y: 0) }
                    try await Task.sleep(for: .seconds(duration))
                }
            } catch is CancellationError {
                // A new selection, size, reduced-motion setting or disappearance cancels the reading cycle.
            } catch {
                assertionFailure("Unexpected help clock failure: \(error)")
            }
        }
    }
}
