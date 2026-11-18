import DelosCore
import Foundation
import Synchronization
#if canImport(MetricKit) && !os(tvOS)
import MetricKit
#endif

/// Reads what the last run left and decides, once per problem, whether to offer a report (`ProblemMonitor` of DELOS for
/// Android; the state machine is ``ProblemDetector``). The ledger of what was offered lives in the standard defaults; the
/// system's records of earlier exits (MetricKit's crash and hang diagnostics, delivered at a later start) are kept in
/// `exits.json` beside the log until they are offered.
public enum ProblemMonitor {
    static let ledgerKeys = (crash: "diag_problems_crash_ms", exit: "diag_problems_exit_ms", session: "diag_problems_session_ms",
                             stream: "diag_problems_stream_offer_ms")
    static let exitsFile = "exits.json"
    /// The newest records kept.
    static let maxExits = 16

    private static let lock = Mutex(false)

    /// The system keeps diagnostics of earlier exits here: MetricKit on iPhone, iPad and Mac, nothing on Apple TV.
    public static var exitRecordsAvailable: Bool {
        #if canImport(MetricKit) && !os(tvOS)
        true
        #else
        false
        #endif
    }

    /// The problem to offer now, or nil. Called at the start and again when the system delivers new diagnostics; the ledger keeps
    /// it from offering anything twice. Call it off the main thread.
    public static func detect(defaults: UserDefaults = .standard, directory: URL = DiagLog.defaultDirectory) -> Problem? {
        lock.withLock { _ in
            let signals = StartSignals(
                nowMs: CrashReporter.nowMs(), exitRecordsAvailable: exitRecordsAvailable, currentPid: getpid(), crash: CrashReporter.readCrash(),
                exits: readExits(directory), previousSession: CrashReporter.previousSession)
            let detection = ProblemDetector.atStart(signals, ledger: readLedger(defaults))
            writeLedger(detection.ledger, defaults)
            if let problem = detection.problem { DiagLog.i("Problem", "Offering a report: \(problem.kind.rawValue) \(problem.summary)") }
            return detection.problem
        }
    }

    /// A failed stream as a problem to offer, unless one was offered recently.
    public static func streamFailed(title: String, details: String?, defaults: UserDefaults = .standard) -> Problem? {
        lock.withLock { _ in
            let detection = ProblemDetector.streamFailed(ledger: readLedger(defaults), nowMs: CrashReporter.nowMs(), title: title, details: details)
            writeLedger(detection.ledger, defaults)
            return detection.problem
        }
    }

    /// The user dismissed or reported [problem]: its crash files are not needed any more.
    public static func resolve(_ problem: Problem) {
        DiagLog.i("Problem", "Handled: \(problem.kind.rawValue) \(problem.id)")
        if problem.kind == .crash { CrashReporter.clearCrash() }
    }

    // MARK: Exit records

    /// Adds the system's records of earlier exits (the newest ``maxExits`` are kept).
    public static func store(_ records: [ExitRecord], directory: URL = DiagLog.defaultDirectory) {
        guard !records.isEmpty else { return }
        lock.withLock { _ in
            var all = readExits(directory)
            for record in records where !all.contains(record) { all.append(record) }
            all = Array(all.sorted { $0.timestamp < $1.timestamp }.suffix(maxExits))
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(all) {
                try? data.write(to: directory.appendingPathComponent(exitsFile), options: .atomic)
            }
        }
    }

    static func readExits(_ directory: URL) -> [ExitRecord] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(exitsFile)) else { return [] }
        return (try? JSONDecoder().decode([ExitRecord].self, from: data)) ?? []
    }

    static func readLedger(_ defaults: UserDefaults) -> ProblemLedger {
        func value(_ key: String) -> Int64 { (defaults.object(forKey: key) as? NSNumber)?.int64Value ?? 0 }
        return ProblemLedger(crashMs: value(ledgerKeys.crash), exitMs: value(ledgerKeys.exit), sessionMs: value(ledgerKeys.session),
                             streamOfferMs: value(ledgerKeys.stream))
    }

    static func writeLedger(_ ledger: ProblemLedger, _ defaults: UserDefaults) {
        defaults.set(NSNumber(value: ledger.crashMs), forKey: ledgerKeys.crash)
        defaults.set(NSNumber(value: ledger.exitMs), forKey: ledgerKeys.exit)
        defaults.set(NSNumber(value: ledger.sessionMs), forKey: ledgerKeys.session)
        defaults.set(NSNumber(value: ledger.streamOfferMs), forKey: ledgerKeys.stream)
    }
}

#if canImport(MetricKit) && !os(tvOS)
/// Receives the system's crash and hang diagnostics of earlier runs (MetricKit; Android's `getHistoricalProcessExitReasons`)
/// and keeps them as exit records; [onNew] runs after new ones arrived (on MetricKit's queue).
public final class SystemExitDiagnostics: NSObject, MXMetricManagerSubscriber, Sendable {
    private let onNew: @Sendable () -> Void

    public init(onNew: @escaping @Sendable () -> Void) {
        self.onNew = onNew
        super.init()
        MXMetricManager.shared.add(self)
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var records: [ExitRecord] = []
        for payload in payloads {
            let when = Int64(payload.timeStampEnd.timeIntervalSince1970 * 1000)
            for crash in payload.crashDiagnostics ?? [] {
                records.append(ExitRecord(timestamp: when, pid: crash.metaData.pid, kind: .crash, description: Self.describe(crash)))
            }
            for hang in payload.hangDiagnostics ?? [] {
                let seconds = hang.hangDuration.converted(to: .seconds).value
                records.append(ExitRecord(timestamp: when, pid: hang.metaData.pid, kind: .hang,
                                          description: String(format: "hang of %.1f s", locale: Locale(identifier: "en_US_POSIX"), seconds)))
            }
        }
        guard !records.isEmpty else { return }
        DiagLog.i("Problem", "The system reported \(records.count) earlier crash or hang diagnostics")
        ProblemMonitor.store(records)
        onNew()
    }

    /// The system's own words: `EXC_BAD_ACCESS (SIGSEGV)`, the termination reason, the Objective-C exception.
    static func describe(_ crash: MXCrashDiagnostic) -> String {
        var parts: [String] = []
        if let type = crash.exceptionType?.int32Value { parts.append(machException(type)) }
        if let signal = crash.signal?.int32Value { parts.append("signal \(signal) (\(signalName(signal)))") }
        if let reason = crash.exceptionReason {
            parts.append("\(reason.exceptionName): \(reason.composedMessage)")
        } else if let termination = crash.terminationReason, !termination.isEmpty {
            parts.append(termination)
        }
        return parts.joined(separator: ", ")
    }

    private static func machException(_ type: Int32) -> String {
        switch type {
        case 1: "EXC_BAD_ACCESS"
        case 2: "EXC_BAD_INSTRUCTION"
        case 3: "EXC_ARITHMETIC"
        case 5: "EXC_SOFTWARE"
        case 6: "EXC_BREAKPOINT"
        case 10: "EXC_CRASH"
        case 11: "EXC_RESOURCE"
        case 12: "EXC_GUARD"
        default: "exception \(type)"
        }
    }

    private static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGSEGV: "SIGSEGV"
        case SIGBUS: "SIGBUS"
        case SIGILL: "SIGILL"
        case SIGFPE: "SIGFPE"
        case SIGABRT: "SIGABRT"
        case SIGTRAP: "SIGTRAP"
        case SIGKILL: "SIGKILL"
        default: "SIG\(signal)"
        }
    }
}
#endif
