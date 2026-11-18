/// Ports `LinkProbeClientTest.kt` (DELOS for Android), plus a full UDP probe against a loopback fake host.
import Darwin
import Foundation
import Synchronization
import Testing
@testable import DelosHost

/// A PC on 127.0.0.1 for the probe: the handler plays the HTTPS request (and may send the UDP packets itself).
private final class FakeLinkHost: LinkProbeHost {
    typealias Handler = @Sendable (LinkProbeQuery, @escaping @Sendable (Int, [String: String]) -> Void) async throws -> (status: Int, body: Data)

    let hostName = "127.0.0.1"
    private let handler: Handler
    private let queries = Mutex<[LinkProbeQuery]>([])

    var calls: [LinkProbeQuery] { queries.withLock { $0 } }

    init(handler: @escaping Handler = { _, _ in Issue.record("The host was asked"); return (500, Data()) }) {
        self.handler = handler
    }

    func udpProbe(
        address: String, query: LinkProbeQuery, timeout: Duration, onHead: @escaping @Sendable (Int, [String: String]) -> Void
    ) async throws -> (status: Int, body: Data) {
        queries.withLock { $0.append(query) }
        return try await handler(query, onHead)
    }
}

private let supported = PyroWaveHostInfo(
    wireBudgetVersion: 1, udpProbeVersion: 1, udpHandshakeVersion: 1, hostLinkMbps: 0, bandwidthProbeBytes: 0,
    criticalFECPercent: 50, minParityShards: 2)

@Suite struct LinkProbeClientTests {
    private func result(_ expected: String, _ sent: String, _ elapsed: String) -> String {
        "<root status_code=\"200\"><expected>\(expected)</expected><sent>\(sent)</sent><elapsedMs>\(elapsed)</elapsedMs></root>"
    }

    private func parse(_ body: String) throws(LinkTestError) -> LinkProbeResponse { try LinkProbeResponse.parse(Data(body.utf8)) }

    // MARK: The announced UDP port

    @Test func validPortHeader() {
        #expect(LinkProbeClient.validPort("1024") == 1024)
        #expect(LinkProbeClient.validPort("47998") == 47998)
        #expect(LinkProbeClient.validPort(" 65535 ") == 65535)
    }

    @Test func aPortOutsideTheUnprivilegedRangeIsRefused() {
        for header in ["0", "80", "1023", "65536", "99999"] {
            #expect(LinkProbeClient.validPort(header) == nil, "\(header)")
        }
    }

    @Test func aPortThatIsNotAPlainNumberIsRefused() {
        for header in ["", "  ", "-1", "+5000", "5000a", "0x1388", "5 000", "50.0", "123456", "٥٠٠٠", "5000\n5001"] {
            #expect(LinkProbeClient.validPort(header) == nil, "\(header)")
        }
    }

    // MARK: HTTP failures become reasons the UI can word

    @Test func httpStatusBecomesAReason() {
        #expect(LinkProbeClient.failure(code: 403, text: "").failure == .denied)
        #expect(LinkProbeClient.failure(code: 404, text: "<html>not found</html>").failure == .hostUnsupported)
        #expect(LinkProbeClient.failure(code: 400, text: "Stop streaming before testing bandwidth").failure == .streamActive)
        #expect(LinkProbeClient.failure(code: 400, text: "Bad request").failure == .hostError)
        #expect(LinkProbeClient.failure(code: 500, text: "boom").failure == .hostError)
        #expect(LinkProbeClient.failure(code: 503, text: "").failure == .hostError)
    }

    @Test func aHugeErrorBodyIsCutShort() {
        let failure = LinkProbeClient.failure(code: 500, text: String(repeating: "x", count: 100_000))
        #expect(failure.message.count < 1000)
    }

    // MARK: The result document

    @Test func aWellFormedResultIsRead() throws {
        let response = try parse(result("1200", "1180", "1003.5"))
        #expect(response.expected == 1200)
        #expect(response.sent == 1180)
        #expect(abs(response.elapsedMs - 1003.5) <= 0.0001)
    }

    @Test func malformedResponseIsAFailureNotACrash() {
        let malformed = [
            "",
            "not xml at all",
            "<root status_code=\"200\"></root>",
            "<root status_code=\"200\"><expected>12",
            result("many", "1", "1"),
            result("10", "", "1"),
            result("10", "5", "soon"),
            result("10", "5", "NaN"),
            result("-10", "5", "1"),
            result("99999999999999999999", "5", "1"),
        ]
        for body in malformed {
            #expect("\(body)", performing: { try parse(body) }, throws: { ($0 as? LinkTestError)?.failure == .invalidResponse })
        }
    }

