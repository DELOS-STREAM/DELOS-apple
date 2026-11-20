import Combine
import DelosCore
import DelosData
import DelosInput
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Debug info (Settings → About → Debug info; `DebugInfoScreen` of DELOS for Android), in the style of the settings: the device
/// (its system, kernel, model and vibration motor), its displays, the diagnostic log (a preview of exactly what a problem report
/// contains, Report, Share, Copy summary and Clear; docs/DIAGNOSTICS.md), the haptic capabilities and the vibration and rumble
/// tests (``DebugRumbleLab``), the on-screen controls' preview and every connected controller. The panel on the right shows the
/// focused row's description and its technical details; on a compact stage it is a dock under the list.
///
/// Controller: up and down move between the rows, left and right change a slider or switch, A runs the row, B goes back.
/// Touch: a tap focuses a row, a tap on the focused row runs it; a row that only runs something runs at once.
struct DebugInfoScreen: View {
    let profileID: String
    let focus: FocusModel
    let navigator: Navigator
    let feedback: Feedback?
    let actions: ShellActions
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.scenePhase) private var scenePhase
    @State private var lab: DebugRumbleLab?
    /// The diagnostic report exactly as it would be shared now; nil while it is being built.
    @State private var report: DiagnosticReport?
    @State private var reportRun = 0
    @State private var displays = DisplayFacts.all()

    private var export: DiagnosticsExport {
        DiagnosticsExport(hosts: actions.hosts, profiles: actions.profiles, artwork: actions.artwork)
    }

    private var rows: [DebugRow] {
        let all = deviceRows + displayRows + diagnosticRows + (lab?.rows() ?? []) + oscRows
        // The lab's controllers come after the on-screen controls, as on Android: the sections in their order, each row kept in place
        return DebugSection.allCases.flatMap { section in all.filter { $0.section == section } }
    }

    private var focusedRow: DebugRow? { rows.first { focus.focused == AnyHashable($0.id) } }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                navigator.takeInput(focus) { command in capture(command) }
                if lab == nil { lab = DebugRumbleLab(profileID: profileID, toasts: actions.toasts) }
                // The first row, every time the screen opens (Android's first-row request): the rows register their frames
                // before this runs, and the first one to report would otherwise keep the focus, possibly far down the list
                if let first = rows.first { focus.focus(AnyHashable(first.id)) }
            }
            .onDisappear {
                navigator.releaseInput(focus)
                lab?.stopAll()
            }
            .task(id: reportRun) { report = await export.report() }
            // A continuous test repeats until it is cancelled, so it must not go on while the app is in the background
            .onChange(of: scenePhase) { _, now in if now != .active { lab?.stopAll() } }
            .onChange(of: focus.focused, initial: true) {
                navigator.setHints(ScreenHints(adjustable: ShellHints.adjustable(focusedRow.map(\.settingRow))), from: focus)
            }
            .onReceive(Self.displaysChanged) { _ in displays = DisplayFacts.all() }
    }

    /// A display connected, removed or changed.
    #if os(macOS)
    private static var displaysChanged: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
    }
    #else
    private static var displaysChanged: Publishers.Merge3<NotificationCenter.Publisher, NotificationCenter.Publisher, NotificationCenter.Publisher> {
        let center = NotificationCenter.default
        return Publishers.Merge3(center.publisher(for: UIScene.willConnectNotification), center.publisher(for: UIScene.didDisconnectNotification),
                                 center.publisher(for: UIScreen.modeDidChangeNotification))
    }
    #endif

    // MARK: Rows

    private var deviceRows: [DebugRow] {
        let kernel = DeviceFacts.kernel
        let system = DeviceFacts.system
        let name = system.components(separatedBy: " ").first ?? system
        let version = system.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        let motor = DeviceHardware.haptics
        return [
            DebugRow(id: "system", section: .device, icon: Symbols.version, label: name,
                value: .info("\(version) · \(DeviceFacts.systemBuild)"), description: L("debug_system_description")),
            DebugRow(id: "kernel", section: .device, icon: Symbols.memory, label: L("debug_kernel_label"), value: .info(kernel.version),
                description: L("debug_kernel_description_darwin"), details: kernel.full),
            DebugRow(id: "model", section: .device, icon: Symbols.deviceModel, label: L("debug_model_label"),
                value: .info("\(DeviceFacts.kind) · \(DeviceFacts.model)"), description: L("debug_model_description"),
                details: L("debug_model_details_apple", DeviceFacts.model, DeviceFacts.chip, DeviceFacts.systemBuild)),
            DebugRow(id: "motor", section: .device, icon: Symbols.vibration, label: L("debug_motor_label"),
                value: .info(motor ? L("debug_yes") : L("debug_no")),
                description: motor ? L("debug_motor_yes_description") : L("debug_motor_no_description")),
        ]
    }

    private var displayRows: [DebugRow] {
        displays.map { display in
            DebugRow(id: "display_\(display.id)", section: .displays, icon: Symbols.monitor, label: display.name,
                value: .info(display.role == .main ? L("debug_display_role_main") : L("debug_display_role_external")),
                description: display.role == .main ? L("debug_display_main_description") : L("debug_display_external_description"),
                details: display.details)
        }
    }

    private var diagnosticRows: [DebugRow] {
        let handOver = DiagnosticsExport.canHandOver
        let unavailable = L("debug_unavailable_tv")
        var rows = [
            DebugRow(id: "diag_log", section: .diagnostics, icon: Symbols.diagnosticLogs, label: L("debug_log_label"), value: .info(logValue),
                description: L("debug_log_description"), details: report.map(preview) ?? L("debug_log_preview_reading")),
        ]
        // Only in a build with the report service: without it the log leaves the device through Share alone
        if ReportUploader.shared.enabled {
            #if os(tvOS)
            let reportNote = L("shell_problem_note_upload_tv")
            #else
            let reportNote = L("shell_problem_note_upload")
            #endif
            rows.append(DebugRow(id: "diag_report", section: .diagnostics, icon: Symbols.reportIssue, label: L("debug_report_label"),
                value: .action(label: nil), description: reportNote))
            if DiagnosticsExport.saveFolder != nil {
                #if os(iOS)
                let saveNote = L("debug_report_save_description_files")
                #else
                let saveNote = L("debug_report_save_description")
                #endif
                rows.append(DebugRow(id: "diag_report_save", section: .diagnostics, icon: Symbols.download, label: ReportOutcomeText.saveLabel,
                    value: .action(label: nil), description: saveNote))
            }
        }
        rows += [
            DebugRow(id: "diag_share", section: .diagnostics, icon: Symbols.shareLog, label: L("debug_share_label"), value: .action(label: nil),
                description: handOver ? L("debug_share_description_apple") : unavailable, enabled: handOver),
            DebugRow(id: "diag_copy", section: .diagnostics, icon: Symbols.copySummary, label: L("debug_copy_label"), value: .action(label: nil),
                description: handOver ? L("debug_copy_description") : unavailable, enabled: handOver),
            DebugRow(id: "diag_clear", section: .diagnostics, icon: Symbols.delete, label: L("debug_clear_label"), value: .action(label: nil),
                description: L("debug_clear_description")),
            // What the last stream of this session encrypted (the PC decides about video and audio)
            DebugRow(id: "stream_encryption", section: .diagnostics, icon: Symbols.key, label: L("stream_encryption_label"),
                value: .info(StreamEncryption.last.map(Self.encryptionText) ?? L("stream_encryption_none")),
                description: L("stream_encryption_description")),
        ]
        #if DEBUG
        // Debug builds only (never in a release build): the way to see the crash capture and the report card work
        rows.append(DebugRow(id: "diag_test_crash", section: .diagnostics, icon: Symbols.testCrash, label: "Trigger test crash", // l10n-ignore
            value: .action(label: nil), description: "Debug builds only. Crashes Delos on purpose; the next start offers the problem report, once.")) // l10n-ignore
        #endif
        return rows
    }

    /// The on-screen controls exist on a touchscreen only.
    private var oscRows: [DebugRow] {
        guard DeviceHardware.touchscreen else { return [] }
        return [DebugRow(id: "osc_preview", section: .onScreenControls, icon: Symbols.joystick, label: L("debug_osc_label"),
            value: .action(label: nil), description: L("debug_osc_description"))]
    }

    /// "212 KB, 1,904 log lines", "Reading…" while it is built, "Off" when nothing is kept.
    private var logValue: String {
        guard let report else { return L("debug_log_reading") }
        if !DiagLog.isEnabled && report.logLines == 0 { return L("debug_log_off") }
        let lines = report.logLines.formatted(.number.locale(.current))
        return LPlural("debug_log_size", report.logLines, DiagnosticReport.sizeText(report.bytes, locale: .current), lines)
    }

    /// The header, the device block and the newest 40 lines; the note about the hidden lines in the user's language.
    private func preview(_ report: DiagnosticReport) -> String {
        guard let parts = report.preview() else { return report.text }
        return (parts.head + [LPlural("diag_preview_hidden_lines", parts.hidden)] + parts.tail).joined(separator: "\n")
    }

    private static func encryptionText(_ encryption: StreamEncryption) -> String {
        func word(_ value: Bool?) -> String {
            switch value {
            case true?: L("common_on")
            case false?: L("common_off")
            case nil: L("stream_encryption_unknown")
            }
        }
        return L("stream_encryption_value", word(encryption.video), word(encryption.audio), word(encryption.control))
    }

    // MARK: Actions

    private func activate(_ row: DebugRow) {
        guard row.enabled else {
            feedback?.play(.error)
            return
        }
        switch row.id {
        case "diag_report": reportNow(.upload)
        case "diag_report_save": reportNow(.save)
        case "diag_share": shareLog()
        case "diag_copy": copySummary()
        case "diag_clear": clearLogs()
        case "osc_preview": go { navigator.push(.oscPreview) }
        #if DEBUG
        case "diag_test_crash": fatalError("Test crash from Debug info") // l10n-ignore
        #endif
        default:
            if lab?.activate(row.id) == true { return }
        }
    }

    /// A report the user started here: the same two ways as the problem card, without a detected problem.
    private func reportNow(_ mode: ReportMode) {
        let export = export
        let toasts = actions.toasts
        Task {
            if mode == .upload { toasts.show(ReportOutcomeText.uploading, icon: Symbols.reportIssue) }
            let result = await export.submit(problem: nil, mode: mode)
            toasts.show(ReportOutcomeText.text(result), icon: result.succeeded ? Symbols.checkCircle : Symbols.warning, durationMs: 6_500)
            guard DiagnosticsExport.canHandOver else { return }
            try? await Task.sleep(for: .milliseconds(900))
            if await !DiagnosticsExport.openIssue(result.issueURL) {
                feedback?.play(.error)
                toasts.show(L("shell_report_no_browser"), icon: Symbols.error)
            }
        }
    }

    private func shareLog() {
        let export = export
        let ready = report
        Task {
            let text = if let ready { ready } else { await export.report() }
            let shared = (try? DiagnosticsExport.writeForSharing(text)).map(DiagnosticsExport.share) ?? false
            if !shared {
                feedback?.play(.error)
                actions.toasts.show(L("debug_share_no_app_toast"), icon: Symbols.error)
            }
        }
    }

    private func copySummary() {
        let export = export
        Task {
            DiagnosticsExport.copy(await export.summary().text)
            actions.toasts.show(L("debug_summary_copied_toast"), icon: Symbols.checkCircle)
        }
    }

    private func clearLogs() {
        Task {
            await Task.detached(priority: .utility) {
                DiagLog.clear()
                DiagnosticsExport.clearShared()
            }.value
            report = nil
            reportRun += 1
            actions.toasts.show(L("debug_logs_cleared_toast"), icon: Symbols.checkCircle)
        }
    }

    // MARK: Input

    private func capture(_ command: MenuCommand) -> Bool {
        switch command {
        case .left, .right:
            guard let row = focusedRow else { return false }
            guard row.enabled else { return true }
            switch row.value {
            case .slider, .toggle:
                if lab?.step(row.id, by: command == .right ? 1 : -1) == true { feedback?.play(.move) }
            default: break
            }
            // Left and right never leave the row
            return true
        case .up:
            // A held Up stops at the first row
            return navigator.commandRepeat > 0 && focusedRow?.id == rows.first?.id
        default:
            return false
        }
    }

    private func tapped(_ row: DebugRow, wasFocused: Bool) {
        switch RowTouch.of(row.value, wasFocused: wasFocused, enabled: row.enabled, canPopup: false) {
        case .focusOnly: feedback?.play(.move)
        case .activate, .pick:
            if case .toggle = row.value { feedback?.play(.select) } else { feedback?.play(.open) }
            activate(row)
        case .error: feedback?.play(.error)
        case .adjust, .none: break
        }
    }

    // MARK: Layout

    private var content: some View {
        let compact = stage.compact
        let margin = compact ? SettingsLayout.margin(stage) : 150
        let bottom = (compact ? SettingsLayout.bottom(scale: stage.textScale) : 110) + stage.safe.bottom
        return ZStack(alignment: .topLeading) {
            Text(L("debug_title"))
                .font(DelosFonts.unbounded(stage.tpx(46)))
                .foregroundStyle(colors.text.color)
                .offset(x: stage.px(margin + (compact ? 0 : stage.safe.leading)), y: stage.px((compact ? 108 : 124) + stage.safe.top))
            if compact {
                VStack(spacing: stage.px(HelpDockLayout.listGap)) {
                    list
                    DebugDetails(row: focusedRow, compact: true)
                        .frame(height: stage.px(HelpDockLayout.height(
                            stageHeight: stage.height, rowsTop: 184 + stage.safe.top + 14 + SettingsLayout.sectionHeading,
                            bottom: bottom, rowHeight: SettingsLayout.tallRow(stage))))
                }
                .padding(.leading, stage.px(margin))
                .padding(.trailing, stage.px(margin))
                .padding(.top, stage.px(184 + stage.safe.top))
                .padding(.bottom, stage.px(bottom))
            } else {
                HStack(alignment: .top, spacing: stage.px(56)) {
                    list
                    DebugDetails(row: focusedRow, compact: false).frame(width: stage.px(520))
                }
                .padding(.leading, stage.px(margin + stage.safe.leading))
                .padding(.trailing, stage.px(margin + stage.safe.trailing))
                .padding(.top, stage.px(230 + stage.safe.top))
                .padding(.bottom, stage.px(bottom))
            }
        }
    }

    private var list: some View {
        let rows = rows
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: stage.px(SettingsLayout.rowGap)) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index == 0 || rows[index - 1].section != row.section {
                        DebugSectionHeading(label: row.section.title)
                    }
                    FocusItem(id: row.id, model: focus, action: { activate(row) }, tap: { wasFocused in tapped(row, wasFocused: wasFocused) }) { focused in
                        SettingRowView(
                            row: row.settingRow, focused: focused, hostedPlate: true, entrance: min(index, Motion.staggerCap),
                            onSlide: { value in
                                focus.focus(AnyHashable(row.id))
                                lab?.slide(row.id, to: value)
                            },
                            onStep: { direction in
                                focus.focus(AnyHashable(row.id))
                                guard row.enabled else {
                                    feedback?.play(.error)
                                    return
                                }
                                if lab?.step(row.id, by: direction) == true { feedback?.play(.move) }
                            })
                    }
                    .id(row.id)
                    .anchorPreference(key: SettingsRowAnchors.self, value: .bounds) { [row.id: $0] }
                    .reportsRowFrame(row.id)
                }
            }
            .backgroundPreferenceValue(SettingsRowAnchors.self) { anchors in
                GeometryReader { proxy in
                    let anchor = (focus.focused as? String).flatMap { anchors[$0] }
                    SettingsFocusPlate(target: anchor.map { SettingsPlateGeometry.target(proxy[$0]) })
                }
            }
            // Room for the focused row's scale and glow, which the scroll view would cut
            .padding(.horizontal, stage.px(18))
            .padding(.top, stage.px(14))
            .padding(.bottom, stage.px(140))
            .focusDrivenScroll()
            .coordinateSpace(.named(SettingsListScroll.contentSpace))
            .entranceScope()
        }
        .settingsListScroll(
            focus: focus, contains: { id in rows.contains { $0.id == id } }, resetKey: AnyHashable(0),
            fadeTop: stage.compact ? SettingsLayout.compactFadeTop : SettingsLayout.fadeTop,
            fadeBottom: stage.compact ? SettingsLayout.compactFadeBottom : SettingsLayout.fadeBottom, compact: stage.compact)
        .frame(maxWidth: .infinity)
    }
}

