import DelosData
import DelosHost
import DelosInput
import Foundation

// The link guidance's words and the guidance itself (LinkGuidance.kt, LinkFormats.kt, LinkResult.kt, LinkVerdictText.kt,
// LinkRecommendation.kt and LinkMonitor.kt of DELOS for Android): what the screens say about the link for one stream format.

extension LinkCodec {
    /// The codec of the `video_format` setting.
    init(_ codec: VideoCodec) {
        self = switch codec {
        case .pyroWave: .pyroWave
        case .av1: .av1
        case .hevc: .hevc
        case .h264: .h264
        case .automatic: .automatic
        }
    }
}

/// The stream format the guidance talks about. [defaultKbps] is the bitrate DELOS suggests for it without any test:
/// PyroWave's quality guide, or the app's own default for the others. [label] names it for the one-sentence help
/// ("1080p60 PyroWave 4:2:0").
struct LinkFormat: Equatable {
    let codec: LinkCodec
    let label: String
    let fps: Int
    let defaultKbps: Int

    /// "1080p", "1440p", "4K" from the height.
    static func resolutionLabel(height: Int) -> String { height >= 2160 ? "4K" : "\(height)p" }

    /// The format for [width] x [height] at [fps]. PyroWave in HDR uses the 4:2:0 guide, as everywhere else in the app.
    /// Nil for a size that makes no sense.
    static func of(codec: LinkCodec, width: Int, height: Int, fps: Int, hdr: Bool, chroma444: Bool) -> LinkFormat? {
        guard width > 0, height > 0, fps > 0 else { return nil }
        let base = "\(resolutionLabel(height: height))\(fps)\(hdr ? " HDR" : "")"
        if codec == .pyroWave {
            let full = chroma444 && !hdr
            return LinkFormat(
                codec: codec, label: "\(base) PyroWave \(full ? "4:4:4" : "4:2:0")", fps: fps,
                defaultKbps: PyroWaveBitrate.recommendedKbps(width: width, height: height, fps: fps, chroma444: full, hdr: hdr))
        }
        return LinkFormat(
            codec: codec, label: codec == .automatic ? base : "\(base) \(codec.label)", fps: fps,
            defaultKbps: StreamPlan.defaultBitrateKbps(width: width, height: height, fps: fps))
    }

    /// The format of [settings] at [resolution] (the chosen one, else the display's).
    static func of(_ settings: StreamSettings, resolution: StreamResolution) -> LinkFormat? {
        of(codec: LinkCodec(settings.codec), width: resolution.width, height: resolution.height, fps: settings.fps,
           hdr: settings.hdr, chroma444: settings.text(.pyrowaveChroma) == "444")
    }
}

/// "225 Mbps", a technical readout.
func linkMbps(_ kbps: Int) -> String { "\(kbps / 1000) Mbps" }

extension LinkTransport {
    /// The name used inside a sentence ("Tested yesterday on Wi-Fi"); "this network" for anything else.
    var label: String {
        switch self {
        case .wifi: L("link_transport_wifi")
        case .ethernet: L("link_transport_ethernet")
        case .other: L("link_transport_other")
        }
    }
}

extension LinkRecommendation {
    /// The clause that says why ("link carries up to 665 Mbps").
    var reasonText: String {
        switch reason {
        case .untested: L("link_reason_untested")
        case .testedOK: L("link_reason_tested_ok", linkMbps(testedKbps))
        case .testedLimited: L("link_reason_tested_limited", linkMbps(testedKbps))
        case .hostLinkLimited: L("link_reason_host_limited", linkMbps(hostLinkKbps))
        case .dropping: L("link_reason_dropping", linkMbps(droppedAtKbps))
        }
    }

    /// "Recommended: 225 Mbps · link carries up to 665 Mbps".
    var line: String { L("link_recommended_line", linkMbps(kbps), reasonText) }

    /// "225 Mbps · link carries up to 665 Mbps", the value under Use recommended bitrate.
    var valueText: String { L("link_value_reason", linkMbps(kbps), reasonText) }
}

extension LinkReading {
    /// "Link drops frames at 220 Mbps, try 170", or the one-line state otherwise.
    var text: String {
        switch verdict {
        case .measuring: L("link_reading_measuring")
        case .keepingUp: L("link_reading_keeps_up", linkMbps(targetKbps))
        case .dropping: L("link_reading_drops", linkMbps(targetKbps), linkMbps(suggestedKbps))
        case .deviceBehind: L("link_reading_device_behind")
        }
    }
}

