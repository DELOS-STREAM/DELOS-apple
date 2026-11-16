import Foundation
import Network
import Security
import Synchronization
@testable import DelosHost

/// A GameStream host on the loopback interface for the tests: an HTTP and an HTTPS listener (Network.framework) that
/// answer with whatever `handler` returns. The HTTPS side presents `identity` and requires a client certificate.
final class FakeHost: Sendable {
    struct Request: Sendable {
        let path: String
        let rawQuery: String
        let secure: Bool
        /// The client certificate of the TLS connection (DER), for HTTPS requests.
        let clientCertificate: Data?

        var query: [String: String] {
            var out = [String: String]()
            for part in rawQuery.split(separator: "&") {
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                out[pair[0]] = pair.count > 1 ? pair[1].removingPercentEncoding : ""
            }
            return out
        }
    }

    struct Response: Sendable {
        var status = 200
        var body: Data
        /// Never answer (for time-out tests).
        var silent = false

        static func xml(_ text: String) -> Response { Response(body: Data(text.utf8)) }
    }

    typealias Handler = @Sendable (Request) -> Response

    private final class State: Sendable {
        let requests = Mutex<[Request]>([])
        let clientCertificate = Mutex<Data?>(nil)
    }

    let identity: ClientIdentity
    let httpPort: Int
    let httpsPort: Int
    private let listeners: [NWListener]
    private let state = State()

    var requests: [Request] { state.requests.withLock { $0 } }
    var httpAddress: HostAddress { HostAddress(host: "127.0.0.1", port: httpPort) }
    func pin(_ certificate: Data? = nil) -> HostPin {
        HostPin(certificate: certificate ?? identity.certificate, httpsPort: httpsPort)
    }

