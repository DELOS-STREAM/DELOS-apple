import DelosCore
import Foundation

// The upload of a cleaned report to the Delos report service and the choice between upload and saving the file
// (docs/DIAGNOSTICS.md, "The report service"; ReportUploader.kt, ReportSubmission.kt and ProblemReporter.kt of DELOS for Android).

/// Why a report could not be uploaded. The app then saves the file instead.
public enum UploadFailure: Sendable, Equatable {
    /// No connection to the service (offline, DNS, refused, TLS).
    case offline
    /// The service did not answer in time.
    case timeout
    /// Too many uploads from this address (HTTP 429).
    case rateLimited
    /// The service stopped accepting reports for today (HTTP 503 `daily_limit`).
    case dailyLimit
    /// The report is larger than the service accepts (HTTP 413).
    case tooLarge
    /// The service failed (5xx other than the daily limit).
    case serviceError
    /// The service refused the request (any other status, a redirect).
    case rejected
    /// The service said 201 with an answer that is not a link of this service.
    case malformed
}

public enum ReportUpload: Sendable, Equatable {
    /// [link] is the address of the stored report, [expires] its expiry (ISO 8601), [rescrubbed] what the service's second
    /// scrub still changed.
    case uploaded(link: String, expires: String, rescrubbed: Int)
    case failed(UploadFailure)
}

/// Posts an already scrubbed report to the Delos report service (`tools/report-worker/` of DELOS for Android) and returns the
/// link of the stored copy. The address is the build setting `DELOS_REPORTS_URL` (Info.plist `DelosReportsURL`); without one
/// ``enabled`` is false and nothing here is used. The text goes gzip-compressed as `text/plain; charset=utf-8`; redirects
/// are not followed, the address must be HTTPS (a loopback address in a debug build, for tests), and the link in the answer is
/// used only when it is `<service>/r/<22 characters of an id>`. Neither the text nor the link is logged.
public final class ReportUploader: Sendable {
    /// What the service accepts (`MAX_BYTES` of the Worker).
    public static let maxBytes = 128 * 1024
    /// How long the service keeps a report (`TTL_SECONDS` of the Worker), for the texts that say so.
    public static let keptDays = 30
    static let note = "(older log lines were left out: the report service accepts 128 KiB)"

    private let endpoint: URL?
    private let session: URLSession

    public init(baseURL: String, configuration: URLSessionConfiguration = ReportUploader.configuration) {
        endpoint = MetadataProxy.url(baseURL: baseURL, path: "v1/reports")
        session = URLSession(configuration: configuration)
    }

    /// The uploader of this build: its address is `DelosReportsURL` of the app's Info.plist.
    public static let shared = ReportUploader(baseURL: Bundle.main.object(forInfoDictionaryKey: "DelosReportsURL") as? String ?? "")

    /// 20 s without an answer, 30 s in all; no cookies, no cache.
    public static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return configuration
    }

    public var enabled: Bool { endpoint != nil }

    public func upload(_ text: String) async -> ReportUpload {
        guard let endpoint else { return .failed(.rejected) }
        let raw = Data(text.utf8)
        guard raw.count <= Self.maxBytes else { return failed(.tooLarge) }
        guard let body = Gzip.compress(raw) else { return failed(.rejected) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        do {
            let (data, response) = try await session.upload(for: request, from: body, delegate: NoRedirects())
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return answer(endpoint, status: status, body: data.prefix(4096))
        } catch let error as URLError where error.code == .timedOut {
            return failed(.timeout)
        } catch {
            return failed(.offline)
        }
    }

    private func answer(_ endpoint: URL, status: Int, body: Data) -> ReportUpload {
        switch status {
        case 201:
            guard let upload = Self.parse(endpoint: endpoint, body: body) else { return failed(.malformed) }
            if case .uploaded(_, _, let rescrubbed) = upload {
                DiagLog.i("Report", "Log uploaded (the service's second scrub changed \(rescrubbed))")
            }
            return upload
        case 429: return failed(.rateLimited)
        case 413: return failed(.tooLarge)
        case 503 where Self.errorCode(body) == "daily_limit": return failed(.dailyLimit)
        case 500...: return failed(.serviceError)
        default: return failed(.rejected)
        }
    }

    private func failed(_ reason: UploadFailure) -> ReportUpload {
        DiagLog.w("Report", "Log upload failed: \(reason)")
        return .failed(reason)
    }

    private static func errorCode(_ body: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? String
    }

    /// The upload a 201 answer stands for, or nil when the body is not `{id, url, expires[, rescrubbed]}` with a link of
    /// [endpoint]'s service.
    static func parse(endpoint: URL, body: Data) -> ReportUpload? {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let id = json["id"] as? String,
              let link = json["url"] as? String, let expires = json["expires"] as? String,
              id.count == 22, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              var expected = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        expected.path = "/r/\(id)"
        expected.query = nil
        expected.fragment = nil
        guard let address = expected.string, link == address else { return nil }
        return .uploaded(link: address, expires: expires, rescrubbed: json["rescrubbed"] as? Int ?? 0)
    }

    /// [text] cut to what the service accepts: the header, the device block and the sections stay whole, the oldest log lines go
    /// first and a note says so. Text that fits is returned as it is.
    public static func fit(_ text: String, maxBytes: Int = maxBytes) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let lines = text.components(separatedBy: "\n")
        let start = lines.firstIndex { $0.hasPrefix(DiagnosticReport.logHeading) }.map { $0 + 1 } ?? 0
        let head = Array(lines[..<start]) + [note]
        var size = head.reduce(0) { $0 + $1.utf8.count + 1 }
        var kept: [String] = []
        for line in lines[start...].reversed() {
            let bytes = line.utf8.count + 1
            if size + bytes > maxBytes { break }
            size += bytes
            kept.append(line)
        }
        return (head + kept.reversed()).joined(separator: "\n")
    }
}

