import DelosCore
import Foundation
import Synchronization
import Testing
@testable import DelosData

let diagnosticsInfo = DeviceInfo(
    delosVersion: "0.1.0", buildType: "release", buildNumber: "100", deviceKind: "iPhone", model: "iPhone17,1", system: "iOS 26.1",
    systemBuild: "23B85", chip: "Apple A18 Pro", architecture: "arm64", gpu: "Apple A18 Pro GPU", screen: "2622x1206 at 120 Hz, scale 3.0",
    network: "Wi-Fi", locale: "en-US", timeZone: "UTC+01:00",
    settings: [("Codec", "hevc"), ("Resolution", "1920x1080"), ("Frame rate", "60"), ("HDR", "off")])

/// The report text (DiagnosticReportTest and StreamSettingsSnapshotTest of DELOS for Android).
@Suite struct DiagnosticsReportTests {
    private let scrubber = LogScrubber(context: ScrubContext(pcNames: ["Meiton-PC"]))
    private let log = (1...300).map { "2026-11-10 12:00:00.000 I/Core [main] line \($0) for Meiton-PC at 192.168.0.200" }.joined(separator: "\n") + "\n"

    @Test func theDeviceBlockListsTheFactsOneLineEach() {
        let text = diagnosticsInfo.format()
        #expect(text.contains("Delos: 0.1.0 (release), build 100"))
        #expect(text.contains("Device: iPhone (iPhone17,1)"))
        #expect(text.contains("System: iOS 26.1, build 23B85"))
        #expect(text.contains("  Codec: hevc"))
        #expect(!text.contains("192.") && !text.contains("Meiton"))
        #expect(DeviceInfo.utcOffset(3600) == "UTC+01:00")
        #expect(DeviceInfo.utcOffset(-5 * 3600 - 1800) == "UTC-05:30")
    }

    @Test func theReportIsScrubbedAsAWholeAndCountsItsLines() {
        let report = DiagnosticReports.build(info: diagnosticsInfo, rawLog: log, scrubber: scrubber, generated: "now")
        #expect(report.logLines == 300)
        #expect(!report.text.contains("Meiton-PC") && !report.text.contains("192.168.0.200"))
        #expect(report.text.contains("line 300 for <pc-1> at <ip-1>"))
        #expect(report.text.contains("== Log (300 lines, oldest first) =="))
        #expect(report.bytes == report.text.utf8.count)
    }

    @Test func theSummaryKeepsTheNewestLinesOnly() {
        let summary = DiagnosticReports.summary(info: diagnosticsInfo, rawLog: log, scrubber: scrubber, generated: "now", tailLines: 100)
        #expect(summary.logLines == 100)
        #expect(summary.text.contains("line 300 ") && summary.text.contains("line 201 ") && !summary.text.contains("line 200 "))
    }

    @Test func sizesShowAsAndroidShowsThem() {
        #expect(DiagnosticReport.sizeText(512) == "512 B")
        #expect(DiagnosticReport.sizeText(1536) == "1.5 KB")
        #expect(DiagnosticReport.sizeText(200 * 1024) == "200 KB")
        #expect(DiagnosticReport.sizeText(1_300_000) == "1.2 MB")
    }

    @Test func thePreviewShowsTheHeaderAndTheLastLinesAndCountsWhatIsHidden() throws {
        let report = DiagnosticReports.build(info: diagnosticsInfo, rawLog: log, scrubber: scrubber, generated: "now")
        let parts = try #require(report.preview(tailLines: 10))
        #expect(parts.head.first == "Delos diagnostic report")
        #expect(parts.head.contains("== Device =="))
        #expect(parts.hidden == 290)
        #expect(parts.tail.last == "2026-11-10 12:00:00.000 I/Core [main] line 300 for <pc-1> at <ip-1>")
        let short = DiagnosticReports.build(info: diagnosticsInfo, rawLog: "2026-11-10 12:00:00.000 I/A [m] only\n", scrubber: scrubber, generated: "now")
        #expect(short.preview() == nil)
    }

