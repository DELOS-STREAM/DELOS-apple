import DelosData
import SwiftUI

/// The offer after a problem (`ProblemOfferCard` of DELOS for Android; docs/DIAGNOSTICS.md): a Liquid Glass card in the middle
/// of the start and home screens, with what happened in one sentence, the one-line summary, a note on what Report does, and
/// Report this problem (A, with the GitHub mark: the report is a GitHub issue) beside Dismiss (B). With the report service a
/// second row offers saving the log instead. There is no scrim and nothing is asked before it leaves; it is offered once per
/// problem.
///
/// While it shows it has the controller's commands (``ShellRouter``): left and right move between its buttons, down reaches the
/// second row, A runs the focused one, B dismisses it. Touch reaches the screen under it as well. Apple TV, which can neither
/// save a file nor open the draft, offers Report only with the report service.
struct ProblemOfferCard: View {
    let offers: ProblemOffers
    let shown: Bool
    let onReport: @MainActor (ReportMode) -> Void
    let onDismiss: @MainActor () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion

    /// The card's width in stage pixels; on a compact stage it keeps 48 px from both edges.
    static let width = 936.0

    var body: some View {
        let compact = stage.compact
        ZStack {
            if shown, let problem = offers.problem {
                card(problem)
                    .frame(width: stage.px(compact ? min(Self.width, stage.width - 2 * 48) : Self.width))
                    .transition(reducedMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.3), value: shown && offers.problem != nil)
    }

    private func card(_ problem: Problem) -> some View {
        let uploads = ReportUploader.shared.enabled
        return VStack(alignment: .leading, spacing: stage.px(22)) {
            HStack(spacing: stage.px(26)) {
                ZStack {
                    Circle().fill(colors.accent.color)
                    SymbolView(symbol: Symbols.debug, size: 46, color: colors.onAccent, filled: true)
                }
                .frame(width: stage.px(84), height: stage.px(84))
                VStack(alignment: .leading, spacing: stage.px(6)) {
                    Text(Self.title(problem.kind))
                        .font(DelosFonts.unbounded(stage.tpx(28)))
                        .foregroundStyle(colors.text.color)
                    Text(Self.sentence(problem.kind))
                        .font(DelosFonts.figtree(stage.tpx(22)))
                        .lineSpacing(stage.tpx(22 * 0.35))
                        .foregroundStyle(colors.text2.color)
                }
            }
            Text(Self.summary(problem))
                .font(DelosFonts.figtree(stage.tpx(18)))
                .lineSpacing(stage.tpx(18 * 0.35))
                .foregroundStyle(colors.text3.color)
                .lineLimit(2)
                .truncationMode(.tail)
            Text(ReportOutcomeText.cardNote)
                .font(DelosFonts.figtree(stage.tpx(20)))
                .lineSpacing(stage.tpx(20 * 0.4))
                .foregroundStyle(colors.text2.color)
                .fixedSize(horizontal: false, vertical: true)
            // The buttons keep FocusSpacing's gaps; where Report and Dismiss do not fit side by side in the card (long labels
            // in some languages, a larger interface scale) they stand one above the other
            VStack(alignment: .leading, spacing: stage.px(FocusSpacing.pillLineGap)) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: stage.px(FocusSpacing.pillGap)) { answerButtons }
                    VStack(alignment: .leading, spacing: stage.px(FocusSpacing.pillLineGap)) { answerButtons }
                }
                if uploads, DiagnosticsExport.saveFolder != nil {
                    FocusItem(id: ProblemOffers.saveID, model: offers.focus, action: { onReport(.save) }) { focused in
                        PillButton(label: ReportOutcomeText.saveLabel, icon: Symbols.download, focused: focused)
                    }
                }
            }
            .padding(.top, stage.px(6))
        }
        .padding(stage.px(stage.compact ? 40 : 52))
        .background {
            GlassShape(RoundedRectangle(cornerRadius: stage.px(34)), tint: colors.surface, role: .panel)
                .overlay(RoundedRectangle(cornerRadius: stage.px(34)).strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
        .onAppear { if !ProblemOffers.canReport { offers.focus.focus(ProblemOffers.dismissID) } }
    }

    /// Report this problem (A) and Dismiss (B).
    @ViewBuilder private var answerButtons: some View {
        if ProblemOffers.canReport {
            FocusItem(id: ProblemOffers.reportID, model: offers.focus, action: { onReport(.upload) }) { focused in
                PillButton(label: L("shell_problem_report"), icon: Symbols.reportIssue, primary: true, focused: focused, glyph: .south)
            }
        }
        FocusItem(id: ProblemOffers.dismissID, model: offers.focus, clickCue: .back, action: onDismiss) { focused in
            PillButton(label: L("shell_problem_dismiss"), icon: Symbols.close, focused: focused, glyph: .east)
        }
    }

    static func title(_ kind: ProblemKind) -> String {
        kind == .streamFailed ? L("shell_problem_title_stream") : L("shell_problem_title_generic")
    }

    /// The sentence under the title: what happened the last time (`problemSentence`).
    static func sentence(_ kind: ProblemKind) -> String {
        switch kind {
        case .crash: L("diag_problem_java_crash")
        case .nativeCrash: L("diag_problem_native_crash")
        case .hang: L("diag_problem_anr")
        case .uncleanExit: L("diag_problem_unclean_exit")
        case .streamFailed: L("diag_problem_stream_failed")
        }
    }

    /// The line with the facts (`problemSummary`): the kind and the technical subject (the exception, the signal, the system's
    /// description, the failed stream's title), the subject shown as it was reported.
    static func summary(_ problem: Problem) -> String {
        let subject = String(problem.subject.prefix(Problem.summaryMax))
        let blank = subject.trimmingCharacters(in: .whitespaces).isEmpty
        switch problem.kind {
        case .crash:
            if !problem.viaExitRecord { return subject }
            return blank ? L("diag_problem_summary_crash") : L("diag_problem_summary_crash_with", subject)
        case .nativeCrash:
            return blank ? L("diag_problem_summary_native_crash") : L("diag_problem_summary_native_crash_with", subject)
        case .hang:
            return blank ? L("diag_problem_summary_hang") : L("diag_problem_summary_hang_with", subject)
        case .uncleanExit:
            return L("diag_problem_summary_unclean_exit")
        case .streamFailed:
            return subject
        }
    }
}
