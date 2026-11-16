import Observation
import SwiftUI

/// The short message at the bottom of the stage (a toast of DELOS for Android, without its kinds and stacking yet):
/// one at a time, a new one replaces the old, each goes away after a few seconds.
@MainActor
@Observable
final class Toasts {
    struct Toast: Equatable {
        let id = UUID()
        let text: String
        let icon: String
    }

    private(set) var current: Toast?
    @ObservationIgnored private var hide: Task<Void, Never>?

    func show(_ text: String, icon: String) {
        let toast = Toast(text: text, icon: icon)
        current = toast
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, self?.current == toast else { return }
            self?.current = nil
        }
    }
}

/// Shows the current toast: a glass pill with an icon, 72 stage pixels above the bottom edge.
struct ToastOverlay: View {
    let toasts: Toasts
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        VStack {
            Spacer()
            if let toast = toasts.current {
                HStack(spacing: stage.px(14)) {
                    SymbolView(symbol: toast.icon, size: 32, color: colors.accent, filled: true)
                    Text(toast.text)
                        .font(DelosFonts.figtree(stage.px(24), .semibold))
                        .foregroundStyle(colors.text.color)
                        .lineLimit(2)
                }
                .padding(.horizontal, stage.px(32))
                .frame(minHeight: stage.px(72))
                .background {
                    Capsule().fill(colors.surface2.color)
                        .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                }
                .id(toast.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, stage.px(72 + stage.safe.bottom))
        .animation(.easeOut(duration: 0.3), value: toasts.current)
        .allowsHitTesting(false)
    }
}
