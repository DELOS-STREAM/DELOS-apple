/// What the host announces about its FEC (`PyroWaveCriticalFecPercentage`, `PyroWaveMinParityShards`) plus the stream's
/// packet size (WireBudget.kt).
public struct WireTransport: Equatable, Sendable {
    public var packetSize: Int
    public var criticalFECPercent: Int
    public var minParityShards: Int
    public var envelopeBytes: Int

    public init(packetSize: Int = LinkPolicy.defaultPacketSize, criticalFECPercent: Int, minParityShards: Int = 2, envelopeBytes: Int = 0) {
        self.packetSize = packetSize
        self.criticalFECPercent = criticalFECPercent
        self.minParityShards = minParityShards
        self.envelopeBytes = envelopeBytes
    }
}

/// The conversion between a total wire allowance (what the bitrate setting and the probe use) and the image allowance
/// (what the codec may spend on the picture). A port of `pyrowavebandwidth.h`, which Vibepollo and Nonary's
/// moonlight-qt keep identical: it reserves one maximum feasible critical FEC block, packet rounding, IPv6, encryption,
/// Ethernet overhead and 3572 kbps for audio and control.
public enum WireBudget {
    /// The largest critical-block parity count that still fits one 255-shard Reed-Solomon block, up to [packets] shards.
    public static func maxCriticalParity(_ t: WireTransport, packets: Int64 = Int64(LinkPolicy.maxFECBlockShards)) -> Int64 {
        guard t.criticalFECPercent > 0 else { return 0 }
        let shards = Int64(LinkPolicy.maxFECBlockShards)
        let limit = min(packets, shards)
        var result: Int64 = 0
        var critical: Int64 = 1
        while critical <= limit {
            let parity = max((critical * Int64(t.criticalFECPercent) + 99) / 100, Int64(t.minParityShards))
            if critical + parity <= shards { result = max(result, parity) }
            critical += 1
        }
        return result
    }

    /// The image bytes a [wireBytes] allowance carries; 0 when it cannot even hold the parity.
    public static func imageBytes(_ wireBytes: Int64, _ t: WireTransport) -> Int64 {
        guard t.packetSize > 16 else { return 0 }
        let packets = wireBytes / Int64(t.packetSize + LinkPolicy.wireOverheadBytes)
        let parity = maxCriticalParity(t, packets: packets)
        guard packets > parity else { return 0 }
        let data = (packets - parity) * Int64(t.packetSize - 16)
        let headers = Int64(LinkPolicy.frameHeaderBytes + t.envelopeBytes)
        return data > headers ? (data - headers) & ~3 : 0
    }

    /// The wire bytes an [image] allowance needs.
    public static func wireBytes(_ image: Int64, _ t: WireTransport) -> Int64 {
        guard t.packetSize > 16, image > 0 else { return 0 }
        let payload = Int64(t.packetSize - 16)
        let data = (image + Int64(LinkPolicy.frameHeaderBytes + t.envelopeBytes) + payload - 1) / payload
        return (data + maxCriticalParity(t)) * Int64(t.packetSize + LinkPolicy.wireOverheadBytes)
    }

    /// The image kbps a [totalKbps] wire allowance carries at [fps].
    public static func imageKbps(_ totalKbps: Double, fps: Int, _ t: WireTransport) -> Double {
        guard fps > 0, totalKbps > LinkPolicy.audioControlKbps else { return 0 }
        return Double(imageBytes(Int64((totalKbps - LinkPolicy.audioControlKbps) * 125 / Double(fps)), t)) * Double(fps) / 125
    }

    /// The total wire kbps an [imageKbps] picture needs at [fps].
    public static func totalKbps(_ imageKbps: Double, fps: Int, _ t: WireTransport) -> Double {
        guard fps > 0, imageKbps > 0 else { return 0 }
        return Double(wireBytes(Int64((imageKbps * 125 / Double(fps)).rounded(.up)), t)) * Double(fps) / 125 + LinkPolicy.audioControlKbps
    }
}
