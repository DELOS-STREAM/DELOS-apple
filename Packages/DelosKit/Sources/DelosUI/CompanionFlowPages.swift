import DelosData
import SwiftUI

/*
 * The pages of the launch and connect flow on the companion screen (`CompanionFlowData.kt`, `CompanionFlowPages.kt` and
 * `CompanionFlowPublisher.kt` of DELOS for Android; docs/DUAL_SCREEN.md, "Launch and connect"): the loader of a game that
 * is starting, a portal the shell waits in, the result of a stream that ended and the problem of a start that failed.
 * They are data plus the owner's own callbacks, and every one is an overlay. The wording is chosen against the panel's
 * budgets, in whole sentences only. Android's `ReportPage` (the problem report card) is not ported: this app has no
 * problem reports yet.
 */

// MARK: - Data and pure choices

/// How far a stream start has got, as far as the app really knows (`StartStage`, CompanionFlowData.kt:17-31): never a
/// percentage. Here the launch request is ``StreamSteps/launch(display:)``; the first connection stage the core reports
/// comes after it was accepted, and the connection that starts ends the loader.
enum CompanionStartStage: Hashable, Sendable {
    /// The launch request is being sent.
    case launching
    /// The PC accepted the launch: the streams are being set up and the first video is awaited.
    case connecting
    /// The connection runs: only the first picture is awaited.
    case connected

    /// The stage of a controller that is still connecting: the launch was accepted once a connection stage was told
    /// (``StreamController/progress`` grows with each one from 0).
    static func of(progress: Double) -> CompanionStartStage { progress > 0 ? .connecting : .launching }
}

/// The named steps of the loader (`StepKind`): each one is an event the app really observes.
enum CompanionStepKind: Int, CaseIterable, Hashable, Sendable { case hostFound, launchAccepted, waitingVideo, streamReady }

enum CompanionStepMark: Hashable, Sendable { case done, current, pending }

/// One shown line of the step list; [hiddenAfter] is the number of pending steps folded into it ("+1 pending").
struct CompanionStepRow: Hashable, Sendable {
    let kind: CompanionStepKind
    let mark: CompanionStepMark
    var hiddenAfter = 0
}

/// The step list of the loader (`FlowSteps`, CompanionFlowData.kt:43-76).
enum CompanionFlowSteps {
    /// The rows a panel gives the list: all four on a tall panel, three on a short one.
    static func rowBudget(_ budget: FitBudget) -> Int { budget.roomy ? 4 : 3 }

    /// The four steps with their marks: exactly one is current, the ones before it done, the ones after it pending.
    static func steps(_ stage: CompanionStartStage) -> [(kind: CompanionStepKind, mark: CompanionStepMark)] {
        let current: CompanionStepKind = switch stage {
        case .launching: .launchAccepted
        case .connecting: .waitingVideo
        case .connected: .streamReady
        }
        return CompanionStepKind.allCases.map { kind in
            (kind, kind == current ? .current : kind.rawValue < current.rawValue ? .done : .pending)
        }
    }

    /// The steps cut to [maxRows]: trailing pending steps fold into the count on the last shown row; when the current step
    /// would still not show, the oldest completed steps leave first. The current step is always shown.
    static func rows(_ stage: CompanionStartStage, maxRows: Int) -> [CompanionStepRow] {
        let all = steps(stage)
        if all.count <= maxRows { return all.map { CompanionStepRow(kind: $0.kind, mark: $0.mark) } }
        let current = all.firstIndex { $0.mark == .current } ?? 0
        let first = max(current - (maxRows - 1), 0)
        let end = first + maxRows
        return (first..<end).map { i in
            CompanionStepRow(kind: all[i].kind, mark: all[i].mark, hiddenAfter: i == end - 1 ? all.count - end : 0)
        }
    }
}

