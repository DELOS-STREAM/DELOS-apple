import SwiftUI

/// The fade of one edge of a scrolling row or list at full strength, stage pixels from the edge inwards (`fadeMask` of
/// DELOS for Android): what lies beyond the edge is cut, the content is transparent up to [clear] and opaque from [solid].
struct FadeEdge: Equatable, Sendable {
    var solid: Double
    var clear = 0.0

    /// No fade at this edge.
    static let none = FadeEdge(solid: 0)

    /// The same edge in points.
    func points(_ stage: Stage) -> FadeEdge { FadeEdge(solid: stage.px(solid), clear: stage.px(clear)) }
}

/// The two fades of a scrolling row or list.
struct FadeEdges: Equatable, Sendable {
    var start: FadeEdge
    var end: FadeEdge

    init(start: FadeEdge, end: FadeEdge) {
        self.start = start
        self.end = end
    }

    /// Both edges fade over [length] stage pixels.
    init(_ length: Double) { self.init(start: FadeEdge(solid: length), end: FadeEdge(solid: length)) }

    /// A row of chips or pills (`ScrollRow`'s `edge` of DELOS for Android).
    static let row = FadeEdges(24)
    /// A row of tabs that does not fit (`tabScroll`).
    static let tabs = FadeEdges(40)
    /// The rows of a menu that is taller than its room (the context menu's `fadeMask`, 34 px beyond the glow's room).
    static let menu = FadeEdges(34)
}

/// The arithmetic of the fading edges (`fadeEdges(stage, scroll, …)` and `fadeMask` of DELOS for Android): an edge fades
/// only while content is hidden beyond it, and the fade grows with how much is hidden, from nothing to its full length once
/// that much is hidden; an edge with nothing beyond it is not faded at all, so the first and the last item's ring and glow
/// stay whole. All lengths are points.
enum EdgeFadeMath {
    /// How far an edge's fade has grown, 0 to 1: [hidden] points lie beyond it and the fade is [length] long.
    static func strength(hidden: Double, length: Double) -> Double {
        guard hidden > 0, length > 0 else { return 0 }
        return min(hidden / length, 1)
    }

    /// How much content lies hidden beyond the start and the end of a scroll view along its axis: the visible part spans
    /// [visibleStart] to [visibleEnd] of content [contentLength] long (content coordinates; a content inset puts the start
    /// below 0 and the end beyond the content at rest). Each is capped at [cap], beyond which no fade changes any more, so
    /// a long scroll through the middle reports no change.
    static func hidden(visibleStart: Double, visibleEnd: Double, contentLength: Double, cap: (start: Double, end: Double))
        -> (start: Double, end: Double)
    {
        (min(max(visibleStart, 0), cap.start), min(max(contentLength - visibleEnd, 0), cap.end))
    }

    /// The mask's gradient along an axis [length] points long that the mask exceeds by [bleed] points at both ends (room
    /// for a ring, glow or scale-up that reaches out of the scroll view, which is shown while nothing is hidden there):
    /// locations 0 to 1 over the mask's whole `length + 2 bleed`, and the opacity at each. At full strength an edge is clear
    /// through the bleed and its [FadeEdge/clear] and opaque from its [FadeEdge/solid]; the strength scales both, so a
    /// fade grows out of the edge as content scrolls behind it. Each edge keeps to its half of the mask.
    static func stops(length: Double, bleed: Double, start: FadeEdge, end: FadeEdge, strength: (start: Double, end: Double))
        -> [(location: Double, opacity: Double)]
    {
        let total = max(length + 2 * bleed, 1)
        func at(_ points: Double) -> Double { min(max(points / total, 0), 0.5) }
        let startClear = at((bleed + start.clear) * strength.start), startSolid = max(at((bleed + start.solid) * strength.start), startClear)
        let endClear = at((bleed + end.clear) * strength.end), endSolid = max(at((bleed + end.solid) * strength.end), endClear)
        return [
            (0, strength.start > 0 ? 0 : 1), (startClear, strength.start > 0 ? 0 : 1), (startSolid, 1),
            (1 - endSolid, 1), (1 - endClear, strength.end > 0 ? 0 : 1), (1, strength.end > 0 ? 0 : 1),
        ]
    }
}