/// How long ago a result is, by calendar days in [zone]: "just now", "12 min ago", "3 h ago", "yesterday", "4 days ago",
/// "2 weeks ago", "3 months ago". A time in the future (the clock was changed) reads "just now".
func linkAgeText(nowMs: Int64, thenMs: Int64, zone: TimeZone = .current) -> String {
    let elapsed = nowMs - thenMs
    if elapsed < 60_000 { return L("link_age_just_now") }
    let minutes = Int(elapsed / 60_000)
    func day(_ ms: Int64) -> Int64 {
        let offset = Int64(zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(ms) / 1000))) * 1000
        let shifted = ms + offset
        return shifted >= 0 ? shifted / LinkPolicy.msPerDay : (shifted - LinkPolicy.msPerDay + 1) / LinkPolicy.msPerDay
    }
    let days = Int(day(nowMs) - day(thenMs))
    if days <= 0 { return minutes < 60 ? LPlural("link_age_minutes", minutes) : LPlural("link_age_hours", minutes / 60) }
    if days == 1 { return L("link_age_yesterday") }
    if days < 7 { return LPlural("link_age_days", days) }
    if days < 30 { return LPlural("link_age_weeks", days / 7) }
    return LPlural("link_age_months", days / 30)
}

extension LinkTest {
    /// "Tested yesterday on Wi-Fi", the line under the recommendation.
    func summary(nowMs: Int64, zone: TimeZone = .current) -> String {
        L("link_tested_summary", linkAgeText(nowMs: nowMs, thenMs: testedAtMs, zone: zone), transport.label)
    }
}

extension LinkFailure {
    /// One sentence for a failed test ("DELOS could not reach the PC"), without technical detail.
    var text: String {
        switch self {
        case .hostUnsupported: L("link_failure_host_unsupported")
        case .streamActive: L("link_failure_stream_active")
        case .denied: L("link_failure_denied")
        case .udpBlocked: L("link_failure_udp_blocked")
        case .network: L("link_failure_network")
        case .timeout: L("link_failure_timeout")
        case .hostError: L("link_failure_host_error")
        case .invalidResponse: L("link_failure_invalid_response")
        case .needsNewerClient: L("link_unavailable_newer_delos")
        }
    }
}

extension ProbeScore {
    /// The real reason a probe failed, in plain words, with its rate ("Lost 3.0% of the test packets at 450 Mbps").
    var reasonText: String {
        let rate = linkMbps(requestedKbps)
        if receiverSuspect { return L("link_verdict_receiver_suspect", rate) }
        switch failure {
        case .loss: return L("link_verdict_loss", lossPercent, rate)
        case .windowLoss: return L("link_verdict_window_loss", worstWindowLossPercent, rate)
        case .delayGrowth: return L("link_verdict_delay_growth", rate)
        case .noPackets: return L("link_verdict_no_packets")
        case .notAllSent: return L("link_verdict_not_all_sent", expected > 0 ? 100.0 * Double(sent) / Double(expected) : 0.0, rate)
        case .senderDuration: return L("link_verdict_sender_duration")
        case nil: return L("link_verdict_passed", rate)
        }
    }

    /// The verdict of a passing probe: "Stable" or "Stable, a little jitter".
    var verdictText: String {
        guard passed else { return reasonText }
        return L(jitterWarning ? "link_verdict_stable_jitter" : "link_verdict_stable")
    }
}

/// The sentence for a search that found no rate: the last probe's real reason, and whether anything passed at all.
func linkNoRateText(last: ProbeScore?, bestPassKbps: Int) -> String {
    let reason = last?.reasonText ?? L("link_verdict_no_rate_tested")
    if bestPassKbps > 0 { return L("link_no_rate_passed_once", reason, linkMbps(bestPassKbps)) }
    if let last { return L("link_no_rate_nothing_passed", reason, linkMbps(last.requestedKbps)) }
    return L("link_no_rate_plain", reason)
}

/// Why the PC cannot run the link test.
enum LinkUnavailable: Equatable {
    /// The PC speaks a newer probe protocol than this DELOS knows.
    case needsNewerClient
    /// An older Vibepollo, or a host without PyroWave support.
    case hostOutdated

    var text: String {
        switch self {
        case .needsNewerClient: L("link_unavailable_newer_delos")
        case .hostOutdated: L("link_unavailable_host_outdated")
        }
    }
}

/// What the screens show about the link for one stream format: the recommendation with its reason, the last test (if
/// any) with its age, and the note when the PC cannot run the test. Built from plain values so every screen (Settings,
/// App settings, the stream menu) says the same thing. Works for every codec: the probe measures the network, not the codec.
struct LinkGuidance: Equatable {
    let format: LinkFormat
    let recommendation: LinkRecommendation
    let tested: LinkTest?
    /// Set when the PC cannot run the test.
    let testUnavailable: LinkUnavailable?

