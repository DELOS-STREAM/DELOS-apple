import DelosCore
import Foundation

// What the next start offers a report for (docs/DIAGNOSTICS.md; ProblemDetector.kt of DELOS for Android).

/// What went wrong, in the order the detector prefers when several happened since the last start. The card's sentence is built
/// by the interface in the user's language (``ProblemOfferCard``); [issueSentence] is the English line of the prefilled issue,
/// which stays English because the developers read it.
public enum ProblemKind: String, Sendable, CaseIterable {
    /// The app's own crash handler caught it (an uncaught exception or a fatal signal): `JAVA_CRASH` of Android, whose handler
    /// plays the same part.
    case crash = "CRASH"
    /// The system's record of a crash (MetricKit), with its description.
    case nativeCrash = "NATIVE_CRASH"
    /// The system's record of the app not responding (MetricKit's hang), Android's `ANR`.
    case hang = "HANG"
    /// The process ended while the app was in front, without any other record (Apple TV, which has no MetricKit).
    case uncleanExit = "UNCLEAN_EXIT"
    case streamFailed = "STREAM_FAILED"

    public var issueSentence: String {
        switch self {
        case .crash: "Delos stopped unexpectedly the last time."
        case .nativeCrash: "Delos crashed in its native code the last time."
        case .hang: "Delos stopped responding the last time."
        case .uncleanExit: "Delos did not close normally the last time."
        case .streamFailed: "The last stream could not run."
        }
    }
}

/// Why an earlier process of the app ended, as the system's diagnostics tell it (MetricKit on iPhone, iPad and Mac).
public enum ExitKind: String, Sendable, Codable {
    case crash, hang, other
}

public struct ExitRecord: Sendable, Equatable, Codable {
    public var timestamp: Int64
    public var pid: Int32
    public var kind: ExitKind
    public var description: String

    public init(timestamp: Int64, pid: Int32, kind: ExitKind, description: String) {
        self.timestamp = timestamp
        self.pid = pid
        self.kind = kind
        self.description = description
    }
}

/// A problem to offer a report for, as typed facts (`Problem`): the [kind], the [subject] (the crash summary, the system's
/// description, the title of a failed stream; empty when there is none) and [detail] (the stack trace or the system's
/// description; scrubbed before use). [viaExitRecord]: only the system's record told of it.
public struct Problem: Sendable, Equatable, Identifiable {
    /// The longest summary line; longer subjects are cut (the detail keeps everything).
    public static let summaryMax = 180

    public let id: String
    public let kind: ProblemKind
    public let atMs: Int64
    public let subject: String
    public let detail: String
    public let viaExitRecord: Bool

    public init(id: String, kind: ProblemKind, atMs: Int64, subject: String, detail: String, viaExitRecord: Bool = false) {
        self.id = id
        self.kind = kind
        self.atMs = atMs
        self.subject = subject
        self.detail = detail
        self.viaExitRecord = viaExitRecord
    }

    /// The English one-liner for the log, the issue draft and the report; never shown on the card.
    public var summary: String {
        switch kind {
        case .crash: viaExitRecord ? withSubject("Crash") : subject
        case .nativeCrash: withSubject("Native crash")
        case .hang: withSubject("Not responding")
        case .uncleanExit: "The app was in the foreground when its process ended"
        case .streamFailed: subject
        }
    }

    private func withSubject(_ what: String) -> String {
        subject.trimmingCharacters(in: .whitespaces).isEmpty ? what : String("\(what): \(subject)".prefix(Self.summaryMax))
    }
}

/// What was already offered: one number per source, so nothing is offered twice (stored by ``ProblemMonitor``).
public struct ProblemLedger: Sendable, Equatable {
    public var crashMs: Int64 = 0
    public var exitMs: Int64 = 0
    public var sessionMs: Int64 = 0
    public var streamOfferMs: Int64 = 0

    public init(crashMs: Int64 = 0, exitMs: Int64 = 0, sessionMs: Int64 = 0, streamOfferMs: Int64 = 0) {
        self.crashMs = crashMs
        self.exitMs = exitMs
        self.sessionMs = sessionMs
        self.streamOfferMs = streamOfferMs
    }
}

/// Everything the detector reads at a start. [exitRecordsAvailable]: the system keeps exit records here (MetricKit); without
/// them (Apple TV) the session marker is the fallback, as on Android before API 30.
public struct StartSignals: Sendable {
    public var nowMs: Int64
    public var exitRecordsAvailable: Bool
    public var currentPid: Int32
    public var crash: CrashRecord?
    public var exits: [ExitRecord]
    public var previousSession: SessionRecord?

