import Foundation
import Network
import Testing
@testable import DelosHost

/// Merging a `serverinfo` answer into what is stored about a host, and the rule that an unverified answer never
/// overwrites stored data (S-06 of DELOS for Android; cases of `ComputerDetailsTest.java` and `PairedHostTrustTest.java`).
@Suite struct HostRecordTests {
    static let id = "2A6F3E0B-11C4-4E7B-9E2D-5B6A7C8D9E0F"
    static let lan = HostAddress(host: "192.168.1.20", port: 47989)
    static let pin = HostPin(certificate: TestIdentities.host.certificate, httpsPort: 47984)

    func reply(_ text: String, from address: HostAddress = lan, _ source: ReplySource) throws -> ServerInfoReply {
        ServerInfoReply(info: try ServerInfo.parse(Data(text.utf8)), address: address, source: source)
    }

    func reply(_ source: ReplySource) throws -> ServerInfoReply {
        try reply(Documents.sunshine, source)
    }

    func pairedRecord() throws -> HostRecord {
        try HostRecord(firstReply: reply(.plainHTTP)).paired(with: Self.pin).updated(with: reply(.pinnedHTTPS))
    }

    @Test func theFirstAnswerFillsTheRecord() throws {
        let record = HostRecord(firstReply: try reply(.plainHTTP))

        #expect(record.id == Self.id)
        #expect(record.name == "LIVINGROOM")
        #expect(record.localAddress == HostAddress(host: "192.168.1.20", port: 47989))
        #expect(record.macAddress == "a0:b1:c2:d3:e4:f5")
        #expect(record.httpsPort == 48984)
        #expect(record.externalPort == 48989)
        #expect(record.codecModeSupport == 3843)
        #expect(record.reachability == .online)
        #expect(record.pin == nil)
        // PairStatus means nothing over plain HTTP.
        #expect(!record.hostReportsPaired)
        #expect(!record.lastReplyVerified)
    }

    @Test func addressesFromTheAnswerMustBeHostNamesOrIPLiterals() throws {
        let hostile = Documents.sunshine
            .replacingOccurrences(of: "192.168.1.20", with: "evil.example\r\nX: y")
        let record = HostRecord(firstReply: try reply(hostile, .plainHTTP))

        #expect(record.localAddress == nil)
        // apolloBusy carries an ExternalIP
        let apollo = Documents.apolloBusy.replacingOccurrences(of: "203.0.113.9", with: "203.0.113.9:80\r\nHost: x")
        #expect(HostRecord(firstReply: try reply(apollo, .plainHTTP)).remoteAddress == nil)
        #expect(HostRecord(firstReply: try reply(Documents.apolloBusy, .plainHTTP)).remoteAddress?.host == "203.0.113.9")
    }

    @Test func aPinnedAnswerUpdatesEverythingButThePin() throws {
        let record = try pairedRecord()
        let renamed = Documents.sunshine
            .replacingOccurrences(of: "LIVINGROOM", with: "STUDY")
            .replacingOccurrences(of: "a0:b1:c2:d3:e4:f5", with: "11:22:33:44:55:66")
            .replacingOccurrences(of: "192.168.1.20", with: "192.168.1.99")

        let updated = try record.updated(with: reply(renamed, .pinnedHTTPS))

        #expect(updated.name == "STUDY")
        #expect(updated.macAddress == "11:22:33:44:55:66")
        #expect(updated.localAddress == HostAddress(host: "192.168.1.99", port: 47989))
        #expect(updated.pin == record.pin)
        #expect(updated.hostReportsPaired)
        #expect(updated.lastReplyVerified)
    }

    @Test func theUsersNameForAPCOutlivesTheAnswersOfThePC() throws {
        var record = try pairedRecord()
        record.customName = "Living room"
        let updated = try record.updated(with: reply(Documents.sunshine.replacingOccurrences(of: "LIVINGROOM", with: "STUDY"), .pinnedHTTPS))
        #expect(updated.name == "Living room")
        #expect(updated.serverName == "STUDY")
        let decoded = try JSONDecoder().decode(HostRecord.self, from: JSONEncoder().encode(updated))
        #expect(decoded == updated)
    }

