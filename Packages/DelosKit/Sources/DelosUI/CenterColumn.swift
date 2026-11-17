import SwiftUI

/// The numbers of a centered column on a compact stage (`CenterColumn` of DELOS for Android): the status bar and the hint
/// bar above and below it (which the interface scale zooms) stay clear, the sides keep the compact margin and the
/// scrolling column's cut edges fade over ``fade``.
enum CenterColumnLayout {
    static let statusBar = 104.0, hintBar = 92.0, margin = 48.0, fade = 48.0, scrollPad = 24.0

    /// Stage pixels kept clear above and below the column; none on a stage that is not compact.
    static func clearance(_ stage: Stage) -> (top: Double, bottom: Double) {
        guard stage.compact else { return (0, 0) }
        return (statusBar * stage.textScale + stage.safe.top, hintBar * stage.textScale + stage.safe.bottom)
    }

    /// Stage pixels kept clear at each side.
    static func side(_ stage: Stage) -> Double {
        stage.compact ? margin + max(stage.safe.leading, stage.safe.trailing) : 0
    }
}

/// The cut edges of a vertical scroll view fade over [top] and [bottom] stage pixels while more lies beyond them
/// (`fadeMask` of DELOS for Android); an edge with nothing beyond it stays solid, so the first and the last item's ring
/// and glow are not faded. The mask reaches [overdraw] stage pixels beyond the sides, which it does not cut.
struct ScrollEdgeFades: ViewModifier {
    let top: Double
    let bottom: Double
    let overdraw: Double
    @Environment(\.stage) private var stage
    @State private var more = ScrollMore()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollMore.self) { geometry in
                ScrollMore(
                    top: geometry.visibleRect.minY > 1,
                    bottom: geometry.visibleRect.maxY < geometry.contentSize.height - 1)
            } action: { _, now in more = now }
            .mask {
                GeometryReader { proxy in
                    let height = max(Double(proxy.size.height), 1)
                    let edge = (top: min(stage.px(top) / height, 0.45), bottom: min(stage.px(bottom) / height, 0.45))
                    LinearGradient(stops: [
                        .init(color: .black.opacity(more.top ? 0 : 1), location: 0),
                        .init(color: .black, location: more.top ? edge.top : 0),
                        .init(color: .black, location: 1 - (more.bottom ? edge.bottom : 0)),
                        .init(color: .black.opacity(more.bottom ? 0 : 1), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                    .padding(.horizontal, -stage.px(overdraw))
                }
            }
            .animation(.easeOut(duration: Motion.fade / 1000), value: more)
    }
}

extension View {
    /// Fades the cut edges of the scroll view this is applied to (see ``ScrollEdgeFades``).
    func scrollEdgeFades(top: Double, bottom: Double, overdraw: Double = 400) -> some View {
        modifier(ScrollEdgeFades(top: top, bottom: bottom, overdraw: overdraw))
    }
}

/// `.center-col`: a column in the middle of the stage whose [gap] shrinks on a compact stage. What is too tall for the
/// room (the avatar picker on an iPhone, large text) scrolls instead of running under the bars, and the focused item is
/// kept in view with room for its ring and glow; the cut edges fade while there is more beyond them.
struct CenterColumn<Content: View>: View {
    let gap: Double
    @ViewBuilder let content: () -> Content
    @Environment(\.stage) private var stage

    var body: some View {
        let clear = CenterColumnLayout.clearance(stage)
        let column = VStack(spacing: stage.px(gap * stage.compactScale), content: content)
            .frame(maxWidth: .infinity)
            .entranceScope()
        ViewThatFits(in: .vertical) {
            column
            FocusScroll(axis: .vertical, fades: (CenterColumnLayout.fade, CenterColumnLayout.fade)) {
                column.padding(.vertical, stage.px(CenterColumnLayout.scrollPad))
            }
            .focusable(false)
        }
        .padding(.top, stage.px(clear.top))
        .padding(.bottom, stage.px(clear.bottom))
        .padding(.horizontal, stage.px(CenterColumnLayout.side(stage)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Whether more of a scrolling column lies beyond its top and bottom edge.
struct ScrollMore: Equatable {
    var top = false
    var bottom = false
}
