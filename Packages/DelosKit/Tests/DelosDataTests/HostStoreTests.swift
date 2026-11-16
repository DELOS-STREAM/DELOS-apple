import Foundation
import Network
import Synchronization
import Testing
@testable import DelosData
@testable import DelosHost

@MainActor
@Suite struct HostStoreTests {
    private func record(id: String, name: String, address: HostAddress = HostAddress(host: "192.168.1.5", port: 47989)) throws -> HostRecord {
        let xml = """
        <root status_code="200"><hostname>\(name)</hostname><uniqueid>\(id)</uniqueid><HttpsPort>47984</HttpsPort>\
        <appversion>7.1.431.-1</appversion><PairStatus>0</PairStatus><state>SUNSHINE_SERVER_FREE</state></root>
        """
        let info = try ServerInfo.parse(Data(xml.utf8))
        return HostRecord(firstReply: ServerInfoReply(info: info, address: address, source: .plainHTTP))
    }

    private func suite() -> UserDefaults {
        let name = "delos.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func onlyPairedPCsAreKeptAcrossLaunchesAndComeBackOffline() throws {
        let defaults = suite()
        let store = HostStore(defaults: defaults)
        let pin = HostPin(certificate: Data([1, 2, 3]), httpsPort: 47984)
        store.store(try record(id: "AAAA", name: "Found PC"))
        store.store(try record(id: "BBBB", name: "Desk PC").paired(with: pin))
        #expect(store.hosts.map(\.name) == ["Desk PC", "Found PC"])

        let again = HostStore(defaults: defaults)
        #expect(again.hosts.map(\.id) == ["BBBB"])
        #expect(again.hosts.first?.pin == pin)
        #expect(again.hosts.first?.reachability == .offline)
    }

    @Test func aStoredRecordThatNoLongerDecodesIsSkipped() throws {
        let defaults = suite()
        let good = try JSONEncoder().encode(try record(id: "CCCC", name: "Good").paired(with: HostPin(certificate: Data([9]), httpsPort: 1)))
        let list = "[{\"id\":42},\(String(decoding: good, as: UTF8.self))]"
        defaults.set(Data(list.utf8), forKey: "hosts")
        #expect(HostStore(defaults: defaults).hosts.map(\.name) == ["Good"])
    }

    @Test func thePINHasFourDigits() {
        for _ in 0..<50 {
            let pin = HostStore.newPIN()
            #expect(pin.count == 4 && pin.allSatisfy(\.isNumber))
        }
    }

    @Test func aRenamedPCKeepsItsNameAcrossLaunchesUntilTheNameIsCleared() throws {
        let defaults = suite()
        let store = HostStore(defaults: defaults)
        let pin = HostPin(certificate: Data([1, 2, 3]), httpsPort: 47984)
        store.store(try record(id: "BBBB", name: "DESKTOP-7Q").paired(with: pin))
        store.rename("BBBB", to: "  Living room PC with a long name  ")
        #expect(store.host("BBBB")?.name == "Living room PC with a lo")
        #expect(store.host("BBBB")?.serverName == "DESKTOP-7Q")
        #expect(HostStore(defaults: defaults).host("BBBB")?.name == "Living room PC with a lo")
        store.rename("BBBB", to: " ")
        #expect(store.host("BBBB")?.name == "DESKTOP-7Q")
        #expect(HostStore(defaults: defaults).host("BBBB")?.customName == nil)
    }

    @Test func aRecordStoredBeforeCustomNamesKeepsTheServerName() throws {
        let defaults = suite()
        let json = try JSONEncoder().encode([try record(id: "DDDD", name: "Old").paired(with: HostPin(certificate: Data([9]), httpsPort: 1))])
        var object = try #require(try JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        object[0]["customName"] = nil
        #expect(object[0]["name"] as? String == "Old")
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "hosts")
        #expect(HostStore(defaults: defaults).host("DDDD")?.name == "Old")
    }

    /// A store whose paired PC answers through `host`: its refresh waits there until the test releases it.
    private func storeWithPairedPC(at host: HoldingHost, defaults: UserDefaults) throws -> HostStore {
        let store = HostStore(defaults: defaults, identities: Self.identities)
        let pin = HostPin(certificate: Data([1, 2, 3]), httpsPort: host.address.port)
        store.store(try record(id: "BBBB", name: "Desk PC", address: host.address).paired(with: pin))
        return store
    }

    private static let identities = ClientIdentityStore(storage: MemoryStorage())

    @Test func anUnpairDuringARefreshStaysUnpaired() async throws {
        let host = try await HoldingHost()
        let defaults = suite()
        let store = try storeWithPairedPC(at: host, defaults: defaults)
        let refresh = Task { await store.refresh("BBBB") }
        await host.waitUntilHolding()

        await store.unpair("BBBB")
        #expect(store.host("BBBB")?.pin == nil)
        // The refresh's answer (here a broken connection) arrives after the unpair
        host.release()
        await refresh.value

        #expect(store.host("BBBB")?.pin == nil)
        #expect(HostStore(defaults: defaults).host("BBBB") == nil)
    }

    @Test func aRenameDuringARefreshIsKept() async throws {
        let host = try await HoldingHost()
        let store = try storeWithPairedPC(at: host, defaults: suite())
        let refresh = Task { await store.refresh("BBBB") }
        await host.waitUntilHolding()

        store.rename("BBBB", to: "Living room")
        host.release()
        await refresh.value

        #expect(store.host("BBBB")?.name == "Living room")
        #expect(store.host("BBBB")?.reachability == .offline)
    }
}

