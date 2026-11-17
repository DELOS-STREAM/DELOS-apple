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

    static func helpDuration(overflow: Double) -> Double {
        min(max(overflow / 20, 1), 120)
    }
}

/// A fitting label is just text. Only a focused, overflowing label owns an active display clock.
struct MarqueeLabel: View {
    let text: String
    let active: Bool
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced
    @State private var naturalWidth = 0.0
    @State private var started = Date.now

    var body: some View {
        Text(text)
            .lineLimit(1)
            .hidden()
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    let overflow = naturalWidth > proxy.size.width + 0.5
                    let scrolling = overflow && active && !reduced
                    TimelineView(.animation(paused: !scrolling)) { clock in
                        let offset = scrolling ? SettingsReadingMotion.marqueeOffset(
                            elapsed: clock.date.timeIntervalSince(started), width: naturalWidth / stage.scale) : 0
                        let lap = naturalWidth / stage.scale + SettingsReadingMotion.gap
                        // Hidden at the left: what has scrolled away, back to nothing as the next lap's text arrives; at the
                        // right: the rest of the text (MarqueeText's 28 and 36 px fades)
                        let hiddenStart = scrolling ? stage.px(min(offset, lap - offset)) : 0
                        let hiddenEnd = overflow ? (scrolling ? stage.px(lap) : naturalWidth - proxy.size.width) : 0
                        HStack(spacing: stage.px(SettingsReadingMotion.gap)) {
                            Text(text).fixedSize()
                                .onGeometryChange(for: Double.self) { $0.size.width } action: { naturalWidth = $0 }
                            if scrolling { Text(text).fixedSize() }
                        }
                        .offset(x: -stage.px(offset))
                        .frame(width: proxy.size.width, alignment: .leading)
                        .modifier(EdgeFadeMask(
                            hiddenStart: hiddenStart, hiddenEnd: hiddenEnd, axis: .horizontal,
                            start: FadeEdge(solid: stage.px(28)), end: FadeEdge(solid: min(stage.px(36), proxy.size.width))))
                        .clipped()
                    }
                    .onChange(of: active, initial: true) { _, _ in started = .now }
                    .onChange(of: text) { _, _ in started = .now }
                    .onChange(of: naturalWidth) { _, _ in started = .now }
                    .onChange(of: reduced) { _, _ in started = .now }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
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