    @Test func anUnverifiedAnswerForAPairedHostChangesOnlyReachability() throws {
        let record = try pairedRecord().markedOffline()
        // Anyone on the network can answer over HTTP with the host's id (it is served to everyone).
        let spoofed = Documents.serverInfo(id: Self.id, paired: true, httpsPort: 50000, name: "EVIL")
            .replacingOccurrences(of: "a0:b1:c2:d3:e4:f5", with: "66:66:66:66:66:66")
            .replacingOccurrences(of: "<LocalIP>192.168.1.20", with: "<LocalIP>10.6.6.6")
        let elsewhere = HostAddress(host: "10.6.6.6", port: 47989)

        let updated = try record.updated(with: reply(spoofed, from: elsewhere, .plainHTTP))

        var expected = record
        expected.reachability = .online
        expected.activeAddress = elsewhere
        expected.lastReplyVerified = false
        #expect(updated == expected)
    }

    @Test func anAnswerFromAnotherHostIsRejected() throws {
        let record = try pairedRecord()

        #expect(throws: HostError.differentHost) {
            try record.updated(with: reply(Documents.serverInfo(id: "OTHER-HOST"), .pinnedHTTPS))
        }
        #expect(throws: HostError.differentHost) {
            try record.updated(with: reply(Documents.serverInfo(id: "OTHER-HOST"), .plainHTTP))
        }
    }

    @Test func beforePairingPlainAnswersKeepTheRecordCurrent() throws {
        let record = HostRecord(firstReply: try reply(.plainHTTP))

        let updated = try record.updated(with: reply(Documents.serverInfo(name: "RENAMED"), .plainHTTP))

        #expect(updated.name == "RENAMED")
        #expect(updated.pin == nil)
    }

    @Test func knownAddressesAndMacSurviveAnAnswerWithoutThem() throws {
        let record = try pairedRecord()
        let bare = Documents.sunshine
            .replacingOccurrences(of: "<mac>a0:b1:c2:d3:e4:f5</mac>", with: "<mac>00:00:00:00:00:00</mac>")
            .replacingOccurrences(of: "<LocalIP>192.168.1.20</LocalIP>", with: "<LocalIP>127.0.0.1</LocalIP>")

        let updated = try record.updated(with: reply(bare, .pinnedHTTPS))

        // An all-zero MAC and a loopback local address do not replace the real ones.
        #expect(updated.macAddress == "a0:b1:c2:d3:e4:f5")
        #expect(updated.localAddress == HostAddress(host: "192.168.1.20", port: 47989))
    }

    @Test func anExternalPortWithoutAnAddressMovesTheKnownRemoteAddress() throws {
        let withRemote = try pairedRecord().updated(with: reply(
            Documents.sunshine.replacingOccurrences(of: "<LocalIP>", with: "<ExternalIP>203.0.113.9</ExternalIP><LocalIP>"),
            .pinnedHTTPS))
        #expect(withRemote.remoteAddress == HostAddress(host: "203.0.113.9", port: 48989))

        let moved = try withRemote.updated(with: reply(
            Documents.sunshine.replacingOccurrences(of: "<ExternalPort>48989", with: "<ExternalPort>50000"), .pinnedHTTPS))

        #expect(moved.remoteAddress == HostAddress(host: "203.0.113.9", port: 50000))
    }

    @Test func runningAppFollowsTheAnswerAndOfflineClearsIt() throws {
        let busy = try HostRecord(firstReply: reply(Documents.apolloBusy, .plainHTTP))
        #expect(busy.runningAppID == 881448767)

        let offline = busy.markedOffline()

        #expect(offline.reachability == .offline)
        #expect(offline.runningAppID == 0)
        #expect(offline.name == busy.name)
    }

    @Test func unpairingDropsThePin() throws {
        let record = try pairedRecord().unpaired()

        #expect(record.pin == nil)
        #expect(!record.hostReportsPaired)
    }

    @Test func aRecordSurvivesEncoding() throws {
        let record = try pairedRecord()

        #expect(try JSONDecoder().decode(HostRecord.self, from: JSONEncoder().encode(record)) == record)
    }
}

