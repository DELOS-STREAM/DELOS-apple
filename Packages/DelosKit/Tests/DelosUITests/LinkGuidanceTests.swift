import DelosData
import DelosHost
import Foundation
import Testing
@testable import DelosUI

/// The guidance's texts (LinkGuidanceTest.kt of DELOS for Android) and the Settings rows built from it (LinkGuidanceRows.kt).
@MainActor
@Suite struct LinkGuidanceTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let now: Int64 = 1_794_052_800_000
    private let day: Int64 = 24 * 60 * 60_000
    private let pw = LinkFormat.of(codec: .pyroWave, width: 1920, height: 1080, fps: 60, hdr: false)!
    private var tested: LinkTest { LinkTest(wireKbps: 180_000, testedAtMs: now - day, transport: .wifi, criticalFECPercent: 50, packetSize: 1392) }
    private let supported = PyroWaveHostInfo(
        wireBudgetVersion: 1, udpProbeVersion: 1, udpHandshakeVersion: 1, hostLinkMbps: 1000, bandwidthProbeBytes: 0,
        criticalFECPercent: 50, minParityShards: 2)

    @Test func anUntestedLinkSaysSoAndAnOldHostExplainsWhy() {
        let g = LinkGuidance(format: pw, info: .none, tested: nil)
        #expect(g.line == "Recommended: 225 Mbps · not tested on this link")
        #expect(g.testUnavailable == .hostOutdated)
        #expect(g.testRowText(nowMs: now, transport: .wifi, zone: utc) == "This PC's Vibepollo cannot test the link yet. Update it.")
    }

    @Test func aTestedLinkShowsItsAgeAndThePictureItCarries() {
        let g = LinkGuidance(format: pw, info: .none, tested: tested)
        #expect(g.line == "Recommended: 180 Mbps · link carries 180 Mbps")
        #expect(g.help(nowMs: now, transport: .wifi, zone: utc)
            == "Tested yesterday on Wi-Fi: carries 180 Mbps; 1080p60 PyroWave 4:2:0 wants 225 Mbps, about 102 Mbps of picture after FEC and overhead.")
        #expect(g.testRowText(nowMs: now, transport: .wifi, zone: utc) == "Tested yesterday on Wi-Fi")
    }

    @Test func withoutAResultTheHelpOffersTheTest() {
        let g = LinkGuidance(format: pw, info: supported, tested: nil)
        #expect(g.testUnavailable == nil)
        #expect(g.help(nowMs: now, transport: .wifi, zone: utc) == "Not tested on Wi-Fi. Test link measures what it carries.")
        #expect(g.testRowText(nowMs: now, transport: .wifi, zone: utc) == "Not tested on Wi-Fi yet")
    }

    @Test func theStreamMenuHelpSaysWhatTheRowIs() {
        let date = Date(timeIntervalSince1970: Double(now) / 1000)
        let dropping = LinkGuidance(
            format: pw, info: .none, tested: tested,
            live: LinkReading(verdict: .dropping, targetKbps: 225_000, rxKbps: 1, partialPerSecond: 6, dropShare: 0.1, suggestedKbps: 135_000))
        #expect(dropping.streamHelp(now: date, zone: utc) == "Link drops frames at 225 Mbps. A fills the slider, Apply sends it.")
        #expect(LinkGuidance(format: pw, info: .none, tested: tested).streamHelp(now: date, zone: utc)
            == "Tested yesterday on Wi-Fi. A fills the slider, Apply sends it.")
        #expect(LinkGuidance(format: pw, info: .none, tested: nil).streamHelp(now: date, zone: utc)
            == "Not tested yet. A fills the slider, Apply sends it. Test the link in Settings before connecting.")
    }

    @Test func aLinkWithHeadroomSaysBothNumbersInOneSentence() {
        var roomy = tested
        roomy.wireKbps = 665_000
        let g = LinkGuidance(format: pw, info: .none, tested: roomy)
        #expect(g.line == "Recommended: 225 Mbps · link carries up to 665 Mbps")
        #expect(g.help(nowMs: now, transport: .wifi, zone: utc)
            == "Tested yesterday on Wi-Fi: carries up to 665 Mbps; 225 Mbps is enough for 1080p60 PyroWave 4:2:0.")
    }

    @Test func formatsAreBuiltForEveryCodec() {
        let pyro = LinkFormat.of(codec: .pyroWave, width: 1920, height: 1080, fps: 60, hdr: false)!
        #expect(pyro.label == "1080p60 PyroWave 4:2:0")
        #expect(pyro.defaultKbps == 225_000)
        #expect(LinkFormat.of(codec: .pyroWave, width: 1920, height: 1080, fps: 60, hdr: true)!.label == "1080p60 HDR PyroWave 4:2:0")
        let hevc = LinkFormat.of(codec: .hevc, width: 1920, height: 1080, fps: 60, hdr: false)!
        #expect(hevc.codec == .hevc && hevc.label == "1080p60 HEVC" && hevc.defaultKbps == 20_000)
        #expect(LinkFormat.of(codec: .av1, width: 3840, height: 2160, fps: 60, hdr: false)!.defaultKbps == 80_000)
        let auto = LinkFormat.of(codec: .automatic, width: 2560, height: 1440, fps: 120, hdr: false)!
        #expect(auto.codec == .automatic && auto.label == "1440p120")
        #expect(LinkFormat.of(codec: .automatic, width: 0, height: 1080, fps: 60, hdr: false) == nil)
        #expect(LinkFormat.of(codec: .automatic, width: 1920, height: 1080, fps: 0, hdr: false) == nil)
    }

    @Test func anOrdinaryCodecGetsTheSameSentenceWithItsOwnUsefulMaximum() {
        let hevc = LinkFormat.of(codec: .hevc, width: 1920, height: 1080, fps: 60, hdr: false)!
        var roomy = tested
        roomy.wireKbps = 665_000
        let g = LinkGuidance(format: hevc, info: .none, tested: roomy)
        #expect(g.line == "Recommended: 40 Mbps · link carries up to 665 Mbps")
        #expect(g.help(nowMs: now, transport: .wifi, zone: utc) == "Tested yesterday on Wi-Fi: carries up to 665 Mbps; 40 Mbps is enough for 1080p60 HEVC.")
        #expect(LinkGuidance(format: hevc, info: .none, tested: tested).line == "Recommended: 40 Mbps · link carries up to 180 Mbps")
        #expect(LinkGuidance(format: hevc, info: .none, tested: nil).line == "Recommended: 20 Mbps · not tested on this link")
        // The drop hint is PyroWave only: an ordinary codec ignores it
        let reading = LinkReading(verdict: .dropping, targetKbps: 20_000, rxKbps: 1, partialPerSecond: 6, dropShare: 0.1, suggestedKbps: 15_000)
        #expect(LinkGuidance(format: hevc, info: .none, tested: nil, live: reading).recommendation.kbps == 20_000)
    }

    @Test func ageTextsCountCalendarDays() {
        #expect(linkAgeText(nowMs: now, thenMs: now - 30_000, zone: utc) == "just now")
        #expect(linkAgeText(nowMs: now, thenMs: now + 60_000, zone: utc) == "just now")
        #expect(linkAgeText(nowMs: now + 12 * 60_000, thenMs: now, zone: utc) == "12 min ago")
        #expect(linkAgeText(nowMs: now + 3 * 3_600_000, thenMs: now, zone: utc) == "3 h ago")
        #expect(linkAgeText(nowMs: now, thenMs: now - day, zone: utc) == "yesterday")
        #expect(linkAgeText(nowMs: now, thenMs: now - 4 * day, zone: utc) == "4 days ago")
        #expect(linkAgeText(nowMs: now, thenMs: now - 15 * day, zone: utc) == "2 weeks ago")
        #expect(linkAgeText(nowMs: now, thenMs: now - 95 * day, zone: utc) == "3 months ago")
    }

    // MARK: The Settings rows

    private func form(_ codec: VideoCodec, bitrate: Int? = nil) -> StreamSettingsForm {
        var settings = StreamSettings(resolution: StreamResolution(width: 1920, height: 1080), fps: 60, bitrateKbps: bitrate)
        settings.codec = codec
        return StreamSettingsForm(
            settings: settings,
            device: StreamDevice(pixelWidth: 1920, pixelHeight: 1080, maxFramesPerSecond: 60, decodable: [.h264, .hevc], pyroWave: true))
    }

    private func host(online: Bool = true) throws -> HostRecord {
        let xml = """
        <root status_code="200"><hostname>Desk</hostname><uniqueid>A</uniqueid><HttpsPort>47984</HttpsPort>\
        <appversion>7.1.431.-1</appversion><PairStatus>0</PairStatus><state>SUNSHINE_SERVER_FREE</state></root>
        """
        let reply = ServerInfoReply(
            info: try ServerInfo.parse(Data(xml.utf8)), address: HostAddress(host: "192.168.1.5", port: 47989), source: .plainHTTP)
        let record = HostRecord(firstReply: reply).paired(with: HostPin(certificate: Data([1]), httpsPort: 47984))
        return online ? record : record.markedOffline()
    }

    @Test func theTestAndUseRowsFollowTheBitrateRowWithItsLineAndHelp() throws {
        let form = form(.pyroWave)
        let guidance = LinkGuidance(format: LinkFormat.of(form.settings, resolution: form.effectiveResolution)!, info: supported, tested: tested)
        let catalog = form.catalogRows(.stream)
        let rows = LinkGuidanceRows.apply(catalog, guidance: guidance, host: try host(), form: form, nowMs: now, transport: .wifi)
        #expect(rows.count == catalog.count + 2)
        let index = try #require(rows.firstIndex { $0.id == StreamSettingsForm.bitrate })
        let bitrate = rows[index], test = rows[index + 1], use = rows[index + 2]
        let help = guidance.help(nowMs: now, transport: .wifi)
        #expect(bitrate.note == "Recommended: 180 Mbps · link carries 180 Mbps")
        #expect(bitrate.help == catalog[index].help + "\n\n" + help)
        #expect(test.id == LinkGuidanceRows.testID && test.label == "Test link" && test.icon == Symbols.linkTest)
        #expect(test.section == bitrate.section && test.tab == .stream && test.value == .action(label: nil))
        #expect(test.note == guidance.testRowText(nowMs: now, transport: .wifi))
        #expect(test.help == L("link_test_detail", "Desk", "Wi-Fi") + "\n\n" + help)
        #expect(use.id == LinkGuidanceRows.useID && use.label == "Use recommended bitrate" && use.icon == Symbols.recommend)
        #expect(use.note == "180 Mbps · link carries 180 Mbps")
        #expect(use.help == "Fills the bitrate with 180 Mbps: link carries 180 Mbps. Delos never changes the bitrate by itself.")
        #expect(use.enabled)
    }

    @Test func useRecommendedIsDimmedWhileTheBitrateIsTheRecommendation() throws {
        let form = form(.pyroWave, bitrate: 180_000)
        let guidance = LinkGuidance(format: LinkFormat.of(form.settings, resolution: form.effectiveResolution)!, info: supported, tested: tested)
        let rows = LinkGuidanceRows.apply(form.catalogRows(.stream), guidance: guidance, host: try host(), form: form, nowMs: now, transport: .wifi)
        #expect(rows.first { $0.id == LinkGuidanceRows.useID }?.enabled == false)
    }

    @Test func withoutAPCPyroWaveKeepsItsPlainHintAndOtherCodecsNone() {
        let pyro = form(.pyroWave)
        let rows = LinkGuidanceRows.apply(pyro.catalogRows(.stream), guidance: nil, host: nil, form: pyro, nowMs: now, transport: .wifi)
        #expect(!rows.contains { $0.id == LinkGuidanceRows.testID || $0.id == LinkGuidanceRows.useID })
        #expect(rows.first { $0.id == StreamSettingsForm.bitrate }?.note == "Recommended: 225 Mbps")
        let hevc = form(.hevc)
        #expect(LinkGuidanceRows.bitrateHint(nil, form: hevc) == nil)
    }

    @Test func testLinkSaysWhyItCannotRun() throws {
        let ready = LinkGuidance(format: pw, info: supported, tested: nil)
        #expect(LinkGuidanceRows.testPress(host: try host(online: false), guidance: ready) == .offline("Desk is offline"))
        #expect(LinkGuidanceRows.testPress(host: try host(), guidance: LinkGuidance(format: pw, info: .none, tested: nil))
            == .unavailable("This PC's Vibepollo cannot test the link yet. Update it."))
        #expect(LinkGuidanceRows.testPress(host: try host(), guidance: ready) == .run)
    }

    @Test func theRowsAreFoundByTheirAliases() {
        #expect(SettingsSearch.aliases(LinkGuidanceRows.testID).hasPrefix("bandwidth probe measure speed network wifi "))
        #expect(SettingsSearch.aliases(LinkGuidanceRows.useID).hasPrefix("recommended bitrate link "))
    }

    @Test func failuresAreWordedFromTheirCause() {
        #expect(LinkTester.result(of: CancellationError()) == .cancelled)
        #expect(LinkTester.result(of: LinkTestError(.udpBlocked, "x")) == .failed(.udpBlocked))
        #expect(LinkTester.result(of: HostError.httpStatus(403)) == .failed(.denied))
        #expect(LinkTester.result(of: HostError.hostStatus(code: 403, message: nil)) == .failed(.denied))
        #expect(LinkTester.result(of: HostError.httpStatus(500)) == .failed(.hostError))
        #expect(LinkTester.result(of: HostError.timedOut) == .failed(.network))
        #expect(LinkTestRun.failed(.network).failureText == "Delos could not reach the PC.")
        #expect(LinkTestRun.noRate(last: nil, bestPassKbps: 0).failureText == "No rate could be tested.")
        #expect(LinkTestRun.cancelled.failureText == nil)
    }

    @Test func storedResultsAreKeptPerPCAndNetwork() throws {
        let defaults = try #require(UserDefaults(suiteName: "LinkGuidanceTests-\(UUID().uuidString)"))
        let store = LinkTestStore(defaults: defaults)
        #expect(store.get(hostID: "A", transport: .wifi) == nil)
        store.put(hostID: "A", test: tested)
        #expect(store.get(hostID: "A", transport: .wifi) == tested)
        #expect(store.get(hostID: "A", transport: .ethernet) == nil)
        #expect(store.get(hostID: "B", transport: .wifi) == nil)
        #expect(store.revision == 1)
        #expect(defaults.string(forKey: "delos_link_tests.A/WIFI") == "1;180000;\(now - day);WIFI;50;1392")
    }
}
