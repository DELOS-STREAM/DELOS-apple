import Darwin
import Foundation
import os
import Synchronization

/// Why a link test could not produce a number, as a reason the screens can say in a sentence (LinkProbeClient.kt).
public enum LinkFailure: Equatable, Sendable {
    case hostUnsupported, streamActive, denied, udpBlocked, network, timeout, hostError, invalidResponse
    /// The PC speaks a newer probe protocol than this DELOS knows.
    case needsNewerClient
}

/// A failed link test: the reason the screens word, and a technical message for the log.
public struct LinkTestError: Error, Equatable, Sendable {
    public let failure: LinkFailure
    public let message: String

    public init(_ failure: LinkFailure, _ message: String) {
        self.failure = failure
        self.message = message
    }
}

/// A rate or packet size outside what the host accepts, refused before anything is sent (Android's `require`).
public struct LinkProbeOutOfRange: Error, Equatable, Sendable {
    public let kbps: Int
    public let packetSize: Int
}

/// The query of one probe request: `kbps=&port=&packetsize=&token=[&handshake=1]`.
public struct LinkProbeQuery: Equatable, Sendable {
    public var kbps: Int
    public var port: Int
    public var packetSize: Int
    public var token: String
    public var handshake: Bool

    public var encoded: String {
        "kbps=\(kbps)&port=\(port)&packetsize=\(packetSize)&token=\(token)" + (handshake ? "&handshake=1" : "")
    }
}

/// The PC's side of a probe over HTTPS (NvHTTP.newPyroWaveUdpProbeCall). The real one is a paired PC (``HostLinkProbe``);
/// tests answer with a fake host that sends the UDP packets itself.
public protocol LinkProbeHost: Sendable {
    /// The PC's name or address; it is resolved once, and the UDP receiver and the request both use that address.
    var hostName: String { get }

    /// `GET /pyrowave-udp-probe?[query]` to [address] (a numeric address of ``hostName``), with [timeout] for the whole
    /// request. [onHead] hears the status and the headers (lower-case names) before the body. Returns the status and the
    /// body whatever the status; throws `HostError` (`timedOut` when the time is up) or `CancellationError`.
    func udpProbe(
        address: String, query: LinkProbeQuery, timeout: Duration, onHead: @escaping @Sendable (Int, [String: String]) -> Void
    ) async throws -> (status: Int, body: Data)
}

/// A paired PC as the probe's host: the pinned HTTPS request of ``HostClient``.
public struct HostLinkProbe: LinkProbeHost {
    public let client: HostClient
    public let pin: HostPin

    public init(client: HostClient, pin: HostPin) {
        self.client = client
        self.pin = pin
    }

    public var hostName: String { client.address.host }

    public func udpProbe(
        address: String, query: LinkProbeQuery, timeout: Duration, onHead: @escaping @Sendable (Int, [String: String]) -> Void
    ) async throws -> (status: Int, body: Data) {
        let pinned = HostClient(
            address: HostAddress(host: address, port: client.address.port), identity: client.identity, deviceName: client.deviceName)
        let response = try await pinned.send(
            "pyrowave-udp-probe", query: query.encoded, pin: pin, timeout: timeout, limit: HostClient.xmlLimit, onHead: onHead)
        return (response.status, response.body)
    }
}

/// One UDP probe as the host document describes it (docs/pyrowave-protocol.md): a UDP receiver on an ephemeral port,
/// the pinned HTTPS request `GET /pyrowave-udp-probe?kbps=&port=&packetsize=&token=[&handshake=1]`, and a score made of
/// the arrival of every sequence number against the host's reliable answer (expected, sent, elapsedMs). Cancelling the
/// task stops the request and the receiver.
public struct LinkProbeClient: Sendable {
    public let host: any LinkProbeHost
    public let info: PyroWaveHostInfo
    public let packetSize: Int

    private static let logger = Logger(subsystem: "io.github.meitoncz.delos", category: "LinkTest")