extension DebugRow {
    /// The row as the settings draw it: a description of at most 100 characters (Android's limit) is also the line under the
    /// label; every description stays in the panel.
    var settingRow: SettingRow {
        SettingRow(id: id, tab: .about, section: section.title, icon: icon, label: label, value: value, help: description, enabled: enabled,
                   note: description.count <= 100 ? description : nil)
    }
}

/// A section's heading over its first row: its name in capitals (the settings' heading).
private struct DebugSectionHeading: View {
    let label: String
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        Text(label.uppercased(with: .current))
            .font(DelosFonts.figtree(stage.tpx(16), .semibold))
            .tracking(stage.tpx(16) * 0.08)
            .foregroundStyle(colors.text3.color)
            .padding(.leading, stage.px(26))
            .padding(.top, stage.px(10))
            .padding(.bottom, stage.px(2))
    }
}

/// The focused row's icon on an accent disc, its name, its description and its technical details in a monospaced block (the
/// screen's own text when no row is focused): a glass panel on the right as tall as its text (Android's `DetailsPanel`), or the
/// dock under a compact list. Text longer than the room scrolls by itself.
private struct DebugDetails: View {
    let row: DebugRow?
    let compact: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    /// The room above and below the text in the panel (stage px), which is also the scrolling text's fade.
    private static let textInset = 24.0