    @Test func extraSectionsComeBeforeTheLog() throws {
        let report = DiagnosticReports.build(info: diagnosticsInfo, rawLog: log, scrubber: scrubber, generated: "now",
                                             sections: [("Problem", "Kind: CRASH")])
        let problem = try #require(report.text.range(of: "== Problem =="))
        let logStart = try #require(report.text.range(of: "== Log"))
        #expect(problem.lowerBound < logStart.lowerBound)
    }

    @Test func theFileNameIsTheTimeOfTheReport() {
        let date = Date(timeIntervalSince1970: 1_762_776_000)
        #expect(DiagnosticReports.fileName(date, zone: TimeZone(identifier: "UTC")!) == "delos-diagnostic-20251110-120000.txt")
        #expect(DiagnosticReports.generated(date, zone: TimeZone(identifier: "UTC")!) == "2025-11-10 12:00:00 (device time)")
    }

    @Test func onlyTheListedSettingsCanAppearInAReport() {
        var settings = StreamSettings(resolution: StreamResolution(width: 1920, height: 1080), fps: 120, bitrateKbps: 80_000)
        settings.hdr = true
        let snapshot = Dictionary(uniqueKeysWithValues: StreamSettingsSnapshot.read(settings))
        #expect(snapshot.count == 8)
        #expect(snapshot["Resolution"] == "1920x1080")
        #expect(snapshot["Frame rate"] == "120")
        #expect(snapshot["Bitrate"] == "80000 kbps")
        #expect(snapshot["HDR"] == "on")
        #expect(snapshot["Upscaler"] == "off")
    }
}

/// The cases of docs/DIAGNOSTICS.md, "Crash capture and the report offer" (ProblemDetectorTest of DELOS for Android).
@Suite struct ProblemDetectorTests {
    private let now: Int64 = 1_800_000_000_000
    private let minute: Int64 = 60_000
    private var day: Int64 { 24 * 60 * minute }

    private func crash(at: Int64? = nil, pid: Int32 = 100) -> CrashRecord {
        CrashRecord(whenMs: at ?? now - minute, pid: pid, thread: "main", exception: "NSInvalidArgumentException: boom",
                    stackTrace: "NSInvalidArgumentException: boom\nat DelosUI.Foo.bar() (DELOS)", logTail: ["l1"])
    }

    private func signals(records: Bool = true, crash: CrashRecord? = nil, exits: [ExitRecord] = [], session: SessionRecord? = nil,
                         pid: Int32 = 200) -> StartSignals {
        StartSignals(nowMs: now, exitRecordsAvailable: records, currentPid: pid, crash: crash, exits: exits, previousSession: session)
    }

    private func exit(_ kind: ExitKind, at: Int64? = nil, pid: Int32 = 100, text: String = "") -> ExitRecord {
        ExitRecord(timestamp: at ?? now - minute, pid: pid, kind: kind, description: text)
    }

    @Test func nothingHappenedMeansNoOffer() {
        let result = ProblemDetector.atStart(signals(), ledger: ProblemLedger())
        #expect(result.problem == nil && result.ledger == ProblemLedger())
    }

    @Test func aCrashFileOffersTheCrashWithItsSummaryOnce() throws {
        let first = ProblemDetector.atStart(signals(crash: crash()), ledger: ProblemLedger())
        let problem = try #require(first.problem)
        #expect(problem.kind == .crash)
        #expect(problem.summary == "NSInvalidArgumentException: boom (at DelosUI.Foo.bar)")
        #expect(problem.detail.contains("DelosUI.Foo.bar"))
        #expect(first.ledger.crashMs == now - minute)
        #expect(ProblemDetector.atStart(signals(crash: crash()), ledger: first.ledger).problem == nil)
        #expect(ProblemDetector.atStart(signals(crash: crash(at: now)), ledger: first.ledger).problem?.kind == .crash)
    }