    @Test func aHostErrorDocumentIsAHostErrorAndAHandshakeFailureMeansBlockedUdp() {
        #expect(performing: { try parse("<root status_code=\"500\" status_message=\"Encoder busy\"></root>") },
                throws: { ($0 as? LinkTestError)?.failure == .hostError })
        #expect(performing: { try parse("<root status_code=\"500\" status_message=\"UDP handshake timed out\"></root>") },
                throws: { ($0 as? LinkTestError)?.failure == .udpBlocked })
    }

    // MARK: Before anything is sent

    @Test func aRateOutsideTheHostsRangeIsRefusedBeforeAnyNetworkUse() async {
        let host = FakeLinkHost()
        let client = LinkProbeClient(host: host, info: .none)
        await #expect(throws: LinkProbeOutOfRange.self) { try await client.probe(kbps: LinkPolicy.minKbps - 1) }
        await #expect(throws: LinkProbeOutOfRange.self) { try await client.probe(kbps: LinkPolicy.maxKbps + 1) }
        #expect(host.calls.isEmpty)
    }

    @Test func aHostWithoutTheProbeIsUnsupportedBeforeAnyNetworkUse() async {
        let host = FakeLinkHost()
        await #expect(performing: {
            try await runLinkTest(host: host, info: .none, startKbps: 50_000, transport: .wifi)
        }, throws: { ($0 as? LinkTestError)?.failure == .hostUnsupported })
        #expect(host.calls.isEmpty)
    }

    // MARK: Cancelling

    @Test func cancelStopsTheRunningRequest() async throws {
        let asked = AsyncStream<Void>.makeStream()
        let stopped = Mutex(false)
        let host = FakeLinkHost { _, _ in
            asked.continuation.yield()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                stopped.withLock { $0 = true }
                throw error
            }
            return (500, Data())
        }
        let client = LinkProbeClient(host: host, info: supported)
        let task = Task { try await client.probe(kbps: 5000) }
        var events = asked.stream.makeAsyncIterator()
        _ = await events.next()
        #expect(!stopped.withLock { $0 })

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(stopped.withLock { $0 })
    }

    @Test func aRequestStartedAfterCancelIsStoppedAtOnce() async {
        let host = FakeLinkHost { _, _ in
            try await Task.sleep(for: .seconds(60))
            return (500, Data())
        }
        let client = LinkProbeClient(host: host, info: supported)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.probe(kbps: 5000)
        }
        let started = ContinuousClock.now
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    // MARK: A whole probe over UDP (Swift only)

    @Test func aFakeHostThatSendsEveryPacketPassesTheProbe() async throws {
        let packetSize = LinkPolicy.defaultPacketSize
        let host = FakeLinkHost { query, onHead in
            try await Task.detached { try Self.sendProbe(query, packetSize: packetSize, onHead: onHead) }.value
        }
        let client = LinkProbeClient(host: host, info: supported)

        let score = try await client.probe(kbps: 5000)

        let expected = expectedProbePackets(kbps: 5000, packetSize: packetSize)
        #expect(host.calls.count == 1)
        #expect(host.calls.first?.handshake == true)
        #expect(host.calls.first?.kbps == 5000)
        #expect(host.calls.first?.token.count == LinkPolicy.tokenLength)
        #expect(score.expected == expected)
        #expect(score.sent == expected)
        #expect(score.received == expected)
        #expect(score.lossPercent == 0)
    }

    /// The host's side: announce a UDP port, wait for the client's token there, then send every planned packet back.
    private static func sendProbe(
        _ query: LinkProbeQuery, packetSize: Int, onHead: @Sendable (Int, [String: String]) -> Void
    ) throws -> (status: Int, body: Data) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(fd >= 0)
        defer { close(fd) }
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        try #require(bound == 0)
        _ = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        onHead(200, ["x-pyrowave-udp-port": String(UInt16(bigEndian: local.sin_port))])

        var buffer = [UInt8](repeating: 0, count: 256)
        var client = sockaddr_storage()
        var clientLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let received = withUnsafeMutablePointer(to: &client) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &clientLength) }
        }
        try #require(received == LinkPolicy.tokenLength)
        let token = Array(query.token.utf8)
        #expect(Array(buffer[0..<received]) == token)

        let expected = expectedProbePackets(kbps: query.kbps, packetSize: packetSize)
        var packet = [UInt8](repeating: 0, count: packetSize + LinkPolicy.payloadExtraBytes)
        packet.replaceSubrange(0..<token.count, with: token)
        for seq in 0..<expected {
            let offset = LinkPolicy.sequenceOffset
            packet[offset] = UInt8(truncatingIfNeeded: seq >> 24)
            packet[offset + 1] = UInt8(truncatingIfNeeded: seq >> 16)
            packet[offset + 2] = UInt8(truncatingIfNeeded: seq >> 8)
            packet[offset + 3] = UInt8(truncatingIfNeeded: seq)
            let sent = withUnsafePointer(to: &client) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, packet, packet.count, 0, $0, clientLength) }
            }
            try #require(sent == packet.count)
            // Paced a little so loopback never overflows the receive buffer
            if seq % 64 == 63 { usleep(1000) }
        }
        let body = "<root status_code=\"200\"><expected>\(expected)</expected><sent>\(expected)</sent><elapsedMs>2000</elapsedMs></root>"
        return (200, Data(body.utf8))
    }
}