/// What the loader says about the game it starts (`FlowLoader`).
struct CompanionFlowLoader: Hashable, Sendable {
    /// The game, nil when its name is not known.
    let game: String?
    let pc: String
    let pcID: String
    /// The requested picture as the launch scene tells it ("1920 × 1080 · HEVC · 120 FPS"), nil while unknown.
    let requested: String?
    let stage: CompanionStartStage
    /// Cancel is offered (there is a path that really stops the start).
    let cancellable: Bool
}

/// What kind of end a stream result tells (`StreamResultKind`).
enum CompanionResultKind: Hashable, Sendable {
    /// The start failed before the stream ran: the problem page.
    case failedToStart
    /// The PC ended the stream.
    case hostClosed
    /// The connection was lost.
    case lost

    /// The kind of a result overlay: a failure while the stream was still connecting is a failed start; after it ran, the
    /// "closed" title (``StreamText/termination(_:)``) is the PC's end, every other one a lost connection.
    static func of(title: String, whileStarting: Bool, closedTitle: String) -> CompanionResultKind {
        if whileStarting { return .failedToStart }
        return title == closedTitle ? .hostClosed : .lost
    }
}

/// What a result of a stream that ended is made of (`FlowResult`).
struct CompanionFlowResult: Hashable, Sendable {
    let kind: CompanionResultKind
    let title: String
    let sentence: String
    /// The technical text behind Details on the main display, nil when there is none.
    let details: String?
    let game: String
    let pc: String
    let pcID: String
}

