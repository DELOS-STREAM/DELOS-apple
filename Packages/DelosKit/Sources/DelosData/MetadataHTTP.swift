import Foundation

public enum MetadataError: Error, Equatable, Sendable {
    case unavailable, invalidRequest, malformedResponse, httpStatus(Int)
}
public struct MetadataHTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public let headers: [String: String]
    public init(data: Data, status: Int, headers: [String: String] = [:]) {
        self.data = data; self.status = status; self.headers = headers
    }
}
public protocol MetadataTransport: Sendable {
    func response(for request: URLRequest) async throws -> MetadataHTTPResponse
}
public struct URLSessionMetadataTransport: MetadataTransport {
    public init() {}
    public func response(for request: URLRequest) async throws -> MetadataHTTPResponse {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw MetadataError.malformedResponse }
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return MetadataHTTPResponse(data: data, status: response.statusCode, headers: headers)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            // Never expose configured endpoints, query strings or response bodies through errors.
            throw MetadataError.unavailable
        }
    }
}
public struct MetadataHTTP: Sendable {
    private let transport: any MetadataTransport
    public init(transport: any MetadataTransport = URLSessionMetadataTransport()) { self.transport = transport }
    public func send(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        var request = request
        request.timeoutInterval = 30
        let response = try await transport.response(for: request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.status) else { throw MetadataError.httpStatus(response.status) }
        return response.data
    }
}

/// Reservations happen before suspension, so actor reentrancy cannot release several queued requests together.
public actor RequestPacer {
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void
    private let interval: Duration
    private var next: ContinuousClock.Instant?
    public init(intervalMilliseconds: Int64) {
        let clock = ContinuousClock()
        interval = .milliseconds(max(0, intervalMilliseconds))
        now = { clock.now }
        sleep = { try await clock.sleep(until: $0) }
    }
    init(intervalMilliseconds: Int64, now: @escaping @Sendable () -> ContinuousClock.Instant,
         sleep: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void) {
        interval = .milliseconds(max(0, intervalMilliseconds)); self.now = now; self.sleep = sleep
    }
    public func wait() async throws {
        try Task.checkCancellation()
        let now = now()
        let slot = next.map { max(now, $0) } ?? now
        next = slot.advanced(by: interval)
        if slot > now { try await sleep(slot) }
        try Task.checkCancellation()
    }
}

public enum MetadataProxy {
    public static let maxSteamAppID: Int64 = 4_294_967_295
    public static func url(baseURL: String, path: String, parameters: [URLQueryItem] = []) -> URL? {
        guard var parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty else { return nil }
        #if DEBUG
        let local = ["localhost", "127.0.0.1"].contains(host.lowercased())
        #else
        let local = false
        #endif
        guard parts.scheme?.lowercased() == "https" || (local && parts.scheme?.lowercased() == "http") else { return nil }
        let basePath = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = "/" + ([basePath, path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))].filter { !$0.isEmpty }).joined(separator: "/")
        parts.queryItems = parameters.isEmpty ? nil : parameters
        parts.fragment = nil
        return parts.url
    }
    private static let controls = try! NSRegularExpression(pattern: "[\\p{Cc}\\u2028\\u2029]")
    private static let whitespace = try! NSRegularExpression(pattern: "\\s+")
    private static func clean(_ value: String) -> String {
        let range = NSRange(value.startIndex..., in: value)
        let result = controls.stringByReplacingMatches(in: value, range: range, withTemplate: " ")
        return whitespace.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func term(_ value: String) -> String {
        String(String.UnicodeScalarView(clean(value).unicodeScalars.prefix(128))).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func title(_ value: String) -> String? {
        let value = clean(value)
        guard !value.isEmpty, value.unicodeScalars.count <= 200,
              value.rangeOfCharacter(from: CharacterSet(charactersIn: "#<>[]{|}")) == nil else { return nil }
        return value
    }
}

/// An empty or invalid configuration disables every metadata provider, including direct HLTB requests.
public struct MetadataConfiguration: Sendable {
    public let baseURL: String
    public var enabled: Bool { MetadataProxy.url(baseURL: baseURL, path: "v1/igdb/games") != nil }
    public init(baseURL: String = "") { self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    public static func bundled(_ bundle: Bundle = .main) -> MetadataConfiguration {
        MetadataConfiguration(baseURL: bundle.object(forInfoDictionaryKey: "DelosMetadataURL") as? String ?? "")
    }
}
