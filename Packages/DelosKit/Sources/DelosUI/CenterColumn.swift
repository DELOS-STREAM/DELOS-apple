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

    /// The column's gap in stage pixels: [gap] times the compact scale, at least [min].
    static func gap(_ gap: Double, min: Double, _ stage: Stage) -> Double { max(gap * stage.compactScale, min) }
}

/// `.center-col`: a column in the middle of the stage whose [gap] shrinks on a compact stage, never below [minGap] (the
/// least gap focusable items one above the other need, ``FocusSpacing``). What is too tall for the room (the avatar picker
/// on an iPhone, large text) scrolls instead of running under the bars, and the focused item is kept in view with room for
/// its ring and glow; the cut edges fade while there is more beyond them.
struct CenterColumn<Content: View>: View {
    let gap: Double
    var minGap = 0.0
    @ViewBuilder let content: () -> Content
    @Environment(\.stage) private var stage

    var body: some View {
        let clear = CenterColumnLayout.clearance(stage)
        let column = VStack(spacing: stage.px(CenterColumnLayout.gap(gap, min: minGap, stage)), content: content)
            .frame(maxWidth: .infinity)
            .entranceScope()
        ViewThatFits(in: .vertical) {
            column
            FocusScroll(axis: .vertical, fades: FadeEdges(CenterColumnLayout.fade)) {
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
