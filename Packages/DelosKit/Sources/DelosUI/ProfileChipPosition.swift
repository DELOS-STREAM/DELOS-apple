import SwiftUI

/// Uses the same center-then-free-space rule as the compact status navigation. Values are points.
enum ProfileChipFit {
    static func frame(stageWidth: Double, start: Double, end: Double, idealWidth: Double) -> (x: Double, width: Double) {
        let width = min(idealWidth, max(0, end - start))
        return (StatusBarLayout.placeBetween(start: start, end: end, width: width, centre: stageWidth / 2) ?? start, width)
    }
}

struct ProfileChipPosition: ViewModifier {
    let stage: Stage
    let rightStart: Double?

    func body(content: Content) -> some View {
        if stage.compact {
            let fallback = stage.px(stage.width - StatusBarLayout.side - stage.safe.trailing - 360)
            CompactProfileChipLayout(start: stage.px(StatusBarLayout.side + stage.safe.leading),
                end: (rightStart ?? fallback) - stage.px(StatusBarLayout.minGap),
                top: stage.px(stage.safe.top), barHeight: stage.px(StatusBarLayout.height * stage.textScale)) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.padding(.top, stage.px(44 + stage.safe.top))
        }
    }
}

private struct CompactProfileChipLayout: Layout {
    let start: Double
    let end: Double
    let top: Double
    let barHeight: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let chip = subviews.first else { return }
        let ideal = chip.sizeThatFits(.unspecified)
        let fit = ProfileChipFit.frame(stageWidth: bounds.width, start: start, end: end, idealWidth: ideal.width)
        let proposal = ProposedViewSize(width: fit.width, height: nil)
        let size = chip.sizeThatFits(proposal)
        chip.place(at: CGPoint(x: bounds.minX + fit.x, y: bounds.minY + top + (barHeight - size.height) / 2),
            anchor: .topLeading, proposal: proposal)
    }
}
