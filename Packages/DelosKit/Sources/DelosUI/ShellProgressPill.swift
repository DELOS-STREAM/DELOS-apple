import SwiftUI

/// How far a run over many games is: [done] of [total] (`ArtworkProgress` of DELOS for Android).
struct ShellProgress: Equatable, Sendable {
    var done: Int
    var total: Int

    /// The bar's share, 0 for an empty run.
    var fraction: Double { total == 0 ? 0 : min(Double(done) / Double(total), 1) }

    /// What the pill shows: the artwork download when one runs, else the metadata lookup (`Shell.kt`'s
    /// `ArtworkProgressBar(artworkProgress ?: metadata.progress)`); nil when neither runs.
    static func shown(artwork: ShellProgress?, metadata: ShellProgress?) -> (progress: ShellProgress, label: String)? {
        if let artwork { return (artwork, L("shell_progress_artwork")) }
        if let metadata { return (metadata, L("shell_progress_metadata")) }
        return nil
    }
}

/// Downloading artwork or looking up metadata (`ArtworkProgressBar`): a 620 px glass pill above the button hints, on every
/// screen, with a spinner, what runs, "x of N" and a bar. It rises in while a run goes and fades out once it ends.
struct ShellProgressPill: View {
    let shown: (progress: ShellProgress, label: String)?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion

    var body: some View {
        ZStack {
            if let shown {
                pill(shown.progress, label: shown.label)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.3))
                            .combined(with: .offset(y: reducedMotion ? 0 : stage.px(56)).animation(.easeOut(duration: 0.4))),
                        removal: .opacity.animation(.easeOut(duration: 0.4))))
            }
        }
        .animation(.easeOut(duration: 0.4), value: shown != nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, stage.px(118))
        .allowsHitTesting(false)
    }

    private func pill(_ progress: ShellProgress, label: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: stage.px(26))
        return VStack(spacing: stage.px(12)) {
            HStack(spacing: stage.px(14)) {
                RingSpinner(size: 28, color: colors.accent2)
                Text(label)
                    .font(DelosFonts.figtree(stage.tpx(22), .semibold))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L("shell_progress_count", progress.done, progress.total))
                    .font(DelosFonts.figtree(stage.tpx(22)))
                    .monospacedDigit()
                    .foregroundStyle(colors.text2.color)
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(LinearGradient(colors: [colors.accent.color, colors.accent2.color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * progress.fraction)
                    .animation(.easeOut(duration: 0.5), value: progress.fraction)
            }
            .frame(height: stage.px(8))
            .background(Capsule().fill(colors.surface2.color))
            .clipShape(Capsule())
        }
        .padding(.horizontal, stage.px(26))
        .padding(.vertical, stage.px(18))
        .frame(width: stage.px(620))
        .background(GlassShape(shape, tint: colors.surface3, role: .panel))
        .overlay(shape.strokeBorder(colors.line.color, lineWidth: stage.px(1)))
    }
}