    @Test func theSystemsCrashAndHangRecordsAreOfferedOnce() throws {
        let native = try #require(ProblemDetector.atStart(signals(exits: [exit(.crash, text: "EXC_BAD_ACCESS, signal 11 (SIGSEGV)")]),
                                                          ledger: ProblemLedger()).problem)
        #expect(native.kind == .nativeCrash && native.viaExitRecord)
        #expect(native.summary == "Native crash: EXC_BAD_ACCESS, signal 11 (SIGSEGV)")
        let hangs = [exit(.hang, text: "hang of 2.5 s")]
        let hang = ProblemDetector.atStart(signals(exits: hangs), ledger: ProblemLedger())
        #expect(hang.problem?.kind == .hang)
        #expect(hang.problem?.summary == "Not responding: hang of 2.5 s")
        #expect(ProblemDetector.atStart(signals(exits: hangs), ledger: hang.ledger).problem == nil)
        let other = ProblemDetector.atStart(signals(exits: [exit(.other)]), ledger: ProblemLedger())
        #expect(other.problem == nil && other.ledger.exitMs == now - minute)
    }

    @Test func theSystemsRecordOfTheSameProcessIsTheSameCrash() throws {
        let result = ProblemDetector.atStart(signals(crash: crash(pid: 100), exits: [exit(.crash, pid: 100)]), ledger: ProblemLedger())
        #expect(result.problem?.id == "crash-\(now - minute)")
        #expect(ProblemDetector.atStart(signals(exits: [exit(.crash, pid: 100)]), ledger: result.ledger).problem == nil)
    }

    @Test func withoutSystemRecordsAForegroundExitIsTheFallback() {
        let session = SessionRecord(pid: 100, startedAtMs: now - 10 * minute, updatedAtMs: now - 9 * minute, inForeground: true)
        let result = ProblemDetector.atStart(signals(records: false, session: session), ledger: ProblemLedger())
        #expect(result.problem?.kind == .uncleanExit)
        #expect(ProblemDetector.atStart(signals(records: false, session: session), ledger: result.ledger).problem == nil)
        // With the system's records the marker is not used; in the background, of this process or after a crash it is no problem
        #expect(ProblemDetector.atStart(signals(session: session), ledger: ProblemLedger()).problem == nil)
        var background = session
        background.inForeground = false
        #expect(ProblemDetector.atStart(signals(records: false, session: background), ledger: ProblemLedger()).problem == nil)
        #expect(ProblemDetector.atStart(signals(records: false, session: session, pid: 100), ledger: ProblemLedger()).problem == nil)
        let crashed = ProblemDetector.atStart(signals(records: false, crash: crash(pid: 100), session: session), ledger: ProblemLedger())
        #expect(crashed.problem?.kind == .crash && crashed.ledger.sessionMs == now - 10 * minute)
    }

    @Test func severalProblemsGiveOneOfferWithTheRichestFirstAndTheNewestOfAKind() {
        let exits = [exit(.hang, at: now - 30 * minute, pid: 50), exit(.crash, at: now - 20 * minute, pid: 60)]
        let result = ProblemDetector.atStart(signals(crash: crash(pid: 100), exits: exits), ledger: ProblemLedger())
        #expect(result.problem?.kind == .crash)
        #expect(ProblemDetector.atStart(signals(crash: crash(pid: 100), exits: exits), ledger: result.ledger).problem == nil)
        let two = ProblemDetector.atStart(
            signals(exits: [exit(.hang, at: now - 50 * minute, pid: 1, text: "old"), exit(.hang, at: now - 5 * minute, pid: 2, text: "new")]),
            ledger: ProblemLedger())
        #expect(two.problem?.subject == "new")
    }

    @Test func signalsOlderThanAWeekAreDroppedButStillMarked() {
        let old = now - 8 * day
        let result = ProblemDetector.atStart(signals(crash: crash(at: old), exits: [exit(.hang, at: old)]), ledger: ProblemLedger())
        #expect(result.problem == nil && result.ledger.crashMs == old && result.ledger.exitMs == old)
    }

    @Test func aFailedStreamIsOfferedOnceAndThenWaitsOutTheCooldown() {
        let first = ProblemDetector.streamFailed(ledger: ProblemLedger(), nowMs: now, title: "Connection lost", details: "Error 5")
        #expect(first.problem?.kind == .streamFailed && first.problem?.detail == "Error 5" && first.ledger.streamOfferMs == now)
        #expect(ProblemDetector.streamFailed(ledger: first.ledger, nowMs: now + 5 * minute, title: "x", details: nil).problem == nil)
        #expect(ProblemDetector.streamFailed(ledger: first.ledger, nowMs: now + ProblemDetector.streamOfferCooldownMs, title: "x", details: nil)
            .problem != nil)
    }

    @Test func theLedgerAndTheExitRecordsAreKept() throws {
        let defaults = try #require(UserDefaults(suiteName: "diag-\(UUID().uuidString)"))
        let ledger = ProblemLedger(crashMs: 1, exitMs: 2, sessionMs: 3, streamOfferMs: 4)
        ProblemMonitor.writeLedger(ledger, defaults)
        #expect(ProblemMonitor.readLedger(defaults) == ledger)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString)")
        let records = (0..<20).map { ExitRecord(timestamp: Int64($0), pid: 1, kind: .hang, description: "\($0)") }
        ProblemMonitor.store(records, directory: folder)
        ProblemMonitor.store([records[19]], directory: folder)
        let kept = ProblemMonitor.readExits(folder)
        #expect(kept.count == ProblemMonitor.maxExits)
        #expect(kept.last?.description == "19" && kept.first?.description == "4")
    }
}

