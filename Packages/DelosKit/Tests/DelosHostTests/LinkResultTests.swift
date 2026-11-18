/// Ports `LinkResultTest.kt` (DELOS for Android): the stored result; its age and summary texts are in DelosUITests/LinkVerdictTextTests.swift.
import Testing
@testable import DelosHost

@Suite struct LinkResultTests {
    private let now: Int64 = 1_794_052_800_000

    @Test func aStoredResultRoundTripsAndForeignTextIsIgnored() {
        let test = LinkTest(wireKbps: 340_000, testedAtMs: now, transport: .ethernet, criticalFECPercent: 50, packetSize: 1392)
        #expect(LinkTest.decode(test.encode()) == test)
        #expect(LinkTest.decode(nil) == nil)
        #expect(LinkTest.decode("") == nil)
        #expect(LinkTest.decode("2;340000;1;WIFI;50;1392") == nil)
        #expect(LinkTest.decode("1;340000;x;WIFI;50;1392") == nil)
        #expect(LinkTest.decode("1;1000;1;WIFI;50;1392") == nil)
        #expect(LinkTest.decode("1;340000;1;SATELLITE;50;1392")?.transport == .other)
    }
}