/// The texts of the flow pages, cut to the panel (`FlowText`, CompanionFlowData.kt:108-195).
enum CompanionFlowText {
    /// The first of [candidates] that fits one line of [width] (nil when none does).
    static func oneLine(_ candidates: [String], width: Double, metrics: some CompanionTextMetrics, kind: FitText = .body) -> String? {
        candidates.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && metrics.lines($0, width: width, kind: kind) <= 1 }
    }

    /// A short name for a PC whose own name does not fit: "PC · 7C2A" (the prefix alone when the PC has no id).
    static func pcAlias(_ prefix: String, id: String) -> String {
        id.contains { $0.isLetter || $0.isNumber } ? CompanionFit.alias(prefix, id: id) : prefix
    }

    /// The title of a heading: the first of [candidates] that fits one line, else the last one (an authored short title).
    static func title(_ candidates: [String], width: Double, metrics: some CompanionTextMetrics) -> String {
        oneLine(Array(candidates.dropLast()), width: width, metrics: metrics, kind: .title) ?? candidates.last ?? ""
    }

    /// "game · PC" under a heading: the whole line, then with the PC's alias, then the game alone, then the PC alone; the
    /// alias when nothing fits (a blank game or PC is left out).
    static func gameAndPC(game: String, pc: String, alias: String, width: Double, metrics: some CompanionTextMetrics) -> String {
        func both(_ name: String) -> String {
            [game, name].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " \u{00B7} ")
        }
        return oneLine([both(pc), both(alias), game, pc], width: width, metrics: metrics) ?? alias
    }

    /// The requested settings from the long to the short form: everything, the first and the last part (the codec left
    /// out), the first part.
    static func requestedForms(_ requested: String?) -> [String] {
        let parts = (requested ?? "").components(separatedBy: " \u{00B7} ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = parts.first, let last = parts.last else { return [] }
        let forms = [parts.joined(separator: " \u{00B7} "), parts.count >= 3 ? "\(first) \u{00B7} \(last)" : nil, first].compactMap { $0 }
        return forms.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// The loader's line under its title: "PC · requested …" in the longest form that fits one line (the PC's alias when its
    /// name is too long), else the PC alone; [format] joins the PC and the settings.
    static func requestedLine(
        pc: String, alias: String, requested: String?, format: (String, String) -> String, width: Double, metrics: some CompanionTextMetrics
    ) -> String {
        var candidates: [String] = []
        for name in [pc, alias] where !name.trimmingCharacters(in: .whitespaces).isEmpty {
            candidates += requestedForms(requested).map { format(name, $0) }
        }
        candidates += [pc, alias]
        return oneLine(candidates, width: width, metrics: metrics) ?? alias
    }

    /// The text of a result in the body budget, of whole sentences only: what happened and what to do next; when both do
    /// not fit, the sentence with the short guidance, then the guidance, then the short guidance, then [last].
    static func resultBody(
        sentence: String, guidance: String, guidanceShort: String, budget: FitBudget, metrics: some CompanionTextMetrics, last: String
    ) -> String {
        let candidates = [[sentence, guidance], [sentence, guidanceShort], [guidance], [guidanceShort]]
            .map { $0.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ") }
        return candidates.first { !$0.isEmpty && metrics.lines($0, width: budget.innerWidth) <= budget.bodyLines } ?? last
    }

    /// The first line of a failure's technical text (the failing stage and its code) when it fits [maxLines]; else nil.
    static func errorLine(_ details: String?, maxLines: Int, width: Double, metrics: some CompanionTextMetrics) -> String? {
        guard let line = details?.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }),
              metrics.lines(line, width: width) <= maxLines else { return nil }
        return line
    }

    /// The error text of a failed start: what the app says plus the technical lines after the first one, cut at a sentence
    /// in the error budget; [short] and [last] are the authored fallbacks.
    static func errorText(
        sentence: String, details: String?, short: String, budget: FitBudget, metrics: some CompanionTextMetrics, last: String
    ) -> String {
        let rest = (details ?? "").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.dropFirst()
        let full = ([sentence.trimmingCharacters(in: .whitespaces)] + rest).filter { !$0.isEmpty }.joined(separator: "\n")
        return CompanionFit.summary(full, short: short, maxLines: budget.errorLines, width: budget.innerWidth, metrics: metrics, last: last)
    }

    /// The recovery sentence in its two lines; empty when even the short form does not fit.
    static func recovery(_ full: String, short: String, budget: FitBudget, metrics: some CompanionTextMetrics) -> String {
        CompanionFit.summary(full, short: short, maxLines: budget.recoveryLines, width: budget.innerWidth, metrics: metrics, last: "")
    }

    /// The text under the portal's heading: [sub] in whole sentences within the body budget, empty when nothing fits.
    static func portalNote(_ sub: String, budget: FitBudget, metrics: some CompanionTextMetrics) -> String {
        CompanionFit.summary(sub, short: "", maxLines: budget.bodyLines, width: budget.innerWidth, metrics: metrics, last: "")
    }
}

/// The red of an error line (`LowRed`).
private let companionErrorRed = RGBA(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)

// MARK: - Loader

/// A game that is starting (`LoaderPage`, CompanionFlowPages.kt:32-63): its named steps, the picture asked for, and Cancel
/// while the start can still be cancelled. Waited at, so it never dims. One key for every loader, so a new stage is an update.
enum CompanionLoaderPage {
    static let key = "flow/loader"

    static func page(_ data: CompanionFlowLoader, onCancel: @escaping @MainActor () -> Void) -> CompanionPage {
        CompanionPage(key: key, priority: PagePriority.overlay, keepsAwake: true, revision: data) {
            CompanionLoaderCard(data: data, onCancel: data.cancellable ? onCancel : nil)
        }
    }
}

extension CompanionStream {
    /// The loader page while the stream is still starting (``StreamController/Phase/connecting``), nil once it runs, leaves
    /// or failed (`CompanionHost.forStream`). Cancel is the loader's own cancel (``StreamController/cancelLoader()``, B on
    /// the main screen). Android keeps the page until the first frame; here the loader's end is not observable, so the
    /// stream's own content takes over as soon as the connection runs.
    @MainActor var loaderPage: CompanionPage? {
        guard controller.phase == .connecting else { return nil }
        let data = CompanionFlowLoader(
            game: gameName.isEmpty ? nil : gameName, pc: pcName, pcID: pcID, requested: requested,
            stage: .of(progress: controller.progress), cancellable: controller.loaderCancellable)
        return CompanionLoaderPage.page(data) { [controller] in Task { await controller.cancelLoader() } }
    }
}