/// The prefilled draft (IssueUrlTest and ProblemIssueTest of DELOS for Android).
@Suite struct IssueURLTests {
    private let draft = IssueDraft(
        title: "Crash: NSInvalidArgumentException: boom", whatHappened: "Delos stopped unexpectedly the last time.\nIt was reported from the app.",
        device: "iPhone iPhone17,1, iOS 26.1", build: "Delos 0.1.0 (release), build 100", streamSettings: "Codec hevc, Frame rate 60",
        logs: "NSInvalidArgumentException: boom\nat DelosUI.Foo.bar() (DELOS)", area: "Other")
    private let link = "https://delos-reports.example.workers.dev/r/AbCdEfGhIjKlMnOpQrStUv"

    private func params(_ url: String) -> [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(string: url)?.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }

    @Test func theAddressOpensTheFormMadeForTheAppWithEveryField() {
        let url = IssueURL.build(draft)
        #expect(url.hasPrefix("https://github.com/DELOS-STREAM/DELOS-apple/issues/new?template=app_report.yml&title="))
        let p = params(url)
        #expect(p["labels"] == nil)
        #expect(p["title"] == draft.title && p["what-happened"] == draft.whatHappened && p["area"] == "Other")
        #expect(p["device"] == draft.device && p["build"] == draft.build && p["stream-settings"] == draft.streamSettings && p["logs"] == draft.logs)
        var unset = draft
        unset.area = nil
        #expect(!IssueURL.build(unset).contains("&area="))
    }

    @Test func reservedCharactersNeverEndUpRawInAValue() {
        var odd = draft
        odd.whatHappened = "a&b=c#d?e f+g%h\n\"q\" <x> é"
        let url = IssueURL.build(odd)
        let query = String(url[url.index(after: url.firstIndex(of: "?")!)...])
        #expect(query.filter { $0 == "&" }.count == 7)
        #expect(!query.contains(" ") && !query.contains("#") && !query.contains("<") && !query.contains("\"") && !query.contains("\n"))
        #expect(params(url)["what-happened"] == odd.whatHappened)
    }

    @Test func longTextIsCutLogFirstAndNeverInsideAnEscape() {
        var long = draft
        long.logs = (1...2000).map { "at DelosUI.Frame\($0).run() (DELOS)" }.joined(separator: "\n")
        let url = IssueURL.build(long)
        #expect(url.count <= IssueURL.maxLength)
        #expect(params(url)["logs"]?.hasSuffix("the full log is in the attached file)") == true)
        #expect(params(url)["what-happened"] == draft.whatHappened)
        var wordy = draft
        wordy.whatHappened = String(repeating: "What I did before the crash. ", count: 2000)
        let cut = params(IssueURL.build(wordy))
        #expect(cut["logs"] == "" && wordy.whatHappened.hasPrefix(cut["what-happened"] ?? "x"))
        var accents = draft
        accents.logs = String(repeating: "é", count: 5000)
        let small = IssueURL.build(accents, maxLength: 900)
        #expect(small.count <= 900)
        #expect(small.range(of: "%[0-9A-F]?$", options: .regularExpression) == nil)
    }