/// Refuses every redirect: the answer of the redirect itself is then the answer (a status the uploader rejects).
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// A gzip stream (RFC 1952) around Foundation's raw DEFLATE.
enum Gzip {
    static func compress(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data([0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF])
        out.append(deflated)
        appendLittleEndian(crc32(data), to: &out)
        appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &out)
        return out
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

/// What the user chose to do with the log of a report.
public enum ReportMode: Sendable {
    /// Upload the cleaned log and put its link into the draft; save the file when that fails.
    case upload
    /// Save the cleaned log for the user to attach; nothing is uploaded.
    case save
}

/// What a report did, for the toast and the browser: [issueURL] is the prefilled GitHub draft in every case.
public enum ReportResult: Sendable, Equatable {
    case uploaded(issueURL: String, link: String, expires: String)
    /// The log was saved as [fileName]; [uploadFailure] says why the upload did not happen (nil: saving was chosen).
    case saved(issueURL: String, fileName: String, uploadFailure: UploadFailure?)
    /// Neither the upload nor the save worked: the draft opens without a log.
    case notSaved(issueURL: String, uploadFailure: UploadFailure?)

    public var issueURL: String {
        switch self {
        case .uploaded(let url, _, _), .saved(let url, _, _), .notSaved(let url, _): url
        }
    }

    /// The log is on the service or in a file.
    public var succeeded: Bool {
        if case .notSaved = self { false } else { true }
    }
}

/// A scrubbed report ready to go: the text, the name its file gets, the English words for the folder it is saved in, and the
/// prefilled address for the log at an attachment.
public struct PreparedReport: Sendable {
    public let report: DiagnosticReport
    public let fileName: String
    public let folder: String
    public let issueURL: @Sendable (ReportAttachment) -> String

    public init(report: DiagnosticReport, fileName: String, folder: String, issueURL: @escaping @Sendable (ReportAttachment) -> String) {
        self.report = report
        self.fileName = fileName
        self.folder = folder
        self.issueURL = issueURL
    }
}

/// The decision of a report (`ReportSubmission`): which of upload and save happens, in which order, and what the draft says.
public enum ReportSubmission {
    public static func run(
        _ prepared: PreparedReport, mode: ReportMode, uploader: ReportUploader, save: @Sendable (DiagnosticReport, String) async -> Bool
    ) async -> ReportResult {
        var failure: UploadFailure?
        if mode == .upload, uploader.enabled {
            switch await uploader.upload(ReportUploader.fit(prepared.report.text)) {
            case let .uploaded(link, expires, _):
                return .uploaded(issueURL: prepared.issueURL(.link(link, expires: expires)), link: link, expires: expires)
            case .failed(let reason):
                failure = reason
            }
        }
        let url = prepared.issueURL(.file(name: prepared.fileName, folder: prepared.folder))
        return await save(prepared.report, prepared.fileName)
            ? .saved(issueURL: url, fileName: prepared.fileName, uploadFailure: failure)
            : .notSaved(issueURL: url, uploadFailure: failure)
    }
}
