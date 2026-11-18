import DelosCore
import Foundation

// The prefilled GitHub draft of a report (docs/DIAGNOSTICS.md, "Field-id contract of the issue forms"; ProblemIssue.kt and
// IssueUrl.kt of DELOS for Android).

/// Where the cleaned log of a report is, for the text of the draft.
public enum ReportAttachment: Sendable, Equatable {
    /// Saved as [name] in [folder] (the English words for it: "the Downloads folder", "the DELOS folder of the Files app"); the
    /// user attaches it in the browser.
    case file(name: String, folder: String)
    /// Uploaded to the report service: [link] is its address and [expires] the expiry (ISO 8601).
    case link(String, expires: String)
}

/// The fields of the repository's report form that the app fills in. [logs] is the one that is cut first when the address
/// would be too long; the full log is the uploaded or saved file.
public struct IssueDraft: Sendable, Equatable {
    public var title: String
    public var whatHappened: String
    public var device: String
    public var build: String
    public var streamSettings: String
    public var logs: String
    /// One of the form's Area options (``IssueURL/areaOther``, ``IssueURL/areaConnection``), or nil to leave it unset.
    public var area: String?
    /// The address of the cleaned log on the report service, or nil. It goes first into "What happened?" and is not scrubbed
    /// (the scrubber would replace the service's host); it comes from ``ReportUploader``, which accepts only a link of the service.
    public var logLink: String?
    /// What the app says about where the log is, added after "What happened?" without the scrubber (it would take a file name of
    /// 32 characters for a token); never cut.
    public var attachmentNote: String

    public init(title: String, whatHappened: String, device: String, build: String, streamSettings: String, logs: String,
                area: String? = nil, logLink: String? = nil, attachmentNote: String = "") {
        self.title = title
        self.whatHappened = whatHappened
        self.device = device
        self.build = build
        self.streamSettings = streamSettings
        self.logs = logs
        self.area = area
        self.logLink = logLink
        self.attachmentNote = attachmentNote
    }
}

/// The GitHub new-issue address with the form made for the app (`.github/ISSUE_TEMPLATE/app_report.yml`) filled in through
/// query parameters named after its field ids, a contract with every installed app (`IssueFormContractTests` compares them with
/// the form file). Nothing is sent by this: the browser opens it and the user reads, edits and submits the issue. Every free-text
/// field passes [scrub] first, and the address stays under [maxLength] characters; the link and the note are never cut. There is
/// no `labels` parameter: GitHub takes it only from people who may label issues, so the form sets its labels itself.
public enum IssueURL {
    public static let newIssue = "https://github.com/DELOS-STREAM/DELOS-apple/issues/new"
    public static let template = "app_report.yml"
    public static let areaOther = "Other"
    public static let areaConnection = "Pairing/connection"
    /// Browsers and GitHub accept far longer addresses; this keeps clear of any proxy limit.
    public static let maxLength = 6000
    public static let logLinkLabel = "Diagnostic log:"
    static let cutNote = "\n… (cut; the full log is in the attached file)"

    public static func build(_ draft: IssueDraft, scrub: (String) -> String = { $0 }, maxLength: Int = maxLength) -> String {
        let title = String(scrub(draft.title).prefix(120))
        let what = scrub(draft.whatHappened)
        let linkLine = draft.logLink.map { "\(logLinkLabel) \($0)\n\n" } ?? ""
        let note = draft.attachmentNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n" + draft.attachmentNote
        let device = String(scrub(draft.device).prefix(300))
        let build = String(scrub(draft.build).prefix(300))
        let settings = String(scrub(draft.streamSettings).prefix(300))
        let logs = scrub(draft.logs)

        func url(_ logsText: String, _ whatText: String) -> String {
            var text = newIssue + "?template=" + encode(template) + "&title=" + encode(title)
                + "&what-happened=" + encode(linkLine + whatText + note)
            if let area = draft.area { text += "&area=" + encode(area) }
            return text + "&device=" + encode(device) + "&build=" + encode(build) + "&stream-settings=" + encode(settings)
                + "&logs=" + encode(logsText)
        }

        var shownLogs = logs
        var result = url(shownLogs, what)
        // The log is cut first, a tenth at a time from the original (the note must not feed back into the length), then the
        // description; a cut is in the raw text, never inside an escape
        var keep = logs.count
        while result.count > maxLength, keep > 0 {
            keep = keep * 9 / 10
            shownLogs = keep < 40 ? "" : logs.prefix(keep).trimmingTrailingWhitespace() + cutNote
            result = url(shownLogs, what)
        }
        var shownWhat = what
        while result.count > maxLength, !shownWhat.isEmpty {
            shownWhat = shownWhat.prefix(shownWhat.count * 9 / 10).trimmingTrailingWhitespace()
            result = url(shownLogs, shownWhat)
        }
        return result
    }

