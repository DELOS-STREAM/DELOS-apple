import DelosInput
import SwiftUI

/// When a piece of chrome is shown, by the kind of input in use (``InputKind``).
enum InputKindRule: Sendable {
    /// For fingers, pointers and keyboards: hidden while a controller is the input (its buttons do the same: the back
    /// arrow of the bars, the back chip of a submenu).
    case withoutController
    /// For a controller only.
    case withController

    func shows(_ kind: InputKind) -> Bool {
        switch self {
        case .withoutController: kind != .controller
        case .withController: kind == .controller
        }
    }
}

extension View {
    /// Shows this view by [rule] and the kind of input in use (``ControllerGlyphs/kind``), live: it fades in or out with a
    /// small scale and slide, and the layout around it follows (it takes its width, and [gap] after it, only while
    /// shown). Reduced motion: a plain fade. A view that is hidden takes no touches and is hidden from accessibility.
    /// The one component for chrome that depends on the input kind.
    func inputKindVisibility(_ rule: InputKindRule, gap: Double = 0) -> some View {
        modifier(InputKindVisibilityModifier(rule: rule, gap: gap))
    }
}

private struct InputKindVisibilityModifier: ViewModifier {
    let rule: InputKindRule
    let gap: Double
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced

    func body(content: Content) -> some View {
        let shown = rule.shows(ControllerGlyphs.shared.kind)
        RevealLayout(progress: shown ? 1 : 0, gap: stage.px(gap)) {
            content
                .opacity(shown ? 1 : 0)
                .scaleEffect(shown || reduced ? 1 : Motion.popFromScale, anchor: .leading)
                .offset(x: shown || reduced ? 0 : -stage.px(Motion.chevronBumpDistance * 2))
                .allowsHitTesting(shown)
                .accessibilityHidden(!shown)
        }
        .animation(reduced ? .easeOut(duration: Motion.fade / 1000) : Motion.out(Motion.rowIn), value: shown)
    }
}

/// Lays out its one child at its own size times [progress] in width, plus [gap] after it: the neighbors glide as it
/// comes and goes.
private struct RevealLayout: Layout {
    var progress: Double
    var gap: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(progress, gap) }
        set { (progress, gap) = (newValue.first, newValue.second) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(.unspecified)
        return CGSize(width: (size.width + gap) * progress, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
    }
}