    @Test func everyFreeTextFieldPassesTheScrubberButTheLinkAndTheNoteDoNot() {
        let scrubber = LogScrubber(context: ScrubContext(pcNames: ["Meiton-PC"]))
        var dirty = draft
        dirty.title = "Stream to Meiton-PC failed"
        dirty.whatHappened = "Could not reach Meiton-PC at 192.168.0.200"
        dirty.logs = "poll Meiton-PC (192.168.0.200:47989)"
        dirty.logLink = link
        dirty.attachmentNote = "saved as `delos-diagnostic-20261110-120000.txt`"
        let p = params(IssueURL.build(dirty, scrub: scrubber.scrub))
        let text = p.values.joined(separator: "\n")
        #expect(!text.contains("Meiton-PC") && !text.contains("192.168.0.200") && text.contains("<pc-1>"))
        #expect(p["what-happened"]?.hasPrefix("Diagnostic log: \(link)\n\n") == true)
        #expect(p["what-happened"]?.hasSuffix("\n\nsaved as `delos-diagnostic-20261110-120000.txt`") == true)
        var huge = dirty
        huge.whatHappened = String(repeating: "word ", count: 3000)
        #expect(params(IssueURL.build(huge, maxLength: 700))["what-happened"]?.hasPrefix("Diagnostic log: \(link)") == true)
    }

    @Test func theDraftCarriesTheFactsAndWhereTheLogIs() {
        let trace = "NSInvalidArgumentException: boom\n" + (1...30).map { "at DelosUI.Frame\($0).run() (DELOS)" }.joined(separator: "\n")
        let crash = Problem(id: "crash-1", kind: .crash, atMs: 1, subject: "NSInvalidArgumentException: boom (at DelosUI.Frame1.run)", detail: trace)
        let draft = ProblemIssue.draft(crash, info: diagnosticsInfo, attachment: .file(name: "f.txt", folder: "the Downloads folder"))
        #expect(draft.title == "Crash: NSInvalidArgumentException: boom (at DelosUI.Frame1.run)")
        #expect(draft.device == "iPhone iPhone17,1, iOS 26.1")
        #expect(draft.build == "Delos 0.1.0 (release), build 100")
        #expect(draft.streamSettings == "Codec hevc, Resolution 1920x1080, Frame rate 60, HDR off")
        #expect(draft.area == "Other" && draft.logLink == nil)
        #expect(draft.attachmentNote.contains("`f.txt` in the Downloads folder"))
        let logs = ProblemIssue.logsText(crash)
        #expect(logs.components(separatedBy: "\n").filter { $0.hasPrefix("at ") }.count == 12 && !logs.contains("Frame13"))
        #expect(ProblemIssue.section(crash, detectedAt: "then").hasPrefix("Kind: CRASH\nDetected: then\nSummary: NSInvalidArgumentException: boom"))
        let uploaded = ProblemIssue.draft(crash, info: diagnosticsInfo, attachment: .link(link, expires: "2026-12-20T10:00:00.000Z"))
        #expect(uploaded.logLink == link && uploaded.attachmentNote.contains("2026-12-20") && !uploaded.attachmentNote.contains(".txt"))
    }

    @Test func aFailedStreamAHangAndAManualReportKeepTheirOwnWords() {
        let file = ReportAttachment.file(name: "f.txt", folder: "the Downloads folder")
        let stream = ProblemIssue.draft(Problem(id: "s", kind: .streamFailed, atMs: 1, subject: "Connection lost", detail: "Error 5"),
                                        info: diagnosticsInfo, attachment: file)
        #expect(stream.title == "Stream failed: Connection lost" && stream.area == "Pairing/connection" && stream.logs == "Connection lost\n\nError 5")
        let hang = ProblemIssue.draft(Problem(id: "h", kind: .hang, atMs: 1, subject: "hang of 3.0 s", detail: "hang of 3.0 s", viaExitRecord: true),
                                      info: diagnosticsInfo, attachment: file)
        #expect(hang.title == "Not responding: hang of 3.0 s")
        let bare = ProblemIssue.draft(Problem(id: "n", kind: .nativeCrash, atMs: 1, subject: "", detail: "", viaExitRecord: true),
                                      info: diagnosticsInfo, attachment: file)
        #expect(bare.title == "Native crash")
        let manual = ProblemIssue.manualDraft(info: diagnosticsInfo, attachment: file)
        #expect(manual.title.isEmpty && manual.logs.isEmpty && manual.area == nil && manual.attachmentNote.contains("`f.txt`"))
    }
}