    public init(host: any LinkProbeHost, info: PyroWaveHostInfo, packetSize: Int = LinkPolicy.defaultPacketSize) {
        self.host = host
        self.info = info
        self.packetSize = packetSize
    }

    public func probe(kbps: Int) async throws -> ProbeScore {
        guard (LinkPolicy.minKbps...LinkPolicy.maxKbps).contains(kbps),
              (LinkPolicy.minPacketSize...LinkPolicy.maxPacketSize).contains(packetSize) else {
            throw LinkProbeOutOfRange(kbps: kbps, packetSize: packetSize)
        }
        let expected = expectedProbePackets(kbps: kbps, packetSize: packetSize)
        let handshake = info.udpHandshakeVersion == 1
        let address = try LinkAddress.resolve(host.hostName)
        var generator = SystemRandomNumberGenerator()
        let token = (0..<LinkPolicy.tokenLength / 2).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
        let receiver = try LinkReceiver(
            address: address, token: Array(token.utf8), packetSize: packetSize, expected: expected, handshake: handshake)
        receiver.start()
        do {
            let score = try await measure(kbps: kbps, expected: expected, token: token, handshake: handshake, address: address, receiver: receiver)
            receiver.close()
            return score
        } catch {
            await receiver.finish()
            receiver.close()
            throw error
        }
    }

    private func measure(
        kbps: Int, expected: Int, token: String, handshake: Bool, address: LinkAddress, receiver: LinkReceiver
    ) async throws -> ProbeScore {
        let query = LinkProbeQuery(kbps: kbps, port: receiver.localPort, packetSize: packetSize, token: token, handshake: handshake)
        let answer: (status: Int, body: Data)
        do {
            answer = try await host.udpProbe(
                address: address.numeric, query: query, timeout: .milliseconds(LinkPolicy.requestTimeoutMs)
            ) { status, headers in
                // The host flushes its headers, then waits for the token before it sends; the body stays pending
                guard handshake, (200..<300).contains(status) else { return }
                if let port = headers["x-pyrowave-udp-port"].flatMap(Self.validPort) { receiver.senderPort.store(port, ordering: .releasing) }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch HostError.timedOut {
            throw receiver.authenticated.load(ordering: .acquiring) == 0
                ? LinkTestError(.udpBlocked, "No UDP packets arrived before the test timed out")
                : LinkTestError(.timeout, "The test did not complete in time")
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw LinkTestError(.network, String(describing: error))
        }
        guard (200..<300).contains(answer.status) else {
            throw Self.failure(code: answer.status, text: String(decoding: answer.body, as: UTF8.self))
        }
        if handshake && receiver.senderPort.load(ordering: .acquiring) == 0 {
            throw LinkTestError(.hostError, "The host did not announce a valid UDP port")
        }
        try Task.checkCancellation()
        let response = try LinkProbeResponse.parse(answer.body)
        if response.expected != Int64(expected) || response.sent > response.expected {
            throw LinkTestError(.invalidResponse, "Host planned \(response.expected) packets, expected \(expected)")
        }
        // A bounded tail of reordered packets still counts; its delay is scored against the send schedule
        try await Task.sleep(for: .milliseconds(LinkPolicy.drainMs))
        await receiver.finish()
        if let error = receiver.error { throw LinkTestError(.network, "The UDP receiver failed: \(error)") }
        let score = scoreProbe(
            requestedKbps: kbps, expected: expected, sent: Int(response.sent), senderMs: response.elapsedMs,
            arrivalsUs: receiver.arrivals, receiveBufferBytes: receiver.grantedBuffer,
            maxStallMs: Double(receiver.maxStallUs.load(ordering: .acquiring)) / 1000)
        #if DEBUG
        Self.logger.debug("""
            \(kbps) kbps expected=\(expected) sent=\(score.sent) received=\(score.received) rcvbuf=\(receiver.grantedBuffer) \
            loss=\(score.lossPercent)% window=\(score.worstWindowLossPercent)% p99=\(score.delayP99Ms)ms \
            growth=\(score.delayGrowthMs)ms hostElapsed=\(score.senderMs)ms stall=\(score.maxStallMs)ms: \
            \(score.passed ? "PASS" : "FAIL \(String(describing: score.failure))")
            """)
        #endif
        return score
    }

    /// An HTTP failure as a reason the screens can word.
    static func failure(code: Int, text: String) -> LinkTestError {
        let message = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        switch code {
        case 403: return LinkTestError(.denied, message.isEmpty ? "Forbidden" : message)
        case 404: return LinkTestError(.hostUnsupported, "The host has no /pyrowave-udp-probe")
        // Vibepollo answers 400 "Stop streaming before testing bandwidth" while a stream session exists or another probe runs
        case 400 where message.range(of: "streaming", options: .caseInsensitive) != nil: return LinkTestError(.streamActive, message)
        default: return LinkTestError(.hostError, "HTTP \(code): \(message)")
        }
    }

    /// The announced UDP port: plain ASCII digits, 1024...65535.
    static func validPort(_ header: String) -> Int? {
        let text = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 5, text.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }), let port = Int(text) else {
            return nil
        }
        return (1024...65535).contains(port) ? port : nil
    }
}

