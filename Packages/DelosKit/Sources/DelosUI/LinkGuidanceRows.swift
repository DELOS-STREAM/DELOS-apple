import DelosData
import DelosHost
import Foundation

/// The Settings rows of the link guidance (`LinkGuidanceRows.kt` of DELOS for Android): the bitrate row gets the
/// recommendation as its line and the last test in its help, and Test link and Use recommended bitrate follow it.
/// Nothing is sent and no bitrate is changed except by the user's own press of Use recommended bitrate.
enum LinkGuidanceRows {
    static let testID = "link_test"
    static let useID = "link_use_recommended"

    /// The PC the settings talk about: the one whose library is open, else the first paired one (`settingsPc`).
    @MainActor
    static func settingsHost(libraryHostID: String?, hosts: HostStore) -> HostRecord? {
        libraryHostID.flatMap(hosts.host) ?? hosts.paired.first
    }

    /// The line under the bitrate row: the PC's own line when the link is known (tested or not), else PyroWave's guide
    /// alone ("Recommended: 225 Mbps"), else none.
    static func bitrateHint(_ guidance: LinkGuidance?, form: StreamSettingsForm) -> String? {
        if let guidance { return guidance.line }
        guard form.settings.codec == .pyroWave, let format = LinkFormat.of(form.settings, resolution: form.effectiveResolution) else {
            return nil
        }
        return L("link_recommended_plain", format.defaultKbps / 1000)
    }

    /// [rows] with the guidance next to the bitrate row (`withLinkRows`): the row's line and help, then Test link (the
    /// last test or why there is none) and Use recommended bitrate (dimmed while the bitrate already is the
    /// recommendation). Without a PC or guidance only the line changes.
    static func apply(
        _ rows: [SettingRow], guidance: LinkGuidance?, host: HostRecord?, form: StreamSettingsForm, nowMs: Int64,
        transport: LinkTransport
    ) -> [SettingRow] {
        rows.flatMap { row -> [SettingRow] in
            guard row.id == StreamSettingsForm.bitrate else { return [row] }
            var bitrate = row
            bitrate.note = bitrateHint(guidance, form: form)
            guard let guidance, let host else { return [bitrate] }
            let help = guidance.help(nowMs: nowMs, transport: transport)
            bitrate.help = row.help + "\n\n" + help
            let recommended = guidance.recommendation
            let test = SettingRow(
                id: testID, tab: row.tab, section: row.section, icon: Symbols.linkTest, label: L("link_test_action"),
                value: .action(label: nil), help: L("link_test_detail", host.name, transport.label) + "\n\n" + help,
                note: guidance.testRowText(nowMs: nowMs, transport: transport))
            let use = SettingRow(
                id: useID, tab: row.tab, section: row.section, icon: Symbols.recommend, label: L("link_use_action"),
                value: .action(label: nil), help: L("link_use_detail", linkMbps(recommended.kbps), recommended.reasonText),
                enabled: form.effectiveBitrate != recommended.kbps, note: recommended.valueText)
            return [bitrate, test, use]
        }
    }

    /// What pressing Test link does: a toast when the PC is offline or cannot test, else the test.
    enum TestPress: Equatable {
        case offline(String)
        case unavailable(String)
        case run
    }

    static func testPress(host: HostRecord, guidance: LinkGuidance) -> TestPress {
        if host.reachability != .online { return .offline(L("link_pc_offline_toast", host.name)) }
        if let unavailable = guidance.testUnavailable { return .unavailable(unavailable.text) }
        return .run
    }
}