/// The form file the address names (IssueFormContractTest of DELOS for Android): every field the app fills in exists with a
/// type that takes it, and the form sets its labels itself.
@Suite struct IssueFormContractTests {
    @Test func theAppReportFormHasEveryFieldTheAppSends() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(".github/ISSUE_TEMPLATE/\(IssueURL.template)"), encoding: .utf8)
        #expect(text.contains("labels: [bug, from-app, needs-triage]"))
        // Each `- type:` element with its id
        var types: [String: String] = [:]
        var currentType: String?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- type:") { currentType = trimmed.replacingOccurrences(of: "- type:", with: "").trimmingCharacters(in: .whitespaces) }
            if trimmed.hasPrefix("id:"), let currentType { types[trimmed.replacingOccurrences(of: "id:", with: "").trimmingCharacters(in: .whitespaces)] = currentType }
        }
        #expect(types["what-happened"] == "textarea")
        #expect(types["logs"] == "textarea")
        #expect(types["area"] == "dropdown")
        for id in ["device", "build", "stream-settings"] { #expect(["input", "textarea"].contains(types[id] ?? ""), "\(id)") }
        #expect(text.contains("- \(IssueURL.areaOther)\n") && text.contains("- \(IssueURL.areaConnection)\n"))
    }
}

/// A stand-in report service: the answer for each host, and what it received.
final class ReportService: URLProtocol, @unchecked Sendable {
    typealias Answer = @Sendable (URLRequest) -> Result<(Int, String), URLError>
    static let answers = Mutex<[String: Answer]>([:])
    static let received = Mutex<[String: [(path: String, headers: [String: String], body: Data)]]>([:])