/// The result of a whole test run.
public enum LinkTestOutcome: Equatable, Sendable {
    /// [jitter]: it passed, with p99 transit variation above 4 ms ("a little jitter").
    case done(LinkTest, jitter: Bool)
    case noRate(last: ProbeScore?, bestPassKbps: Int)
    case cancelled
}

/// The whole calibration against one host: the document's search over real probes. Starts at [startKbps] (the selected
/// bitrate), bounded by the PC's routed wired link speed (`PyroWaveHostLinkMbps`, when it knows one) and 3 Gbps. Throws
/// ``LinkTestError`` on a network or host failure. The result is only returned, never applied.
public func runLinkTest(
    host: any LinkProbeHost,
    info: PyroWaveHostInfo,
    startKbps: Int,
    transport: LinkTransport,
    isolation: isolated (any Actor)? = #isolation,
    nowMs: () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000).rounded()) },
    onStep: (LinkStep) -> Void = { _ in }
) async throws -> LinkTestOutcome {
    guard info.supportsLinkTest else { throw LinkTestError(.hostUnsupported, "The host does not advertise the UDP probe") }
    let client = LinkProbeClient(host: host, info: info)
    let cap = info.hostLinkMbps > 0 ? min(LinkPolicy.maxKbps, info.hostLinkMbps * 1000) : LinkPolicy.maxKbps
    let result: LinkSearchResult
    do {
        result = try await searchLink(startKbps: startKbps, capKbps: cap, probe: { try await client.probe(kbps: $0) }, onStep: onStep)
    } catch is CancellationError {
        return .cancelled
    }
    switch result {
    case .confirmed(let wire, let score):
        return .done(
            LinkTest(wireKbps: wire, testedAtMs: nowMs(), transport: transport, criticalFECPercent: info.criticalFECPercent,
                     packetSize: LinkPolicy.defaultPacketSize),
            jitter: score.jitterWarning)
    case .noRate(let last, let best): return .noRate(last: last, bestPassKbps: best)
    case .cancelled: return .cancelled
    }
}

// MARK: The UDP side

/// The PC's address as one socket address: the first IPv4 address of its name (an IPv6-only PC gets its IPv6 one).
struct LinkAddress: Sendable {
    let storage: sockaddr_storage
    let numeric: String

    var family: Int32 { Int32(storage.ss_family) }

