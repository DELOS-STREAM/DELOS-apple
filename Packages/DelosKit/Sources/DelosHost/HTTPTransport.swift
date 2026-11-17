import Foundation
import Network
import Security
import Synchronization

/// What HTTPS trusts: exactly one certificate, the one pinned at pairing (rule S-07 of DELOS for Android). The system
/// trust store, the host name and the validity dates play no part. The client identity is presented when the host
/// asks for a client certificate.
struct TLSPolicy: Sendable {
    let pinnedCertificate: Data
    let identity: ClientIdentity
}

struct HTTPRequest: Sendable {
    var address: HostAddress
    var path: String
    /// Already percent-encoded (`HTTPRequest.encode`).
    var query: String
    /// Nil: plain HTTP.
    var tls: TLSPolicy?
    /// Nil: no limit (the host waits for the user, as in the first pairing step, or for a game to start).
    var timeout: Duration?
    var maximumBodySize: Int

    var target: String { query.isEmpty ? path : path + "?" + query }

    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    var head: Data {
        Data("GET \(target) HTTP/1.1\r\nHost: \(address.description)\r\nUser-Agent: DELOS\r\nAccept: */*\r\nConnection: close\r\n\r\n".utf8)
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

struct HTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

/// One GET request per connection over Network.framework (`Connection: close`). Network.framework instead of
/// URLSession: the exclusive pin is a TLS verify block that replaces the system evaluation completely, the client
/// certificate is a TLS option, and plain HTTP to a PC by address or name needs no App Transport Security exception.
enum HTTPTransport {
    static func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        let outcome = Outcome()
        // Keep-alive probes end a connection to a PC that vanished while a request without a time limit waits.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let parameters: NWParameters
        if let tls = request.tls {
            parameters = NWParameters(tls: tlsOptions(tls, outcome: outcome), tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(request.address.port)) else {
            throw HostError.unreachable("invalid port")
        }
        let connection = NWConnection(host: NWEndpoint.Host(request.address.host), port: port, using: parameters)
        let timer = request.timeout.map { timeout in
            Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                outcome.timedOut.store(true, ordering: .relaxed)
                connection.cancel()
            }
        }
        defer {
            timer?.cancel()
            connection.cancel()
        }
        do {
            return try await withTaskCancellationHandler {
                try await exchange(connection, request)
            } onCancel: {
                connection.cancel()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if outcome.timedOut.load(ordering: .relaxed) { throw HostError.timedOut }
            if outcome.pinMismatch.load(ordering: .relaxed) { throw HostError.certificateMismatch }
            if let error = error as? HostError { throw error }
            throw HostError.unreachable(String(describing: error))
        }
    }

    private final class Outcome: Sendable {
        let timedOut = Atomic<Bool>(false)
        let pinMismatch = Atomic<Bool>(false)
    }

    private static let queue = DispatchQueue(label: "io.github.meitoncz.delos.host.http", attributes: .concurrent)

    private static func tlsOptions(_ policy: TLSPolicy, outcome: Outcome) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        if let identity = sec_identity_create(policy.identity.secIdentity) {
            sec_protocol_options_set_local_identity(security, identity)
        }
        let pinned = policy.pinnedCertificate
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let matches = leafCertificate(sec_trust_copy_ref(trust).takeRetainedValue()) == pinned
            if !matches { outcome.pinMismatch.store(true, ordering: .relaxed) }
            complete(matches)
        }, queue)
        return options
    }

    static func leafCertificate(_ trust: SecTrust) -> Data? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        return SecCertificateCopyData(leaf) as Data
    }

    private static func exchange(_ connection: NWConnection, _ request: HTTPRequest) async throws -> HTTPResponse {
        try await ready(connection)
        try await send(request.head, on: connection)
        var parser = HTTPResponseParser(maximumBodySize: request.maximumBodySize)
        while true {
            let (data, complete) = try await receive(connection)
            if let data { try parser.append(data) }
            if let response = try parser.response(atEnd: complete) { return response }
            if complete { throw HostError.malformedResponse("the connection closed before the answer was complete") }
        }
    }

    private static func ready(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(with: .success(()))
                // Waiting means no path or a refused connection: report it now instead of retrying silently.
                case .waiting(let error), .failed(let error): once.resume(with: .failure(error))
                case .cancelled: once.resume(with: .failure(CancellationError()))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private static func receive(_ connection: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, complete))
                }
            }
        }
    }
}

/// Resumes a continuation at most once (connection state handlers fire repeatedly).
final class Once<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, Error>?>

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with result: Result<Value, Error>) {
        continuation.withLock { stored in
            stored?.resume(with: result)
            stored = nil
        }
    }
}