private struct CompanionLoaderCard: View {
    let data: CompanionFlowLoader
    let onCancel: (@MainActor () -> Void)?
    @Environment(\.delosColors) private var colors
    @State private var pressed = false

    var body: some View {
        PageCard { fit in
            let b = fit.budget
            let width = b.innerWidth - PageHeading.chrome
            let generic = L("companion_flow_starting_generic")
            let title = data.game.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                .map { CompanionFlowText.title([L("companion_flow_starting", $0), generic], width: width, metrics: fit.metrics) } ?? generic
            let alias = CompanionFlowText.pcAlias(L("companion_flow_pc"), id: data.pcID)
            let line = CompanionFlowText.requestedLine(
                pc: data.pc, alias: alias, requested: data.requested, format: { L("companion_flow_requested", $0, $1) }, width: width,
                metrics: fit.metrics)
            PageHeading(icon: Symbols.playArrow, title: title, subtitle: line)
            CompanionStepList(rows: CompanionFlowSteps.rows(data.stage, maxRows: CompanionFlowSteps.rowBudget(b)))
            BodyText(L("companion_flow_no_percentage"), color: colors.text2).optional(40)
            Filler()
            if let onCancel {
                ActionRow(actions: [PageAction(label: L("companion_flow_cancel_start"), enabled: !pressed) {
                    pressed = true
                    onCancel()
                }])
            }
        }
    }
}

