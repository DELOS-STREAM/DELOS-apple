import DelosData
import Foundation
import Testing

/// Which screen is main and where the companion goes (`DualScreenPlannerTest`, `CompanionDimSettingTest` and
/// `CompanionLogicTest`'s dimming of DELOS for Android).
@Suite struct SecondDisplayTests {
    private let phone = ScreenSize(width: 2556, height: 1179)
    private let tv = ScreenSize(width: 3840, height: 2160)
    private let small = ScreenSize(width: 1240, height: 1080)

    private func plan(
        second: ScreenSize?, role: SecondDisplayRole, choice: MainScreenChoice = .automatic, fullExternal: Bool = false, streaming: Bool = false
    ) -> ScreenPlan? {
        ScreenPlanner.plan(device: phone, second: second, role: role, choice: choice, fullExternal: fullExternal, streaming: streaming)
    }

    @Test func withoutASecondScreenNothingChanges() {
        for role in SecondDisplayRole.allCases {
            #expect(plan(second: nil, role: role, fullExternal: true, streaming: true) == nil)
            #expect(!ScreenPlanner.paired(second: nil, role: role))
        }
    }

    @Test func aPairPutsTheLargerScreenFirstUnlessSwapped() {
        #expect(plan(second: tv, role: .builtIn) == ScreenPlan(main: .second))
        #expect(plan(second: tv, role: .builtIn)?.companion == .device)
        #expect(plan(second: small, role: .builtIn) == ScreenPlan(main: .device))
        #expect(plan(second: tv, role: .builtIn, choice: .swapped) == ScreenPlan(main: .device))
        #expect(plan(second: small, role: .builtIn, choice: .swapped) == ScreenPlan(main: .second))
        #expect(ScreenPlanner.paired(second: tv, role: .builtIn))
    }

    @Test func aTieGoesToTheDevicesOwnScreen() {
        #expect(ScreenPlanner.pair(device: phone, second: phone, choice: .automatic).main == .device)
        #expect(ScreenPlanner.pair(device: phone, second: phone, choice: .swapped).main == .second)
    }

    @Test func aMonitorTakesOnlyAStreamInFullyExternalDisplayMode() {
        for role in [SecondDisplayRole.automatic, .external] {
            #expect(plan(second: tv, role: role) == nil)
            #expect(plan(second: tv, role: role, fullExternal: true) == nil)
            #expect(plan(second: tv, role: role, streaming: true) == nil)
            // The stream goes to the monitor and the device's screen is its touch control, whatever its size or Main screen
            #expect(plan(second: small, role: role, choice: .swapped, fullExternal: true, streaming: true) == ScreenPlan(main: .second))
            #expect(!ScreenPlanner.paired(second: tv, role: role))
        }
    }

    @Test func partOfTheDeviceIsNeverAStreamTargetOfTheExternalMode() {
        // A paired screen follows Main screen even in Fully External Display Mode
        #expect(plan(second: small, role: .builtIn, fullExternal: true, streaming: true) == ScreenPlan(main: .device))
    }

    @Test func mainScreenAndDimmingAreKeptForTheDevice() {
        let suite = "delos.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MainScreenChoice.load(defaults) == .automatic)
        MainScreenChoice.save(.swapped, defaults)
        #expect(defaults.string(forKey: "display_main_screen") == "swapped")
        #expect(MainScreenChoice.load(defaults) == .swapped)
        #expect(MainScreenChoice.automatic.step(1) == .swapped && MainScreenChoice.automatic.step(-1) == .swapped)

        #expect(CompanionDim.load(defaults) == CompanionDim(enabled: true, minutes: 1))
        CompanionDim.saveEnabled(false, defaults)
        CompanionDim.saveMinutes(5, defaults)
        #expect(CompanionDim.load(defaults) == CompanionDim(enabled: false, minutes: 5))
        // An unknown delay is the default one
        CompanionDim.saveMinutes(7, defaults)
        #expect(CompanionDim.load(defaults).minutes == 1)
        defaults.set(3, forKey: CompanionDim.minutesKey)
        #expect(CompanionDim.load(defaults).minutes == 1)
    }

    @Test func dimmingWaitsForTheDelayAndNeverWhileOff() {
        #expect(CompanionDim.step(1, 1) == 2 && CompanionDim.step(10, 1) == 1 && CompanionDim.step(1, -1) == 10)
        let dim = CompanionDim(enabled: true, minutes: 2)
        #expect(dim.delay == 120)
        #expect(!dim.dimmed(sinceTouch: 119))
        #expect(dim.dimmed(sinceTouch: 120))
        #expect(CompanionDim(enabled: false, minutes: 1).delay == nil)
        #expect(!CompanionDim(enabled: false, minutes: 1).dimmed(sinceTouch: 10_000))
    }
}