    public init(nowMs: Int64, exitRecordsAvailable: Bool, currentPid: Int32, crash: CrashRecord?, exits: [ExitRecord],
                previousSession: SessionRecord?) {
        self.nowMs = nowMs
        self.exitRecordsAvailable = exitRecordsAvailable
        self.currentPid = currentPid
        self.crash = crash
        self.exits = exits
        self.previousSession = previousSession
    }
}

/// The problem to offer now (or nil) and the ledger to store, which already counts it as offered.
public struct Detection: Sendable, Equatable {
    public var problem: Problem?
    public var ledger: ProblemLedger
}

/// The state machine behind the report offer (`ProblemDetector`): it turns the markers of the last run into at most one
/// ``Problem``, and every source it looked at is marked in the ledger, so the same problem is never offered a second time,
/// whether it was reported, dismissed or ignored.
public enum ProblemDetector {
    /// Older signals are no longer the user's concern: an offer a week late would confuse.
    public static let maxAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000
    /// After an offer for a failed stream the next one waits this long (a PC that is off fails every time).
    public static let streamOfferCooldownMs: Int64 = 30 * 60 * 1000

    public static func atStart(_ signals: StartSignals, ledger: ProblemLedger) -> Detection {
        var candidates: [Problem] = []
        func fresh(_ ms: Int64) -> Bool { signals.nowMs - ms <= maxAgeMs }

        if let crash = signals.crash, crash.whenMs > ledger.crashMs, fresh(crash.whenMs) {
            candidates.append(Problem(id: "crash-\(crash.whenMs)", kind: .crash, atMs: crash.whenMs, subject: CrashFile.summary(crash),
                                      detail: crash.stackTrace))
        }

        let newExits = signals.exits.filter { $0.timestamp > ledger.exitMs }
        for exit in newExits where fresh(exit.timestamp) {
            let kind: ProblemKind?
            switch exit.kind {
            // The handler's own file tells more; the system's record of the same process is the same crash
            case .crash: kind = signals.crash?.pid == exit.pid ? nil : .nativeCrash
            case .hang: kind = .hang
            case .other: kind = nil
            }
            guard let kind else { continue }
            candidates.append(Problem(id: "exit-\(exit.timestamp)", kind: kind, atMs: exit.timestamp, subject: exit.description,
                                      detail: exit.description, viaExitRecord: true))
        }

        let session = signals.previousSession
        let useSession = !signals.exitRecordsAvailable
        if useSession, let session, session.inForeground, session.pid != signals.currentPid, session.startedAtMs > ledger.sessionMs,
           fresh(session.updatedAtMs), signals.crash?.pid != session.pid {
            candidates.append(Problem(id: "session-\(session.startedAtMs)", kind: .uncleanExit, atMs: session.updatedAtMs, subject: "", detail: ""))
        }

        var next = ledger
        next.crashMs = max(ledger.crashMs, signals.crash?.whenMs ?? 0)
        next.exitMs = max(ledger.exitMs, newExits.map(\.timestamp).max() ?? 0)
        if useSession { next.sessionMs = max(ledger.sessionMs, session?.startedAtMs ?? 0) }
        // The richest signal wins: the handler's crash has a stack trace, the system's records have its description
        let order = ProblemKind.allCases
        let best = candidates.min { a, b in
            let ia = order.firstIndex(of: a.kind) ?? 0, ib = order.firstIndex(of: b.kind) ?? 0
            return ia != ib ? ia < ib : a.atMs > b.atMs
        }
        return Detection(problem: best, ledger: next)
    }

    /// A stream that failed (the secondary entry): offered unless one was offered within the cooldown.
    public static func streamFailed(ledger: ProblemLedger, nowMs: Int64, title: String, details: String?) -> Detection {
        guard nowMs - ledger.streamOfferMs >= streamOfferCooldownMs else { return Detection(problem: nil, ledger: ledger) }
        let problem = Problem(id: "stream-\(nowMs)", kind: .streamFailed, atMs: nowMs, subject: String(title.prefix(Problem.summaryMax)),
                              detail: details ?? "")
        var next = ledger
        next.streamOfferMs = nowMs
        return Detection(problem: problem, ledger: next)
    }
}