    static func resolve(_ host: String) throws -> LinkAddress {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let list else {
            throw LinkTestError(.network, "Could not resolve \(host)")
        }
        defer { freeaddrinfo(list) }
        var all: [UnsafeMutablePointer<addrinfo>] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = list
        while let entry = cursor {
            if entry.pointee.ai_family == AF_INET || entry.pointee.ai_family == AF_INET6 { all.append(entry) }
            cursor = entry.pointee.ai_next
        }
        guard let chosen = all.first(where: { $0.pointee.ai_family == AF_INET }) ?? all.first, let address = chosen.pointee.ai_addr else {
            throw LinkTestError(.network, "Could not resolve \(host)")
        }
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: UnsafeRawBufferPointer(start: address, count: Int(chosen.pointee.ai_addrlen))) }
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, chosen.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else {
            throw LinkTestError(.network, "Could not resolve \(host)")
        }
        let numeric = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // A scoped IPv6 address keeps its zone in the socket address; the request uses the plain address
        return LinkAddress(storage: storage, numeric: numeric.split(separator: "%").first.map(String.init) ?? numeric)
    }

    var length: socklen_t {
        socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
    }

    /// The same machine as [other] (the address only, not the port).
    func matches(_ other: sockaddr_storage) -> Bool {
        guard Int32(other.ss_family) == family else { return false }
        var mine = storage, theirs = other
        if family == AF_INET {
            let a = withUnsafeBytes(of: &mine) { $0.load(as: sockaddr_in.self).sin_addr.s_addr }
            let b = withUnsafeBytes(of: &theirs) { $0.load(as: sockaddr_in.self).sin_addr.s_addr }
            return a == b
        }
        let a = withUnsafeBytes(of: &mine) { Array(UnsafeRawBufferPointer(rebasing: $0[8..<24])) }
        let b = withUnsafeBytes(of: &theirs) { Array(UnsafeRawBufferPointer(rebasing: $0[8..<24])) }
        return a == b
    }

    /// The port of a socket address.
    static func port(of address: sockaddr_storage) -> Int {
        var copy = address
        return withUnsafeBytes(of: &copy) { Int(UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self))) }
    }

    /// This address with [port].
    func with(port: Int) -> sockaddr_storage {
        var copy = storage
        withUnsafeMutableBytes(of: &copy) { $0.storeBytes(of: UInt16(port).bigEndian, toByteOffset: 2, as: UInt16.self) }
        return copy
    }
}

/// Reads the datagrams of one probe on a thread of its own. Only exact-size packets from the PC that start with the token
/// count; the host's 32-byte warmups are therefore ignored. With the handshake, ``senderPort`` is the host's announced
/// port: the token is sent there every 100 ms until the first measured packet arrives (this also opens outbound UDP state
/// on both sides), and only packets from that port are accepted. The loop allocates nothing and takes no lock; arrival is
/// stamped right after `recvfrom` returns, and scoring happens after it ends.
final class LinkReceiver: @unchecked Sendable {
    let senderPort = Atomic<Int>(0)
    /// Published on the first datagram, every 256 and at the end.
    let authenticated = Atomic<Int>(0)
    let maxStallUs = Atomic<Int>(0)
    let localPort: Int
    /// What the OS granted for the receive buffer.
    let grantedBuffer: Int