@Suite struct WakeOnLanTests {
    @Test func theMagicPacketIsSixFFsAndTheMacSixteenTimes() throws {
        let packet = try #require(WakeOnLan.magicPacket(macAddress: "a0:b1:c2:d3:e4:f5"))

        #expect(packet.count == 102)
        #expect(packet.prefix(6) == Data(repeating: 0xFF, count: 6))
        for repetition in 0..<16 {
            #expect(packet.dropFirst(6 + repetition * 6).prefix(6) == Data([0xA0, 0xB1, 0xC2, 0xD3, 0xE4, 0xF5]))
        }
        #expect(WakeOnLan.magicPacket(macAddress: "A0-B1-C2-D3-E4-F5") == packet)
    }

    @Test(arguments: ["", "a0:b1:c2:d3:e4", "a0:b1:c2:d3:e4:f5:06", "a0:b1:c2:d3:e4:g5", "a0b1c2d3e4f5", "00:00:00:00:00:00", "a:b1:c2:d3:e4:f50"])
    func whatIsNotAMacAddressSendsNothing(mac: String) {
        #expect(WakeOnLan.magicPacket(macAddress: mac) == nil)
    }

    @Test func thePortsFollowTheHostsHTTPPort() {
        #expect(WakeOnLan.ports(httpPort: 47989) == [9, 47009, 47998, 47999, 48000, 48002, 48010])
        #expect(WakeOnLan.ports(httpPort: 48989) == [9, 47009, 48998, 48999, 49000, 49002, 49010])
    }

    @Test func thePacketReachesTheHost() async throws {
        // A UDP listener on the loopback interface stands in for the PC's port 47998 (shifted by the HTTP port).
        let received = AsyncStream.makeStream(of: Data.self)
        let listener = try NWListener(using: .udp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receiveMessage { data, _, _, _ in
                if let data { received.continuation.yield(data) }
            }
        }
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let once = Once(continuation)
            listener.stateUpdateHandler = { state in
                if case .ready = state { once.resume(with: .success(Int(listener.port!.rawValue))) }
                if case .failed(let error) = state { once.resume(with: .failure(error)) }
            }
            listener.start(queue: .global())
        }
        defer { listener.cancel() }

        let sent = await WakeOnLan.wake(
            macAddress: "a0:b1:c2:d3:e4:f5", addresses: [HostAddress(host: "127.0.0.1", port: port - 9)], broadcast: false)

        #expect(sent == 7)
        var iterator = received.stream.makeAsyncIterator()
        #expect(await iterator.next() == WakeOnLan.magicPacket(macAddress: "a0:b1:c2:d3:e4:f5"))
    }
}

@Suite struct DiscoveryTests {
    @Test func aResolvedEndpointBecomesAnAddress() {
        #expect(HostDiscovery.address(of: .hostPort(host: "192.168.1.20", port: 47989)) == HostAddress(host: "192.168.1.20", port: 47989))
        #expect(HostDiscovery.address(of: .hostPort(host: "2001:db8::1", port: 47989)) == HostAddress(host: "2001:db8::1", port: 47989))
        #expect(HostDiscovery.address(of: .hostPort(host: "desk.local", port: 47989)) == HostAddress(host: "desk.local", port: 47989))
        // Bonjour resolves to an address with its interface (`192.168.1.20%en0`); an IPv4 address is kept without it.
        let scoped = NWEndpoint.Host("192.168.1.20%lo0")
        #expect("\(scoped)".contains("%"))
        #expect(HostDiscovery.address(of: .hostPort(host: scoped, port: 47989)) == HostAddress(host: "192.168.1.20", port: 47989))
        #expect(HostDiscovery.address(of: .service(name: "x", type: "_nvstream._tcp", domain: "local.", interface: nil)) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aServiceOnThisMachineIsFoundAndResolved() async throws {
        // A private service type, so no GameStream client on the network sees the test.
        let type = "_delostest._tcp"
        let name = "DELOS test \(UUID().uuidString.prefix(8))"
        let listener = try NWListener(using: .tcp, on: .any)
        listener.service = NWListener.Service(name: name, type: type)
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .global())
        defer { listener.cancel() }

        var found: DiscoveredHost?
        for await event in HostDiscovery(serviceType: type).events() {
            if case .found(let host) = event, host.serviceName == name {
                found = host
                break
            }
        }
        #expect(found?.address.port == Int(listener.port!.rawValue))
    }
}