    init(identity: ClientIdentity, handler: @escaping Handler) async throws {
        self.identity = identity
        let queue = DispatchQueue(label: "fake-host")
        let state = self.state

        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(security, sec_identity_create(identity.secIdentity)!)
        sec_protocol_options_set_peer_authentication_required(security, true)
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let leaf = HTTPTransport.leafCertificate(sec_trust_copy_ref(trust).takeRetainedValue())
            state.clientCertificate.withLock { $0 = leaf }
            complete(true)
        }, queue)

        let http = try NWListener(using: .tcp, on: .any)
        let https = try NWListener(using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()), on: .any)
        listeners = [http, https]
        let respond: @Sendable (Request) -> Response = { request in
            state.requests.withLock { $0.append(request) }
            return handler(request)
        }
        httpPort = try await Self.start(http, queue: queue) { connection in
            Self.serve(connection, secure: false, certificate: { nil }, queue: queue, respond: respond)
        }
        httpsPort = try await Self.start(https, queue: queue) { connection in
            Self.serve(
                connection, secure: true, certificate: { state.clientCertificate.withLock { $0 } }, queue: queue,
                respond: respond)
        }
    }

    deinit {
        listeners.forEach { $0.cancel() }
    }

    private static func start(
        _ listener: NWListener, queue: DispatchQueue, accept: @escaping @Sendable (NWConnection) -> Void
    ) async throws -> Int {
        listener.newConnectionHandler = accept
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let once = Once(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(with: .success(Int(listener.port!.rawValue)))
                case .failed(let error): once.resume(with: .failure(error))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private static func serve(
        _ connection: NWConnection, secure: Bool, certificate: @escaping @Sendable () -> Data?,
        queue: DispatchQueue, respond: @escaping Handler
    ) {
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data()) { head in
            let line = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")[0]
            let target = line.split(separator: " ")[1]
            let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
            let request = Request(
                path: parts[0], rawQuery: parts.count > 1 ? parts[1] : "", secure: secure,
                clientCertificate: secure ? certificate() : nil)
            let response = respond(request)
            guard !response.silent else { return }
            var bytes = Data("HTTP/1.1 \(response.status) X\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n".utf8)
            bytes.append(response.body)
            connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func receiveHead(_ connection: NWConnection, buffer: Data, done: @escaping @Sendable (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                done(buffer[..<end.lowerBound])
            } else if error == nil && !complete {
                receiveHead(connection, buffer: buffer, done: done)
            }
        }
    }
}

/// Identities made once per test run (RSA key generation takes a moment).
enum TestIdentities {
    static let client = try! ClientIdentity.generate()
    static let host = try! ClientIdentity.generate()
    static let impostor = try! ClientIdentity.generate()
}

/// `serverinfo` documents in the field layout of each host family, from `ServerInfoParsingTest.java` of DELOS for
/// Android (written by hand there, not captures of a real machine).
enum Documents {
    static let sunshine = """
        <?xml version="1.0" encoding="utf-8"?>
        <root status_code="200"><hostname>LIVINGROOM</hostname><appversion>7.1.431.-1</appversion>\
        <GfeVersion>3.23.0.74</GfeVersion><uniqueid>2A6F3E0B-11C4-4E7B-9E2D-5B6A7C8D9E0F</uniqueid>\
        <HttpsPort>48984</HttpsPort><ExternalPort>48989</ExternalPort><MaxLumaPixelsHEVC>1869449984</MaxLumaPixelsHEVC>\
        <mac>a0:b1:c2:d3:e4:f5</mac><LocalIP>192.168.1.20</LocalIP><ServerCodecModeSupport>3843</ServerCodecModeSupport>\
        <PairStatus>1</PairStatus><currentgame>0</currentgame><state>SUNSHINE_SERVER_FREE</state></root>
        """

    static let apolloBusy = """
        <?xml version="1.0" encoding="utf-8"?>
        <root status_code="200"><hostname>DESK</hostname><appversion>7.1.431.-1</appversion>\
        <GfeVersion>3.23.0.74</GfeVersion><uniqueid>7C1D0A55-0000-4000-8000-00000000BEEF</uniqueid>\
        <HttpsPort>47984</HttpsPort><ExternalPort>47989</ExternalPort><mac>00:00:00:00:00:00</mac>\
        <LocalIP>10.0.0.7</LocalIP><ExternalIP>203.0.113.9</ExternalIP><Permission>117506049</Permission>\
        <VirtualDisplayCapable>true</VirtualDisplayCapable><VirtualDisplayDriverReady>true</VirtualDisplayDriverReady>\
        <ServerCommand>Sleep</ServerCommand><ServerCommand>Restart Steam</ServerCommand><PairStatus>1</PairStatus>\
        <currentgame>881448767</currentgame><currentgameuuid>8CB5C136-DA67-4F99-B4A1-F9CD35005CF4</currentgameuuid>\
        <state>SUNSHINE_SERVER_BUSY</state></root>
        """

    /// GeForce Experience declares UTF-16 and sends it.
    static let gfe = """
        <?xml version="1.0" encoding="UTF-16"?>
        <root protocol_version="0.1" query="serverinfo" status_code="200" status_message="OK"><hostname>OLDPC</hostname>\
        <appversion>7.1.415.0</appversion><GfeVersion>3.20.4.14</GfeVersion><uniqueid>0000111122223333</uniqueid>\
        <HttpsPort>47984</HttpsPort><mac>11:22:33:44:55:66</mac><LocalIP>192.168.0.2</LocalIP>\
        <ExternalIP>198.51.100.4</ExternalIP><PairStatus>0</PairStatus><currentgame>12345</currentgame>\
        <state>MJOLNIR_STATE_SERVER_AVAILABLE</state></root>
        """

    /// A Sunshine answer with the given id, pair status and HTTPS port.
    static func serverInfo(id: String = "2A6F3E0B-11C4-4E7B-9E2D-5B6A7C8D9E0F", paired: Bool = false, httpsPort: Int = 47984,
                           name: String = "LIVINGROOM", appVersion: String = "7.1.431.-1") -> String {
        sunshine
            .replacingOccurrences(of: "2A6F3E0B-11C4-4E7B-9E2D-5B6A7C8D9E0F", with: id)
            .replacingOccurrences(of: "<PairStatus>1", with: "<PairStatus>\(paired ? 1 : 0)")
            .replacingOccurrences(of: "<HttpsPort>48984", with: "<HttpsPort>\(httpsPort)")
            .replacingOccurrences(of: "LIVINGROOM", with: name)
            .replacingOccurrences(of: "7.1.431.-1", with: appVersion)
    }
}