    /// Form encoding with `%20` for a space, as the GitHub form expects: only ASCII letters, digits and `.-*_` stay as they are.
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-*_")
}

/// Turns a ``Problem`` and the ``DeviceInfo`` into the prefilled report form (`ProblemIssue`): facts only, never a PC name or
/// address.
public enum ProblemIssue {
    public static func draft(_ problem: Problem, info: DeviceInfo, attachment: ReportAttachment) -> IssueDraft {
        let title: String
        switch problem.kind {
        case .crash: title = problem.viaExitRecord ? titled("Crash", problem.subject) : "Crash: \(problem.subject)"
        case .nativeCrash: title = titled("Native crash", problem.subject)
        case .hang: title = titled("Not responding", problem.subject)
        case .uncleanExit: title = "Delos stopped without closing normally"
        case .streamFailed: title = "Stream failed: \(problem.subject)"
        }
        let what = problem.kind.issueSentence + "\n\n(Created from the problem report in Delos. Please add what you were doing just before.)"
        return common(info, attachment, title: title, what: what, logs: logsText(problem),
                      area: problem.kind == .streamFailed ? IssueURL.areaConnection : IssueURL.areaOther)
    }

    /// The draft of a report the user started from Debug info, without a detected problem: the title and the log summary stay empty.
    public static func manualDraft(info: DeviceInfo, attachment: ReportAttachment) -> IssueDraft {
        common(info, attachment, title: "", what: "(Created from the problem report in Delos. Please describe what happened and what you were doing.)",
               logs: "", area: nil)
    }

    private static func common(_ info: DeviceInfo, _ attachment: ReportAttachment, title: String, what: String, logs: String, area: String?) -> IssueDraft {
        var link: String?
        if case .link(let address, _) = attachment { link = address }
        return IssueDraft(
            title: title, whatHappened: what, device: "\(info.deviceKind) \(info.model), \(info.system)",
            build: "Delos \(info.delosVersion) (\(info.buildType)), build \(info.buildNumber)",
            streamSettings: info.settings.map { "\($0.0) \($0.1)" }.joined(separator: ", "), logs: logs, area: area, logLink: link,
            attachmentNote: attachmentSentence(attachment))
    }

    private static func attachmentSentence(_ attachment: ReportAttachment) -> String {
        switch attachment {
        case let .file(name, folder):
            "The diagnostic log was saved by Delos as `\(name)` in \(folder). I attach it to this issue."
        case let .link(_, expires):
            "The cleaned diagnostic log was uploaded by Delos to its report service; the link above is readable by anyone who has it"
                + " and works until \(expires.prefix(10))."
        }
    }

    private static func titled(_ what: String, _ subject: String) -> String {
        subject.trimmingCharacters(in: .whitespaces).isEmpty ? what : "\(what): \(subject)"
    }

    /// The summary and the head of the stack trace (or the system's description): what fits an address; the file has the rest.
    public static func logsText(_ problem: Problem) -> String {
        let lines = problem.detail.components(separatedBy: "\n")
        let head = lines.prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("at ") }
        let frames = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("at ") }.prefix(12)
        let detail = (head + frames).joined(separator: "\n")
        var parts: [String] = []
        for part in [problem.summary, detail] where !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !parts.contains(part) {
            parts.append(part)
        }
        return parts.joined(separator: "\n\n")
    }

    /// The report's "Problem" section: the same facts with the full stack trace.
    public static func section(_ problem: Problem, detectedAt: String) -> String {
        var text = "Kind: \(problem.kind.rawValue)\nDetected: \(detectedAt)\nSummary: \(problem.summary)\n"
        if !problem.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text += "\n" + problem.detail }
        return text.trimmingTrailingWhitespace()
    }
}

extension StringProtocol {
    func trimmingTrailingWhitespace() -> String {
        var text = String(self)
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text
    }
}