/// Fades the two edges of [axis] by how much is hidden beyond each ([hiddenStart], [hiddenEnd], points), see
/// ``EdgeFadeMath``. Lengths are points. The mask reaches [bleed] beyond the edges along the axis and [outset] beyond the
/// sides across it, so a focused item's ring, glow and scale-up that reach out of the view are not cut while nothing is
/// hidden there. The hidden amounts animate, for a row that is moved by an animated offset (a marquee).
struct EdgeFadeMask: ViewModifier, Animatable {
    var hiddenStart: Double
    var hiddenEnd: Double
    let axis: Axis
    let start: FadeEdge
    let end: FadeEdge
    var bleed = 0.0
    var outset = 0.0

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(hiddenStart, hiddenEnd) }
        set { (hiddenStart, hiddenEnd) = (newValue.first, newValue.second) }
    }

    func body(content: Content) -> some View {
        let horizontal = axis == .horizontal
        content.mask {
            GeometryReader { proxy in
                let stops = EdgeFadeMath.stops(
                    length: Double(horizontal ? proxy.size.width : proxy.size.height), bleed: bleed, start: start, end: end,
                    strength: (EdgeFadeMath.strength(hidden: hiddenStart, length: start.solid),
                               EdgeFadeMath.strength(hidden: hiddenEnd, length: end.solid)))
                LinearGradient(
                    stops: stops.map { .init(color: .black.opacity($0.opacity), location: $0.location) },
                    startPoint: horizontal ? .leading : .top, endPoint: horizontal ? .trailing : .bottom)
                    .padding(horizontal ? .horizontal : .vertical, -bleed)
                    .padding(horizontal ? .vertical : .horizontal, -outset)
            }
        }
    }
}

/// The fading edges of a scroll view along [axis] (stage pixels): each edge fades as far as content is scrolled away
/// behind it (``EdgeFadeMath``). Put on the `ScrollView` itself, whose geometry it reads.
private struct ScrollEdgeFade: ViewModifier {
    let axis: Axis
    let fades: FadeEdges
    let bleed: Double
    let outset: Double
    @Environment(\.stage) private var stage
    @State private var hidden = Hidden()

    private struct Hidden: Equatable {
        var start = 0.0
        var end = 0.0
    }

    func body(content: Content) -> some View {
        let start = fades.start.points(stage), end = fades.end.points(stage)
        let horizontal = axis == .horizontal
        content
            .onScrollGeometryChange(for: Hidden.self) { geometry in
                let visible = geometry.visibleRect
                let amount = EdgeFadeMath.hidden(
                    visibleStart: horizontal ? visible.minX : visible.minY, visibleEnd: horizontal ? visible.maxX : visible.maxY,
                    contentLength: horizontal ? geometry.contentSize.width : geometry.contentSize.height, cap: (start.solid, end.solid))
                // Whole points: a fade that grows by less shows no difference, and the mask is not redrawn for it
                return Hidden(start: amount.start.rounded(), end: amount.end.rounded())
            } action: { _, now in
                // The fade follows the scroll as it is, never on an animation of its own
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { hidden = now }
            }
            .modifier(EdgeFadeMask(
                hiddenStart: hidden.start, hiddenEnd: hidden.end, axis: axis, start: start, end: end,
                bleed: stage.px(bleed), outset: stage.px(outset)))
    }
}

extension View {
    /// Fades the edges of the scroll view this is put on where content is scrolled away behind them (stage pixels; see
    /// ``EdgeFadeMath``): [bleed] is how far the mask reaches beyond the edges along [axis] (a scroll view that does not clip
    /// its content shows a ring or glow there), [outset] how far beyond its sides across it.
    func scrollEdgeFade(_ axis: Axis, _ fades: FadeEdges, bleed: Double = 0, outset: Double = 400) -> some View {
        modifier(ScrollEdgeFade(axis: axis, fades: fades, bleed: bleed, outset: outset))
    }
}