/// A PC on the loopback interface that answers `/unpair` and holds every other request (a `serverinfo` on its way,
/// over HTTP or HTTPS) until the test releases it, which breaks the connection.
private final class HoldingHost: Sendable {
    private final class Held: Sendable {
        let connections = Mutex<[NWConnection]>([])
    }

    let address: HostAddress
    private let listener: NWListener
    private let held: Held

    init() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let held = Held()
        let queue = DispatchQueue(label: "holding-host")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if let data, data.starts(with: Data("GET /unpair".utf8)) {
                    let body = #"<root status_code="200"/>"#
                    let answer = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(answer.utf8), completion: .contentProcessed { _ in connection.cancel() })
                } else {
                    held.connections.withLock { $0.append(connection) }
                }
            }
        }
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
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
        self.listener = listener
        self.held = held
        address = HostAddress(host: "127.0.0.1", port: port)
    }

    deinit {
        listener.cancel()
        release()
    }

    func waitUntilHolding() async {
        for _ in 0..<250 where held.connections.withLock({ $0.isEmpty }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func release() {
        held.connections.withLock { connections in
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}

private final class MemoryStorage: SecretStorage {
    private let items = Mutex<[String: Data]>([:])

    func read(account: String) throws -> Data? { items.withLock { $0[account] } }
    func write(_ data: Data, account: String) throws { items.withLock { $0[account] = data } }
    func delete(account: String) throws { _ = items.withLock { $0.removeValue(forKey: account) } }
}

@Suite struct StreamPlanTests {
    /// Values of DELOS for Android's getDefaultBitrate for the same inputs.
    @Test(arguments: [
        (1920, 1080, 60, 20000), (1280, 720, 60, 10000), (1920, 1080, 30, 10000),
        (3840, 2160, 120, 113000), (2400, 1080, 60, 26000), (320, 240, 60, 2000),
    ])
    func theDefaultBitrateMatchesAndroid(width: Int, height: Int, fps: Int, kbps: Int) {
        #expect(StreamPlan.defaultBitrateKbps(width: width, height: height, fps: fps) == kbps)
    }

    @Test func theDisplayResolutionIsCappedAt1080p() {
        // iPhone 14 Pro Max: 2796 × 1290 pixels
        let settings = StreamResolution.forDisplay(pixelWidth: 1290, pixelHeight: 2796)
        #expect(settings.height <= 1080 && settings.width <= 1920)
        #expect(settings.width % 2 == 0 && settings.height % 2 == 0)
        #expect(abs(Double(settings.width) / Double(settings.height) - 2796.0 / 1290.0) < 0.01)
    }

    @Test func theLaunchRequestAndTheStreamShareTheInputKey() {
        var counter: UInt8 = 0
        let plan = StreamPlan(
            app: HostApp(id: 7, title: "Desktop"), settings: StreamSettings(resolution: StreamResolution(width: 1920, height: 1080)),
            display: StreamResolution(width: 2796, height: 1290), decodable: .h264, refreshRate: 120, randomBytes: { n in (0..<n).map { _ in counter &+= 1; return counter } })
        #expect(plan.request.remoteInputKey == Data(plan.configuration.remoteInputKey.key))
        // The IV starts with the key id, big-endian
        let id = plan.request.remoteInputKeyID
        #expect(Array(plan.configuration.remoteInputKey.iv.prefix(4)) == withUnsafeBytes(of: id.bigEndian) { Array($0) })
        #expect(plan.configuration.bitrateKbps == 20000)
        #expect(plan.request.surroundAudioInfo == 0x3 << 16 | 2)
    }
}