/// Reads an HTTP/1.1 response: status line, headers, then a body by `Content-Length`, chunked transfer coding or
/// up to the end of the connection.
struct HTTPResponseParser {
    let maximumBodySize: Int
    private var buffer = Data()
    private var head: (status: Int, headers: [String: String], bodyStart: Int)?
    /// Chunked bodies are decoded once, as the bytes arrive: the part decoded so far and where the next chunk's size
    /// line starts in `buffer`. Each call then costs the new bytes, not the whole body again.
    private var decoded = [UInt8]()
    private var nextChunk: Int?

    init(maximumBodySize: Int) {
        self.maximumBodySize = maximumBodySize
    }

    mutating func append(_ data: Data) throws {
        buffer.append(data)
        if buffer.count > maximumBodySize + 64 * 1024 { throw HostError.responseTooLarge }
    }

    /// The response once it is complete; nil while more bytes are needed.
    mutating func response(atEnd: Bool) throws -> HTTPResponse? {
        if head == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 64 * 1024 { throw HostError.responseTooLarge }
                return nil
            }
            head = try Self.parseHead(buffer[buffer.startIndex..<end.lowerBound], bodyStart: end.upperBound)
        }
        guard let head else { return nil }
        if head.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard try dechunk() else { return nil }
            return try finish(head, Data(decoded))
        }
        let body = buffer[head.bodyStart...]
        if let lengthText = head.headers["content-length"] {
            guard let length = Int(lengthText), length >= 0 else {
                throw HostError.malformedResponse("invalid Content-Length")
            }
            if length > maximumBodySize { throw HostError.responseTooLarge }
            guard body.count >= length else { return nil }
            return try finish(head, Data(body.prefix(length)))
        }
        return atEnd ? try finish(head, Data(body)) : nil
    }

    private func finish(_ head: (status: Int, headers: [String: String], bodyStart: Int), _ body: Data) throws -> HTTPResponse {
        if body.count > maximumBodySize { throw HostError.responseTooLarge }
        return HTTPResponse(status: head.status, headers: head.headers, body: body)
    }

    private static func parseHead(_ bytes: Data, bodyStart: Int) throws -> (status: Int, headers: [String: String], bodyStart: Int) {
        let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
        let statusParts = lines[0].split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/1."), let status = Int(statusParts[1]) else {
            throw HostError.malformedResponse("not an HTTP response")
        }
        var headers = [String: String]()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (status, headers, bodyStart)
    }

    /// The longest chunk size line (digits and extensions) accepted.
    private static let maximumChunkLine = 1024

    /// Decodes the chunks that are complete in `buffer` into `decoded`; true once the last chunk has arrived. A chunk
    /// that would take the body past the limit is refused as soon as its size line arrives, before any arithmetic with
    /// the size: the size comes from the network.
    private mutating func dechunk() throws -> Bool {
        guard let head else { return false }
        var index = nextChunk ?? head.bodyStart
        defer { nextChunk = index }
        while true {
            guard let lineEnd = find(from: index) else {
                if buffer.count - index > Self.maximumChunkLine { throw HostError.malformedResponse("a chunk size line is too long") }
                return false
            }
            let size = try Self.chunkSize(buffer[index..<lineEnd], remaining: maximumBodySize - decoded.count)
            let start = lineEnd + 2
            if size == 0 { index = start; return true }
            // `size` is at most the limit, and the comparison subtracts instead of adding to it.
            let available = buffer.count - start
            guard available >= 2, available - 2 >= size else { return false }
            guard buffer[start + size] == 13, buffer[start + size + 1] == 10 else {
                throw HostError.malformedResponse("a chunk does not end with CRLF")
            }
            decoded.append(contentsOf: buffer[start..<start + size])
            index = start + size + 2
        }
    }

    /// The size on a chunk's line: hexadecimal digits, optionally followed by `;` and extensions. Throws
    /// `responseTooLarge` once the digits pass `remaining`, so no size can overflow.
    private static func chunkSize(_ line: Data, remaining: Int) throws -> Int {
        let isBlank = { (byte: UInt8) in byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") }
        var digits = line.prefix { $0 != UInt8(ascii: ";") }
        while let first = digits.first, isBlank(first) { digits.removeFirst() }
        while let last = digits.last, isBlank(last) { digits.removeLast() }
        guard !digits.isEmpty else { throw HostError.malformedResponse("invalid chunk size") }
        var size = 0
        for byte in digits {
            guard let digit = hexValue(byte) else { throw HostError.malformedResponse("invalid chunk size") }
            let (shifted, overflowed) = size.multipliedReportingOverflow(by: 16)
            let (next, carried) = shifted.addingReportingOverflow(digit)
            guard !overflowed, !carried, next <= remaining else { throw HostError.responseTooLarge }
            size = next
        }
        return size
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): Int(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): Int(byte - UInt8(ascii: "A")) + 10
        default: nil
        }
    }

    private func find(from start: Int) -> Int? {
        var index = start
        while index + 1 < buffer.count {
            if buffer[index] == 13 && buffer[index + 1] == 10 { return index }
            index += 1
        }
        return nil
    }
}
