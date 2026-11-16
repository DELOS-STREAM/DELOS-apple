import Observation
import SwiftUI

/// Session memory, not a profile preference or a value restored after relaunch.
@MainActor
@Observable
final class SettingsSession {
    static let shared = SettingsSession()
    var tab = SettingsTab.stream

    func opening(_ explicit: SettingsTab? = nil) -> SettingsTab {
        let requested = explicit ?? tab
        return SettingsTab.availableCases.contains(requested) ? requested : .stream
    }
}

enum SettingsPlateGeometry {
    static let duration = 0.520

    static func target(_ row: CGRect) -> CGRect {
        guard row.width > 0, row.height > 0 else { return .zero }
        return row.insetBy(dx: -row.width * 0.01, dy: -row.height * 0.01)
    }
}

struct SettingsRowAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Lives in the scrolling content's coordinate system: scrolling carries the plate with its target row.
struct SettingsFocusPlate: View {
    let target: CGRect?
    @State private var previous: CGRect?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced

    var body: some View {
        Group {
            if let frame = target ?? previous {
                RoundedRectangle(cornerRadius: stage.px(24))
                    .fill(colors.surface2.color)
                    .overlay(RoundedRectangle(cornerRadius: stage.px(24)).strokeBorder(colors.accent.color, lineWidth: stage.px(3)))
                    .shadow(color: colors.glow.color, radius: stage.px(25), y: stage.px(20))
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    // RowGlide.kt and Motion.kt: ROW_FOCUS / Glide, not the per-item focus spring.
                    .animation(reduced ? nil : .timingCurve(0.3, 1.22, 0.42, 1, duration: SettingsPlateGeometry.duration), value: target)
                    .opacity(target == nil ? 0 : 1)
                    .animation(.easeOut(duration: target == nil ? 0.28 : 0.12), value: target != nil)
            }
        }
        .onChange(of: target, initial: true) { _, frame in if let frame { previous = frame } }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum ScreenMotion {
    static let enter = 0.560
    static let fade = 0.280
    static let exit = 0.240
    static let scale = 1.035

    static func transition(reduced: Bool) -> AnyTransition {
        // MotionKit.kt:553–558: separate opacity/scale clocks, including the outward exit scale.
        let fadeIn = AnyTransition.opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: fade))
        let fadeOut = AnyTransition.opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: exit))
        if reduced { return .asymmetric(insertion: fadeIn, removal: fadeOut) }
        return .asymmetric(
            insertion: fadeIn.combined(with: .scale(scale: scale).animation(.timingCurve(0.16, 1, 0.3, 1, duration: enter))),
            removal: fadeOut.combined(with: .scale(scale: scale).animation(.timingCurve(0.5, 0, 0.75, 0, duration: exit))))
    }
}
