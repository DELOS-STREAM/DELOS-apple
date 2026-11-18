/// Ports `WireBudgetTest.kt` (DELOS for Android); the numbers come from an independent transcription of `pyrowavebandwidth.h`.
import Testing
@testable import DelosHost

@Suite struct WireBudgetTests {
    private let fec50 = WireTransport(packetSize: 1392, criticalFECPercent: 50, minParityShards: 2)
    private let fec0 = WireTransport(packetSize: 1392, criticalFECPercent: 0, minParityShards: 2)

    private func near(_ value: Double, _ expected: Double, _ tolerance: Double = 0.01) -> Bool { abs(value - expected) <= tolerance }

    @Test func reservesTheLargestCriticalBlockThatFitsOneReedSolomonBlock() {
        #expect(WireBudget.maxCriticalParity(fec50) == 85)            // 170 data + 85 parity = 255 shards
        #expect(WireBudget.maxCriticalParity(WireTransport(packetSize: 1392, criticalFECPercent: 20)) == 43)
        #expect(WireBudget.maxCriticalParity(fec0) == 0)
        #expect(WireBudget.maxCriticalParity(fec50, packets: 10) == 5) // fewer packets, fewer parity shards
        // The two-shard minimum applies to tiny blocks
        #expect(WireBudget.maxCriticalParity(WireTransport(packetSize: 1392, criticalFECPercent: 1), packets: 1) == 2)
    }

    @Test func anImageAllowanceNeedsItsWireAllowance() {
        #expect(near(WireBudget.totalKbps(220_000, fps: 60, fec50), 310_481.12))
        #expect(near(WireBudget.totalKbps(220_000, fps: 60, fec0), 248_220.32))
        // The audio and control reserve alone is the floor
        #expect(near(WireBudget.totalKbps(1, fps: 60, fec50), 66_565.28))
    }

    @Test func aWireAllowanceCarriesLessPicture() {
        #expect(near(WireBudget.imageKbps(340_000, fps: 60, fec50), 247_015.68))
        #expect(near(WireBudget.imageKbps(180_000, fps: 60, fec50), 102_370.56))
        // Nothing is left when the budget cannot even hold the reserve
        #expect(WireBudget.imageKbps(3_000, fps: 60, fec50) == 0)
        #expect(WireBudget.imageKbps(100_000, fps: 0, fec50) == 0)
    }

    @Test func theTwoConversionsRoundTripWithinPacketRounding() {
        let wire = WireBudget.totalKbps(220_000, fps: 60, fec50)
        let image = WireBudget.imageKbps(wire, fps: 60, fec50)
        #expect(near(image, 220_596.48))
        #expect(image >= 220_000 && image < 221_000)
    }

    @Test func aHigherFrameRateReservesMoreParityForTheSamePicture() {
        let at60 = WireBudget.totalKbps(220_000, fps: 60, fec50) - LinkPolicy.audioControlKbps
        let at120 = WireBudget.totalKbps(220_000, fps: 120, fec50) - LinkPolicy.audioControlKbps
        // One critical block of parity is reserved per frame: the same picture bitrate in twice the frames costs more wire
        #expect(at120 > at60 && at120 < at60 * 1.3)
    }
}