/// The lines of the step list: a mark and the step's name; pending steps beyond the rows say "+N pending".
private struct CompanionStepList: View {
    let rows: [CompanionStepRow]
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        VStack(alignment: .leading, spacing: stage.px(8)) {
            ForEach(rows, id: \.kind) { row in
                let name = switch row.kind {
                case .hostFound: L("companion_flow_step_host")
                case .launchAccepted: L("companion_flow_step_launch")
                case .waitingVideo: L("companion_flow_step_video")
                case .streamReady: L("companion_flow_step_ready")
                }
                let text = row.hiddenAfter > 0
                    ? L("companion_flow_step_more", name, row.hiddenAfter) : row.mark == .pending ? L("companion_flow_step_pending", name) : name
                let color = switch row.mark {
                case .done: colors.accent2
                case .current: colors.accent
                case .pending: colors.text
                }
                let icon = switch row.mark {
                case .done: Symbols.check
                case .current: Symbols.refresh
                case .pending: row.kind == .streamReady ? Symbols.playArrow : Symbols.schedule
                }
                HStack(spacing: stage.px(12)) {
                    SymbolView(symbol: icon, size: 34, color: color)
                    BodyText(text, color: color, maxLines: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Portal

/// A portal the shell waits in (`PortalPage`, CompanionFlowPages.kt:69-96): a PC that connects or wakes up, the exit of a
/// stream. The portal's own words as they are, no invented steps; Cancel only where the portal can be cancelled.
enum CompanionPortalPage {
    static func page(_ portal: Portal, onCancel: (@MainActor () -> Void)?) -> CompanionPage {
        CompanionPage(key: "flow/portal", priority: PagePriority.overlay, keepsAwake: true, revision: CompanionPortalRevision(portal: portal)) {
            CompanionPortalCard(portal: portal, onCancel: portal.cancellable ? onCancel : nil)
        }
    }
}

/// What the portal page shows (the burst's `arriving` and the portal's number do not change it).
private struct CompanionPortalRevision: Hashable {
    let icon: String
    let label: String
    let sub: String
    let cancellable: Bool

    init(portal: Portal) {
        icon = portal.icon
        label = portal.label
        sub = portal.sub
        cancellable = portal.cancellable
    }
}

private struct CompanionPortalCard: View {
    let portal: Portal
    let onCancel: (@MainActor () -> Void)?
    @Environment(\.delosColors) private var colors
    @State private var pressed = false

    var body: some View {
        PageCard { fit in
            let b = fit.budget
            let title = CompanionFlowText.title([portal.label, L("companion_flow_wait")], width: b.innerWidth - PageHeading.chrome, metrics: fit.metrics)
            PageHeading(icon: portal.icon, title: title)
            // A label too long for the title is still said, in whole sentences
            let said = title == portal.label ? portal.sub : [portal.label, portal.sub].filter { !$0.isEmpty }.joined(separator: "\n")
            let note = CompanionFlowText.portalNote(said, budget: b, metrics: fit.metrics)
            if !note.isEmpty { BodyText(note, color: colors.text).optional(50) }
            BodyText(L("companion_flow_no_percentage"), color: colors.text2).optional(40)
            Filler()
            if let onCancel {
                ActionRow(actions: [PageAction(label: L("common_cancel"), enabled: !pressed) {
                    pressed = true
                    onCancel()
                }])
            }
        }
    }
}

extension View {
    /// Publishes [portal] while it is up (`PublishCompanionOverlays`, the portal branch): Cancel runs [onCancel], the very
    /// tap the portal's scrim runs.
    func companionPortal(_ portal: Portal, onCancel: @escaping @MainActor () -> Void) -> some View {
        companionPage { CompanionPortalPage.page(portal, onCancel: onCancel) }
    }
}

// MARK: - Result and problem

/// A stream that ended after it had run, or that the PC ended (`ResultPage`, CompanionFlowPages.kt:103-136): the result's
/// title, the game and the PC, what happened and what to do next, Reconnect and Back to library (the result layer's own
/// callbacks). It never claims the game stopped.
enum CompanionResultPage {
    static func page(_ data: CompanionFlowResult, onReconnect: @escaping @MainActor () -> Void, onBack: @escaping @MainActor () -> Void) -> CompanionPage {
        if data.kind == .failedToStart {
            return CompanionPage(key: "flow/problem", priority: PagePriority.overlay, revision: data) {
                CompanionProblemCard(data: data, onTryAgain: onReconnect, onBack: onBack)
            }
        }
        return CompanionPage(key: "flow/result", priority: PagePriority.overlay, revision: data) {
            CompanionResultCard(data: data, onReconnect: onReconnect, onBack: onBack)
        }
    }
}

private struct CompanionResultCard: View {
    let data: CompanionFlowResult
    let onReconnect: @MainActor () -> Void
    let onBack: @MainActor () -> Void
    @Environment(\.delosColors) private var colors

    var body: some View {
        PageCard { fit in
            let b = fit.budget
            let width = b.innerWidth - PageHeading.chrome
            let title = CompanionFlowText.title([data.title, L("companion_flow_result_title")], width: width, metrics: fit.metrics)
            let alias = CompanionFlowText.pcAlias(L("companion_flow_pc"), id: data.pcID)
            PageHeading(
                icon: Symbols.info, title: title,
                subtitle: CompanionFlowText.gameAndPC(game: data.game, pc: data.pc, alias: alias, width: width, metrics: fit.metrics))
            let closed = data.kind == .hostClosed
            BodyText(CompanionFlowText.resultBody(
                sentence: data.sentence, guidance: L(closed ? "companion_flow_closed_guidance" : "companion_flow_lost_guidance"),
                guidanceShort: L(closed ? "companion_flow_closed_short" : "companion_flow_lost_short"), budget: b, metrics: fit.metrics,
                last: L("companion_see_main")), color: colors.text)
            Filler()
            ActionRow(actions: [
                PageAction(label: L("companion_flow_reconnect"), style: .primary, icon: Symbols.refresh, run: onReconnect),
                PageAction(label: L("shell_hint_back_to_library"), icon: Symbols.library, run: onBack),
            ])
        }
    }
}

/// A start that failed (`ProblemPage` and `ProblemCard`, CompanionFlowPages.kt:143-235): the failing stage and its code in
/// red, the error in the error budget, what to check in accent, the note that the full error stays on the main display
/// (tall panels), Try again and Back.
private struct CompanionProblemCard: View {
    let data: CompanionFlowResult
    let onTryAgain: @MainActor () -> Void
    let onBack: @MainActor () -> Void
    @Environment(\.delosColors) private var colors

    var body: some View {
        PageCard { fit in
            let b = fit.budget
            let width = b.innerWidth - PageHeading.chrome
            let alias = CompanionFlowText.pcAlias(L("companion_flow_pc"), id: data.pcID)
            PageHeading(
                icon: Symbols.warning, title: L("companion_flow_problem_title"),
                subtitle: CompanionFlowText.gameAndPC(game: data.game, pc: data.pc, alias: alias, width: width, metrics: fit.metrics))
            if let line = CompanionFlowText.errorLine(data.details, maxLines: b.roomy ? 2 : 1, width: b.innerWidth, metrics: fit.metrics) {
                BodyText(line, color: companionErrorRed).optional(60)
            }
            BodyText(CompanionFlowText.errorText(
                sentence: data.sentence, details: data.details, short: L("companion_flow_error_short"), budget: b, metrics: fit.metrics,
                last: L("companion_see_main")), color: colors.text)
            let recovery = CompanionFlowText.recovery(L("companion_flow_recovery"), short: L("companion_flow_recovery_short"), budget: b, metrics: fit.metrics)
            if !recovery.isEmpty { BodyText(recovery, color: colors.accent).optional(70) }
            if b.roomy { BodyText(L("companion_flow_full_on_main"), color: colors.text3).optional(30) }
            Filler()
            ActionRow(actions: [
                PageAction(label: L("stream_result_try_again"), style: .primary, icon: Symbols.refresh, run: onTryAgain),
                PageAction(label: L("shell_hint_back"), icon: Symbols.arrowBack, run: onBack),
            ])
        }
    }
}

extension View {
    /// The stream's side of the flow pages (`PublishCompanionOverlays` and `CompanionHost.forStream`): tells the bound
    /// stream the requested picture once the display is known, and publishes the result overlay of [controller] as the
    /// result or the problem page, with [onRetry] and [onBack] the result layer's own callbacks.
    func companionStreamFlow(
        controller: StreamController, requested: String?, pcID: String,
        onRetry: @escaping @MainActor () -> Void, onBack: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(CompanionStreamFlow(controller: controller, requested: requested, pcID: pcID, onRetry: onRetry, onBack: onBack))
    }
}

private struct CompanionStreamFlow: ViewModifier {
    let controller: StreamController
    let requested: String?
    let pcID: String
    let onRetry: @MainActor () -> Void
    let onBack: @MainActor () -> Void
    /// The current attempt reached the running stream (set before any result comes): a result without it is a failed start.
    @State private var streamed = false

    func body(content: Content) -> some View {
        content
            .onChange(of: controller.phase, initial: true) { _, now in
                switch now {
                case .connecting: streamed = false
                case .streaming: streamed = true
                case .leaving, .failed, .ended: break
                }
            }
            .onChange(of: requested, initial: true) { _, now in
                let hub = CompanionHub.shared
                if hub.stream?.controller === controller, hub.stream?.requested != now { hub.stream?.requested = now }
            }
            .companionPage {
                guard case .failed(let text) = controller.phase else { return nil }
                let data = CompanionFlowResult(
                    kind: .of(title: text.title, whileStarting: !streamed, closedTitle: L("stream_result_closed_title")),
                    title: text.title, sentence: text.sentence, details: text.details, game: controller.appName, pc: controller.pcName, pcID: pcID)
                return CompanionResultPage.page(data, onReconnect: onRetry, onBack: onBack)
            }
    }
}