    private let socket: Int32
    private let address: LinkAddress
    private let token: [UInt8]
    private let packetSize: Int
    private let handshake: Bool
    private let stopping = Atomic<Bool>(false)
    private let closed = Atomic<Bool>(false)
    /// Written only by the receive thread; read once it has ended.
    private var arrivalsBuffer: UnsafeMutableBufferPointer<Int64>
    private var failure: String?
    private let end = Mutex<(finished: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    /// Every planned sequence number's arrival in microseconds, -1 when it never came; read after ``finish()``.
    var arrivals: [Int64] { Array(arrivalsBuffer) }
    /// Why the receiver stopped early; read after ``finish()``.
    var error: String? { failure }

    private static let pollMs = 10

    init(address: LinkAddress, token: [UInt8], packetSize: Int, expected: Int, handshake: Bool) throws {
        self.address = address
        self.token = token
        self.packetSize = packetSize
        self.handshake = handshake
        let fd = Darwin.socket(address.family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw LinkTestError(.network, "Could not open the UDP receiver: \(String(cString: strerror(errno)))") }
        func fail(_ what: String) -> LinkTestError {
            let text = String(cString: strerror(errno))
            Darwin.close(fd)
            return LinkTestError(.network, "Could not open the UDP receiver (\(what)): \(text)")
        }
        // The OS may grant less than asked; what it granted decides whether a loss can be ours
        var size = Int32(LinkPolicy.receiveBufferBytes)
        while size >= 64 * 1024, setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size)) != 0 { size /= 2 }
        var granted: Int32 = 0
        var grantedLength = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &granted, &grantedLength)
        var timeout = timeval(tv_sec: 0, tv_usec: Int32(Self.pollMs * 1000))
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { throw fail("timeout") }
        var local = sockaddr_storage()
        local.ss_family = sa_family_t(address.family)
        local.ss_len = UInt8(address.length)
        let bound = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, address.length) } }
        guard bound == 0 else { throw fail("bind") }
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard named == 0 else { throw fail("port") }
        socket = fd
        localPort = LinkAddress.port(of: local)
        grantedBuffer = Int(granted)
        arrivalsBuffer = .allocate(capacity: max(expected, 0))
        arrivalsBuffer.initialize(repeating: -1)
    }

    deinit {
        close()
        arrivalsBuffer.deallocate()
    }

    func start() {
        let thread = Thread { [self] in
            run()
            let waiter = end.withLock { state in
                state.finished = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }
        thread.name = "PyroWave link probe"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops the loop and returns once it has ended (within one poll of 10 ms).
    func finish() async {
        stopping.store(true, ordering: .releasing)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = end.withLock { state in
                if state.finished { return true }
                state.waiter = continuation
                return false
            }
            if done { continuation.resume() }
        }
    }

    /// Closes the socket once the loop has ended.
    func close() {
        guard end.withLock({ $0.finished }), !closed.exchange(true, ordering: .acquiringAndReleasing) else { return }
        Darwin.close(socket)
    }

    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    private func run() {
        let payload = packetSize + LinkPolicy.payloadExtraBytes
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: payload + 64, alignment: 8)
        defer { buffer.deallocate() }
        let arrivals = arrivalsBuffer
        var from = sockaddr_storage()
        let start = Self.now()
        var nextToken: UInt64 = 0
        var count = 0
        var stall: UInt64 = 0
        while !stopping.load(ordering: .acquiring) {
            let port = senderPort.load(ordering: .acquiring)
            if handshake, port != 0, count == 0, Self.now() >= nextToken {
                var target = address.with(port: port)
                let sent = token.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &target) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socket, bytes.baseAddress, bytes.count, 0, $0, address.length) }
                    }
                }
                if sent < 0 {
                    failure = String(cString: strerror(errno))
                    return
                }
                nextToken = Self.now() + UInt64(LinkPolicy.handshakeRetryMs) * 1_000_000
            }
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let received = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socket, buffer.baseAddress, buffer.count, 0, $0, &length) }
            }
            if received < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                if !stopping.load(ordering: .acquiring) { failure = String(cString: strerror(errno)) }
                return
            }
            let arrived = Self.now()
            guard received == payload, address.matches(from) else { continue }
            if handshake, LinkAddress.port(of: from) != senderPort.load(ordering: .acquiring) { continue }
            var matches = true
            for index in token.indices where buffer[index] != token[index] {
                matches = false
                break
            }
            guard matches else { continue }
            count += 1
            if count == 1 || count & 255 == 0 { authenticated.store(count, ordering: .releasing) }
            let offset = LinkPolicy.sequenceOffset
            let seq = Int(Int32(bitPattern: UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16
                | UInt32(buffer[offset + 2]) << 8 | UInt32(buffer[offset + 3])))
            // Unique sequence numbers only: duplicates and out-of-range values never inflate the delivery
            if seq >= 0, seq < arrivals.count, arrivals[seq] < 0 { arrivals[seq] = Int64((arrived - start) / 1000) }
            // How long this datagram waited for the loop and its own handling took; a spike means our thread was late
            let busy = Self.now() - arrived
            if busy > stall {
                stall = busy
                maxStallUs.store(Int(stall / 1000), ordering: .releasing)
            }
        }
        authenticated.store(count, ordering: .releasing)
    }
}
