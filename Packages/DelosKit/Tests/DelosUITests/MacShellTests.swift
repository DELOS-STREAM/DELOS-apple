import Foundation
import Testing
@testable import DelosUI

@MainActor
@Suite struct StreamShutdownTests {
    @Test func withoutAStreamThereIsNothingToLeave() async {
        let shutdown = StreamShutdown()
        #expect(!shutdown.hasStream)
        await shutdown.leaveAll()
    }

    @Test func leavingWaitsForTheStreamsToLeave() async {
        let shutdown = StreamShutdown()
        var left = 0
        let id = shutdown.register {
            try? await Task.sleep(for: .milliseconds(50))
            left += 1
        }
        #expect(shutdown.hasStream)
        await shutdown.leaveAll(timeout: .seconds(5))
        #expect(left == 1)
        shutdown.unregister(id)
        #expect(!shutdown.hasStream)
    }

    @Test func aStreamThatNeverLeavesDoesNotKeepTheAppOpen() async {
        let shutdown = StreamShutdown()
        _ = shutdown.register {
            // A disconnect that hangs
            try? await Task.sleep(for: .seconds(60))
        }
        let start = ContinuousClock.now
        await shutdown.leaveAll(timeout: .milliseconds(100))
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func aStreamThatLeftEarlierIsNotLeftAgain() async {
        let shutdown = StreamShutdown()
        var left = 0
        let id = shutdown.register { left += 1 }
        shutdown.unregister(id)
        await shutdown.leaveAll()
        #expect(left == 0)
    }
}

@Suite struct MacBatteryTests {
    private func source(_ extra: [String: Any]) -> [String: Any] {
        var info: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 80, "Max Capacity": 100]
        info.merge(extra) { $1 }
        return info
    }

    @Test func theInternalBatterysChargeIsItsCapacityOverItsMaximum() throws {
        let battery = try #require(BatteryStatus(powerSource: source(["Power Source State": "Battery Power"])))
        #expect(battery.level == 0.8 && !battery.charging && !battery.low)
        #expect(battery.percent == "80%")
        let low = try #require(BatteryStatus(powerSource: source(["Current Capacity": 15, "Power Source State": "Battery Power"])))
        #expect(low.low)
        // A capacity that is not a percentage (mAh) still gives the fraction
        let milliamps = try #require(BatteryStatus(powerSource: source(["Current Capacity": 2500, "Max Capacity": 5000])))
        #expect(milliamps.level == 0.5)
    }

    @Test func aMacOnTheChargerShowsTheBoltChargingOrHoldingItsCharge() throws {
        let charging = try #require(BatteryStatus(powerSource: source(["Is Charging": true, "Power Source State": "AC Power"])))
        #expect(charging.charging && !charging.low)
        let holding = try #require(BatteryStatus(powerSource: source(["Is Charging": false, "Power Source State": "AC Power"])))
        #expect(holding.charging)
    }

    @Test func nothingButTheInternalBatteryCounts() {
        #expect(BatteryStatus(powerSource: ["Type": "UPS", "Current Capacity": 50, "Max Capacity": 100]) == nil)
        #expect(BatteryStatus(powerSource: ["Current Capacity": 50, "Max Capacity": 100]) == nil)
        #expect(BatteryStatus(powerSource: source(["Max Capacity": 0])) == nil)
        #expect(BatteryStatus(powerSource: ["Type": "InternalBattery"]) == nil)
    }
}