    var body: some View {
        let title = row?.label ?? L("debug_title")
        let description = row?.description ?? L("debug_panel_default")
        let disc = compact ? HelpDockLayout.disc : 120
        let layout = compact ? AnyLayout(HStackLayout(spacing: stage.px(HelpDockLayout.titleGap))) : AnyLayout(VStackLayout(alignment: .leading, spacing: stage.px(26)))
        VStack(alignment: .leading, spacing: stage.px(compact ? HelpDockLayout.bodyGap : 18)) {
            layout {
                ZStack {
                    Circle().fill(colors.accent.color)
                    SymbolView(symbol: row?.icon ?? Symbols.info, size: compact ? 28 : 64, color: colors.onAccent, filled: true)
                }
                .frame(width: stage.px(disc), height: stage.px(disc))
                Text(title)
                    .font(DelosFonts.unbounded(stage.tpx(compact ? 22 : 30)))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(compact ? 1 : nil)
            }
            let identity = "\(row?.id ?? "debug"):\(description):\(row?.details ?? "")"
            if compact {
                AutoScrollingHelp(identity: identity, edgeFade: HelpDockLayout.fade) { text(description) }
            } else {
                // The panel ends under its text; only text taller than the room fills the panel's height and scrolls. Both
                // keep the same inset, so the text does not move when it starts to scroll
                ViewThatFits(in: .vertical) {
                    text(description).padding(.vertical, stage.px(Self.textInset))
                    AutoScrollingHelp(identity: identity, inset: Self.textInset) { text(description) }
                }
            }
        }
        .padding(.horizontal, stage.px(compact ? HelpDockLayout.padX : 44))
        .padding(.vertical, stage.px(compact ? HelpDockLayout.padY : 44))
        .frame(maxWidth: .infinity, maxHeight: compact ? .infinity : nil, alignment: .topLeading)
        .background {
            GlassShape(RoundedRectangle(cornerRadius: stage.px(compact ? 28 : 34)), tint: colors.surface, role: .panel)
                .overlay(RoundedRectangle(cornerRadius: stage.px(compact ? 28 : 34)).strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func text(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: stage.px(compact ? HelpDockLayout.rowGap : 18)) {
            Text(description)
                .font(DelosFonts.figtree(stage.tpx(compact ? 21 : 22)))
                .lineSpacing(stage.tpx((compact ? 21 : 22) * 0.45))
                .foregroundStyle(colors.text2.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            if row?.enabled == false {
                Text(L("settings_screen_unavailable"))
                    .font(DelosFonts.figtree(stage.tpx(18)))
                    .foregroundStyle(colors.text3.color)
            }
            if let details = row?.details {
                Text(details)
                    .font(.system(size: stage.tpx(16), design: .monospaced))
                    .lineSpacing(stage.tpx(16 * 0.4))
                    .foregroundStyle(colors.text3.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
