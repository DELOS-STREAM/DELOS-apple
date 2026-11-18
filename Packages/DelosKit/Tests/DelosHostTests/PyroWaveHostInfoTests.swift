/// Ports `PyroWaveHostInfoTest.kt` (DELOS for Android).
import Foundation
import Testing
@testable import DelosHost

@Suite struct PyroWaveHostInfoTests {
    private func info(_ fields: [(String, String)] = []) throws -> PyroWaveHostInfo {
        let body = "<root status_code=\"200\"><hostname>PC</hostname>" + fields.map { "<\($0.0)>\($0.1)</\($0.0)>" }.joined() + "</root>"
        return PyroWaveHostInfo.parse(try HostXML.root(Data(body.utf8)))
    }

    private let full: [(String, String)] = [
        ("PyroWaveHostLinkMbps", "2500"), ("PyroWaveBandwidthProbeBytes", "33554432"),
        ("PyroWaveWireBudgetVersion", "1"), ("PyroWaveUdpProbeVersion", "1"), ("PyroWaveUdpHandshakeVersion", "1"),
        ("PyroWaveCriticalFecPercentage", "50"), ("PyroWaveMinParityShards", "2"),
    ]

    private func without(_ name: String, _ extra: [(String, String)] = []) -> [(String, String)] {
        full.filter { $0.0 != name } + extra
    }

    @Test func readsEveryFieldTheLinkTestNeeds() throws {
        let host = try info(full)
        #expect(host.hostLinkMbps == 2500)
        #expect(host.bandwidthProbeBytes == 33_554_432)
        #expect(host.wireBudgetVersion == 1)
        #expect(host.udpProbeVersion == 1)
        #expect(host.udpHandshakeVersion == 1)
        #expect(host.criticalFECPercent == 50)
        #expect(host.minParityShards == 2)
        #expect(host.supportsLinkTest)
        #expect(!host.linkTestNeedsNewerClient)
    }

    @Test func aDisabledCriticalFecIsAValidZero() throws {
        let host = try info(without("PyroWaveCriticalFecPercentage", [("PyroWaveCriticalFecPercentage", "0")]))
        #expect(host.criticalFECPercent == 0)
        #expect(host.supportsLinkTest)
    }

    @Test func anOldHostOrAHostWithoutPyroWaveCannotTest() throws {
        let plain = try info()
        #expect(!plain.supportsLinkTest)
        #expect(!plain.linkTestNeedsNewerClient)
        #expect(plain.hostLinkMbps == 0)
        #expect(plain.criticalFECPercent == -1)
        // The legacy download probe alone (no UDP probe fields)
        let legacy = try info([("PyroWaveHostLinkMbps", "1000"), ("PyroWaveBandwidthProbeBytes", "33554432")])
        #expect(!legacy.supportsLinkTest)
        #expect(legacy.hostLinkMbps == 1000)
    }

    @Test func aNewerProtocolIsNamedAndNotGuessedAt() throws {
        let newer = try info(without("PyroWaveUdpProbeVersion", [("PyroWaveUdpProbeVersion", "2")]))
        #expect(!newer.supportsLinkTest)
        #expect(newer.linkTestNeedsNewerClient)
        let budget = try info(without("PyroWaveWireBudgetVersion", [("PyroWaveWireBudgetVersion", "2")]))
        #expect(!budget.supportsLinkTest)
    }

    @Test func missingOrInvalidFecNumbersMakeTheTestUnsupportedRatherThanGuessed() throws {
        #expect(try !info(without("PyroWaveCriticalFecPercentage")).supportsLinkTest)
        #expect(try !info(without("PyroWaveMinParityShards")).supportsLinkTest)
        #expect(try !info(without("PyroWaveCriticalFecPercentage", [("PyroWaveCriticalFecPercentage", "abc")])).supportsLinkTest)
        #expect(try !info(without("PyroWaveCriticalFecPercentage", [("PyroWaveCriticalFecPercentage", "256")])).supportsLinkTest)
    }

    @Test func theProbeAnswerCarriesTheReliableCounts() throws {
        let answer = try LinkProbeResponse.parse(Data((
            "<root status_code=\"200\"><expected>40956</expected><sent>40956</sent><elapsedMs>2000.4</elapsedMs>" +
                "<sendRetries>0</sendRetries><lastSendError>0</lastSendError></root>").utf8))
        #expect(answer.expected == 40956)
        #expect(answer.sent == 40956)
        #expect(abs(answer.elapsedMs - 2000.4) <= 1e-9)
    }

    @Test func aHostFailureAfterTheHandshakeSurfacesItsMessage() {
        #expect(throws: LinkTestError(.udpBlocked, "The client did not complete the UDP handshake")) {
            try LinkProbeResponse.parse(Data(
                "<root status_code=\"500\" status_message=\"The client did not complete the UDP handshake\"/>".utf8))
        }
    }

    @Test func anInvalidProbeAnswerIsRejected() {
        for body in [
            "<root status_code=\"200\"><expected>10</expected><sent>11</sent><elapsedMs>2000</elapsedMs></root>",
            "<root status_code=\"200\"><expected>x</expected><sent>1</sent><elapsedMs>2000</elapsedMs></root>",
            "<root status_code=\"200\"><expected>10</expected><sent>10</sent><elapsedMs>nan</elapsedMs></root>",
            "<root status_code=\"200\"><expected>10</expected></root>",
        ] {
            #expect(throws: LinkTestError.self, "\(body)") { try LinkProbeResponse.parse(Data(body.utf8)) }
        }
    }
}