    /// [format] is the stream asked for, [info] what the PC advertises (``PyroWaveHostInfo/none`` when not known),
    /// [tested] the stored result for this PC on the current kind of network, [live] the running stream's drop hint
    /// (PyroWave only).
    init(format: LinkFormat, info: PyroWaveHostInfo, tested: LinkTest?, live: LinkReading? = nil) {
        self.format = format
        self.tested = tested
        testUnavailable = info.supportsLinkTest ? nil : info.linkTestNeedsNewerClient ? .needsNewerClient : .hostOutdated
        let hostLink = info.hostLinkMbps * 1000
        if format.codec == .pyroWave {
            let transport = tested.map { WireTransport(packetSize: $0.packetSize, criticalFECPercent: $0.criticalFECPercent) }
            recommendation = recommend(
                staticKbps: format.defaultKbps, testedWireKbps: tested?.wireKbps, hostLinkKbps: hostLink, live: live,
                fps: format.fps, transport: transport)
        } else {
            recommendation = recommend(
                staticKbps: ordinaryWantedKbps(format.codec, defaultKbps: format.defaultKbps), testedWireKbps: tested?.wireKbps,
                hostLinkKbps: hostLink, share: LinkPolicy.ordinaryBudgetShare, untestedKbps: format.defaultKbps)
        }
    }

    /// The `Recommended: N Mbps · reason` line of the bitrate row.
    var line: String { recommendation.line }

    /// The long text of the help panel: the test with its age and the one sentence that names both numbers ("Wi-Fi carries
    /// up to 665 Mbps; 225 Mbps is enough for 1080p60 PyroWave 4:2:0."), or why there is no test.
    func help(nowMs: Int64, transport: LinkTransport, zone: TimeZone = .current) -> String {
        guard let tested else { return testUnavailable?.text ?? L("link_help_untested", transport.label) }
        let r = recommendation
        let wire = linkMbps(tested.wireKbps)
        let sentence =
            if r.reason == .testedOK { L("link_help_tested_ok", wire, linkMbps(r.kbps), format.label) }
            else if r.reason == .hostLinkLimited { L("link_help_host_limited", wire, format.label) }
            else if r.pictureKbps > 0 { L("link_help_limited_picture", wire, format.label, linkMbps(r.wantedKbps), linkMbps(r.pictureKbps)) }
            else { L("link_help_limited", wire, format.label, linkMbps(r.wantedKbps)) }
        return L("link_help_joined", tested.summary(nowMs: nowMs, zone: zone), sentence)
    }

    /// The stream menu's help for the recommendation row. There is no test there (the host refuses probes during a
    /// stream), so an untested link points to Settings, before connecting.
    @MainActor
    func streamHelp(now: Date = Date(), zone: TimeZone = .current) -> String {
        let nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded())
        let dropping = recommendation.reason == .dropping
        let dropped = linkMbps(recommendation.droppedAtKbps)
        let confirm = ControllerGlyphs.shared.mark(.south).text ?? "A"
        if dropping { return tested != nil ? L("link_stream_help_dropping", dropped, confirm) : L("link_stream_help_dropping_untested", dropped, confirm) }
        if let tested { return L("link_stream_help_tested", tested.summary(nowMs: nowMs, zone: zone), confirm) }
        return L("link_stream_help_untested", confirm)
    }

    /// What the Test link row says under its label.
    func testRowText(nowMs: Int64, transport: LinkTransport, zone: TimeZone = .current) -> String {
        tested?.summary(nowMs: nowMs, zone: zone) ?? testUnavailable?.text ?? L("link_test_row_untested", transport.label)
    }

    /// The guidance for [host] and the format of [form], or nil when there is no PC (Settings then keep the plain
    /// "Recommended: N Mbps" hint for PyroWave and nothing for the other codecs). An ordinary codec shows it only when the
    /// PC can test or a result exists, so a PC that cannot test adds no noise (`rememberLinkGuidance`).
    @MainActor
    static func forSettings(
        host: HostRecord?, form: StreamSettingsForm, tests: LinkTestStore = .shared, transport: LinkTransport = .current
    ) -> LinkGuidance? {
        guard let host, let format = LinkFormat.of(form.settings, resolution: form.effectiveResolution) else { return nil }
        let tested = tests.get(hostID: host.id, transport: transport)
        let info = host.pyroWave ?? .none
        if format.codec != .pyroWave, !info.supportsLinkTest, tested == nil { return nil }
        return LinkGuidance(format: format, info: info, tested: tested)
    }

    /// The stream menu's guidance (StreamMenu.kt:420-436): the format asked for, the last test of this PC on the current
    /// kind of network and, for PyroWave, the stream's own drop counters. The PC's own link speed is not read here. An
    /// ordinary codec shows it only once a test exists; nil hides the row.
    @MainActor
    static func forStream(
        hostID: String, settings: StreamSettings, resolution: StreamResolution, live: LinkReading? = nil,
        tests: LinkTestStore = .shared, transport: LinkTransport = .current
    ) -> LinkGuidance? {
        guard let format = LinkFormat.of(settings, resolution: resolution) else { return nil }
        let tested = tests.get(hostID: hostID, transport: transport)
        if format.codec != .pyroWave, tested == nil { return nil }
        return LinkGuidance(format: format, info: .none, tested: tested, live: format.codec == .pyroWave ? live : nil)
    }
}
