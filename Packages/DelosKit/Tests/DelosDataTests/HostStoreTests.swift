import DelosHost
import Foundation
import Testing
@testable import DelosData

@MainActor
@Suite struct HostStoreTests {
    private func record(id: String, name: String) throws -> HostRecord {
        let xml = """
        <root status_code="200"><hostname>\(name)</hostname><uniqueid>\(id)</uniqueid><HttpsPort>47984</HttpsPort>\
        <appversion>7.1.431.-1</appversion><PairStatus>0</PairStatus><state>SUNSHINE_SERVER_FREE</state></root>
        """
        let info = try ServerInfo.parse(Data(xml.utf8))
        return HostRecord(firstReply: ServerInfoReply(info: info, address: HostAddress(host: "192.168.1.5", port: 47989), source: .plainHTTP))
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
