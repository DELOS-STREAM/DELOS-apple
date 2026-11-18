import Foundation

/// What a paired Vibepollo advertises in its HTTPS `/serverinfo` about PyroWave link measurement (PyroWaveHostInfo.java;
/// Vibepollo `docs/pyrowave-protocol.md`, "Negotiation" and "FEC-inclusive recommendations and UDP calibration"). Hosts
/// that do not know PyroWave, and unpaired (HTTP) answers, leave every field out: ``none``.
public struct PyroWaveHostInfo: Equatable, Sendable, Codable {
    public static let none = PyroWaveHostInfo(
        wireBudgetVersion: 0, udpProbeVersion: 0, udpHandshakeVersion: 0, hostLinkMbps: 0, bandwidthProbeBytes: 0,
        criticalFECPercent: -1, minParityShards: -1)

    /// `PyroWaveWireBudgetVersion`: the wire budget conversion the host uses; this client implements 1.
    public var wireBudgetVersion: Int
    /// `PyroWaveUdpProbeVersion`: 1 = the authenticated UDP probe at `/pyrowave-udp-probe`.
    public var udpProbeVersion: Int
    /// `PyroWaveUdpHandshakeVersion`: 1 = the client sends its token to the host's announced port first.
    public var udpHandshakeVersion: Int
    /// The host's routed wired link speed to this client in Mbps; 0 when unknown or wireless.
    public var hostLinkMbps: Int
    /// `PyroWaveBandwidthProbeBytes`: the legacy HTTPS download probe's size (not used for calibration).
    public var bandwidthProbeBytes: Int64
    /// `PyroWaveCriticalFecPercentage` (0...255, 0 = off), -1 when the host did not say.
    public var criticalFECPercent: Int
    /// `PyroWaveMinParityShards`, -1 when the host did not say.
    public var minParityShards: Int

    public init(
        wireBudgetVersion: Int, udpProbeVersion: Int, udpHandshakeVersion: Int, hostLinkMbps: Int, bandwidthProbeBytes: Int64,
        criticalFECPercent: Int, minParityShards: Int
    ) {
        self.wireBudgetVersion = wireBudgetVersion
        self.udpProbeVersion = udpProbeVersion
        self.udpHandshakeVersion = udpHandshakeVersion
        self.hostLinkMbps = hostLinkMbps
        self.bandwidthProbeBytes = bandwidthProbeBytes
        self.criticalFECPercent = criticalFECPercent
        self.minParityShards = minParityShards
    }

    /// The UDP link test needs the probe and wire budget versions this client implements, and the FEC numbers the
    /// conversion uses. Anything else (older host, newer protocol) is "not supported".
    public var supportsLinkTest: Bool {
        udpProbeVersion == 1 && wireBudgetVersion == 1 && (0...255).contains(criticalFECPercent) && (0...255).contains(minParityShards)
    }

    /// The host sent a probe version, but not one this client knows (a newer Vibepollo than DELOS).
    public var linkTestNeedsNewerClient: Bool { udpProbeVersion > 1 || wireBudgetVersion > 1 }

    static func parse(_ root: HostXMLElement) -> PyroWaveHostInfo {
        func int(_ name: String, _ fallback: Int) -> Int {
            root.child(name).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? fallback
        }
        return PyroWaveHostInfo(
            wireBudgetVersion: int("PyroWaveWireBudgetVersion", 0),
            udpProbeVersion: int("PyroWaveUdpProbeVersion", 0),
            udpHandshakeVersion: int("PyroWaveUdpHandshakeVersion", 0),
            hostLinkMbps: max(0, int("PyroWaveHostLinkMbps", 0)),
            bandwidthProbeBytes: root.child("PyroWaveBandwidthProbeBytes")
                .flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0,
            criticalFECPercent: int("PyroWaveCriticalFecPercentage", -1),
            minParityShards: int("PyroWaveMinParityShards", -1))
    }
}

/// The host's answer to `GET /pyrowave-udp-probe`: the packets it planned and sent, and how long its sending took
/// (PyroWaveProbeResponse.java). Reliable counts: they include packets lost on the way, which only this answer reveals.
public struct LinkProbeResponse: Equatable, Sendable {
    public var expected: Int64
    public var sent: Int64
    public var elapsedMs: Double

    /// Throws ``LinkTestError``: a host failure document (status_code 500 after the UDP handshake) is a host error, or
    /// blocked UDP when its message names the handshake; anything unreadable is an invalid response.
    public static func parse(_ body: Data) throws(LinkTestError) -> LinkProbeResponse {
        let root: HostXMLElement
        do {
            root = try HostXML.root(body)
        } catch HostError.hostStatus(_, let message) {
            let text = message ?? ""
            throw LinkTestError(text.range(of: "handshake", options: .caseInsensitive) != nil ? .udpBlocked : .hostError, text)
        } catch {
            throw LinkTestError(.invalidResponse, String(describing: error))
        }
        func field(_ name: String) -> String? { root.child(name)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let expected = field("expected").flatMap({ Int64($0) }), let sent = field("sent").flatMap({ Int64($0) }),
              let elapsed = field("elapsedMs").flatMap({ Double($0) }),
              expected >= 0, sent >= 0, sent <= expected, elapsed.isFinite, elapsed >= 0 else {
            throw LinkTestError(.invalidResponse, "The host sent an invalid UDP probe result")
        }
        return LinkProbeResponse(expected: expected, sent: sent, elapsedMs: elapsed)
    }
}