    /// A uploader whose service answers with [answer]; its address is unique to the test.
    static func uploader(_ answer: @escaping Answer) -> (ReportUploader, String) {
        let host = "reports-\(UUID().uuidString.lowercased()).example"
        answers.withLock { $0[host] = answer }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReportService.self]
        return (ReportUploader(baseURL: "https://\(host)", configuration: configuration), "https://\(host)")
    }

    static func seen(_ base: String) -> [(path: String, headers: [String: String], body: Data)] {
        received.withLock { $0[URL(string: base)!.host!] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let host = request.url?.host ?? ""
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        Self.received.withLock { $0[host, default: []].append((request.url?.path ?? "", headers, body)) }
        guard let answer = Self.answers.withLock({ $0[host] }) else { return }
        switch answer(request) {
        case let .success((status, text)):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

/// The upload and the choice between upload and saving (ReportUploaderTest and ReportSubmissionTest of DELOS for Android).
@Suite struct ReportUploadTests {
    private let id = "AbCdEfGhIjKlMnOpQrStUv"
    private let report = "Delos diagnostic report\n== Log (1 lines, oldest first) ==\n2026-11-10 12:34:56.789 I/Stream [main] started\n"

    private func created(_ base: String, linkID: String? = nil) -> String {
        #"{"id":"\#(id)","url":"\#(base)/r/\#(linkID ?? id)","expires":"2026-12-20T10:00:00.000Z","rescrubbed":2}"#
    }

    @Test func aSuccessfulUploadSendsGzippedUTF8TextAndReturnsTheLink() async throws {
        let base = Mutex("")
        let (uploader, address) = ReportService.uploader { _ in .success((201, created(base.withLock { $0 }))) }
        base.withLock { $0 = address }
        #expect(await uploader.upload(report) == .uploaded(link: "\(address)/r/\(id)", expires: "2026-12-20T10:00:00.000Z", rescrubbed: 2))
        let seen = try #require(ReportService.seen(address).first)
        #expect(seen.path == "/v1/reports")
        #expect(seen.headers["content-type"] == "text/plain; charset=utf-8")
        #expect(seen.headers["content-encoding"] == "gzip")
        // gzip: the header, raw DEFLATE, then the CRC-32 and the length of the text
        let body = seen.body
        #expect(body.prefix(3) == Data([0x1F, 0x8B, 0x08]))
        let deflated = body.subdata(in: 10..<(body.count - 8))
        let text = try (deflated as NSData).decompressed(using: .zlib) as Data
        #expect(String(decoding: text, as: UTF8.self) == report)
        let crc = body.subdata(in: (body.count - 8)..<(body.count - 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: crc) == Gzip.crc32(Data(report.utf8)))
    }

    @Test func theCRCIsTheStandardOne() {
        #expect(Gzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func theStatusOfTheAnswerSaysWhyItFailed() async {
        let cases: [(Int, String, UploadFailure)] = [
            (429, #"{"error":"x"}"#, .rateLimited), (413, "", .tooLarge), (500, "", .serviceError), (502, "", .serviceError),
            (503, #"{"error":"daily_limit"}"#, .dailyLimit), (503, #"{"error":"storage_unavailable"}"#, .serviceError), (503, "<html>", .serviceError),
            (400, "", .rejected), (404, "", .rejected), (200, "", .rejected), (307, "", .rejected),
        ]
        for (status, body, expected) in cases {
            let (uploader, _) = ReportService.uploader { _ in .success((status, body)) }
            #expect(await uploader.upload(report) == .failed(expected), "status \(status)")
        }
    }

    @Test func anAnswerThatIsNotTheServicesIsMalformed() async {
        let bad: [@Sendable (String) -> String] = [
            { _ in "not json" }, { _ in "" }, { _ in "[]" }, { _ in "{}" },
            { _ in #"{"id":"\#(id)","expires":"x"}"# },
            { b in #"{"id":"short","url":"\#(b)/r/short","expires":"x"}"# },
            { _ in #"{"id":"\#(id)","url":"https://evil.example/r/\#(id)","expires":"x"}"# },
            { b in #"{"id":"\#(id)","url":"\#(b)/r/other0000000000000000a","expires":"x"}"# },
            { b in #"{"id":"\#(id)","url":"\#(b)/r/\#(id)?x=1","expires":"x"}"# },
            { b in #"{"id":"\#(id)","url":"\#(b)/elsewhere/\#(id)","expires":"x"}"# },
            { b in #"{"id":"\#(id)","url":"\#(b)/r/\#(id)"}"# },
            { b in #"{"id":5,"url":"\#(b)/r/\#(id)","expires":"x"}"# },
        ]
        for make in bad {
            let base = Mutex("")
            let (uploader, address) = ReportService.uploader { _ in .success((201, make(base.withLock { $0 }))) }
            base.withLock { $0 = address }
            #expect(await uploader.upload(report) == .failed(.malformed), "\(make(address))")
        }
    }

    @Test func noAnswerIsATimeoutAndNoConnectionIsOffline() async {
        let (slow, _) = ReportService.uploader { _ in .failure(URLError(.timedOut)) }
        #expect(await slow.upload(report) == .failed(.timeout))
        let (offline, _) = ReportService.uploader { _ in .failure(URLError(.notConnectedToInternet)) }
        #expect(await offline.upload(report) == .failed(.offline))
    }

    @Test func aReportOverTheLimitIsNeverSentAndWithoutAnAddressTheFeatureIsOff() async {
        let (uploader, address) = ReportService.uploader { _ in .success((201, "")) }
        #expect(await uploader.upload(String(repeating: "x", count: ReportUploader.maxBytes + 1)) == .failed(.tooLarge))
        #expect(ReportService.seen(address).isEmpty)
        #expect(!ReportUploader(baseURL: "").enabled)
        #expect(!ReportUploader(baseURL: "   ").enabled)
        #expect(!ReportUploader(baseURL: "not a url").enabled)
        #expect(!ReportUploader(baseURL: "http://reports.example.com").enabled)
        #expect(ReportUploader(baseURL: "https://reports.example.com").enabled)
        #expect(await ReportUploader(baseURL: "").upload(report) == .failed(.rejected))
    }

    @Test func aReportThatIsTooBigLosesItsOldestLogLinesAndKeepsTheHeader() {
        #expect(ReportUploader.fit(report) == report)
        let lines = (1...200).map { "2026-11-10 12:34:56.789 I/Stream [main] line number \($0)" }
        let text = "Delos diagnostic report\n== Device ==\nModel x\n== Log (200 lines, oldest first) ==\n" + lines.joined(separator: "\n") + "\n"
        let fitted = ReportUploader.fit(text, maxBytes: 2000)
        #expect(fitted.utf8.count <= 2000)
        #expect(fitted.hasPrefix("Delos diagnostic report\n== Device ==\nModel x\n== Log (200 lines, oldest first) ==\n"))
        #expect(fitted.contains("older log lines were left out"))
        let kept = fitted.components(separatedBy: "\n").filter { $0.contains("line number") }.compactMap { Int($0.components(separatedBy: "number ").last ?? "") }
        #expect(kept == kept.sorted() && kept.last == 200 && !fitted.contains("line number 1\n"))
    }

    private func prepared() -> PreparedReport {
        let problem = Problem(id: "crash-1", kind: .crash, atMs: 1, subject: "NSInvalidArgumentException: boom", detail: "trace")
        let scrubber = LogScrubber()
        return PreparedReport(report: DiagnosticReport(text: report, logLines: 1), fileName: "delos-diagnostic-20261120-100000.txt",
                              folder: "the Downloads folder") { attachment in
            IssueURL.build(ProblemIssue.draft(problem, info: diagnosticsInfo, attachment: attachment), scrub: scrubber.scrub)
        }
    }

    private func what(_ url: String) -> String {
        URLComponents(string: url)?.queryItems?.first { $0.name == "what-happened" }?.value ?? ""
    }

    @Test func anUploadPutsTheLinkIntoTheDraftAndSavesNothing() async {
        let base = Mutex("")
        let (uploader, address) = ReportService.uploader { _ in .success((201, created(base.withLock { $0 }))) }
        base.withLock { $0 = address }
        let saves = Mutex(0)
        let result = await ReportSubmission.run(prepared(), mode: .upload, uploader: uploader) { _, _ in saves.withLock { $0 += 1 }; return true }
        guard case let .uploaded(url, link, _) = result else { Issue.record("\(result)"); return }
        #expect(link == "\(address)/r/\(id)")
        #expect(saves.withLock { $0 } == 0)
        #expect(what(url).hasPrefix("Diagnostic log: \(link)\n\n") && what(url).contains("2026-12-20") && !what(url).contains(".txt"))
    }

    @Test func aFailedUploadSavesTheFileAndSaysWhy() async {
        let (uploader, _) = ReportService.uploader { _ in .success((429, "")) }
        let result = await ReportSubmission.run(prepared(), mode: .upload, uploader: uploader) { _, _ in true }
        #expect(result == .saved(issueURL: result.issueURL, fileName: "delos-diagnostic-20261120-100000.txt", uploadFailure: .rateLimited))
        #expect(what(result.issueURL).contains("`delos-diagnostic-20261120-100000.txt` in the Downloads folder"))
        let notSaved = await ReportSubmission.run(prepared(), mode: .upload, uploader: uploader) { _, _ in false }
        #expect(notSaved == .notSaved(issueURL: notSaved.issueURL, uploadFailure: .rateLimited) && !notSaved.succeeded)
    }

    @Test func savingInsteadUploadsNothing() async {
        let (uploader, address) = ReportService.uploader { _ in .success((201, "")) }
        let result = await ReportSubmission.run(prepared(), mode: .save, uploader: uploader) { _, _ in true }
        #expect(result == .saved(issueURL: result.issueURL, fileName: "delos-diagnostic-20261120-100000.txt", uploadFailure: nil))
        #expect(ReportService.seen(address).isEmpty)
    }
}
