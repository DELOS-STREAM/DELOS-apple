import Foundation
import Testing
@testable import DelosInput

struct RumbleLabTests {
    private typealias Step = RumbleTestPattern.Step

    private func steps(_ pairs: [(Int, Int)]) -> [Step] { pairs.map { Step(percent: $0.0, milliseconds: $0.1) } }

    @Test func testSampleIsTapSteadyRampAndDecay() {
        let expected = steps([(100, 60), (0, 180), (50, 1000), (0, 180)])
            + stride(from: 0, through: 100, by: 5).map { Step(percent: $0, milliseconds: 25) }
            + [Step(percent: 0, milliseconds: 120)]
            + stride(from: 100, through: 0, by: -5).map { Step(percent: $0, milliseconds: 35) }
        #expect(RumbleTestPattern.test.steps == expected)
        #expect(RumbleTestPattern.test.steps.count == 47)
        #expect(RumbleTestPattern.test.steps.map(\.milliseconds).reduce(0, +) == 2800)
    }

    @Test func steadyPatternsHoldTwoSeconds() {
        #expect(RumbleTestPattern.steady25.steps == steps([(25, 2000)]))
        #expect(RumbleTestPattern.steady50.steps == steps([(50, 2000)]))
        #expect(RumbleTestPattern.steady75.steps == steps([(75, 2000)]))
        #expect(RumbleTestPattern.steady100.steps == steps([(100, 2000)]))
    }

    @Test func rampAndExplosionStepByTwoPercentEvery40Milliseconds() {
        let ramp = RumbleTestPattern.ramp.steps
        #expect(ramp.count == 51)
        #expect(ramp.first == Step(percent: 0, milliseconds: 40))
        #expect(ramp.last == Step(percent: 100, milliseconds: 40))
        #expect(ramp.allSatisfy { $0.milliseconds == 40 && $0.percent % 2 == 0 })
        #expect(RumbleTestPattern.explosion.steps == Array(ramp.reversed()))
    }

    @Test func tapsHeartbeatAndFlutterRepeat() {
        #expect(RumbleTestPattern.tap30.steps == Array(repeating: steps([(100, 30), (0, 250)]), count: 4).flatMap { $0 })
        #expect(RumbleTestPattern.tap60.steps == Array(repeating: steps([(100, 60), (0, 250)]), count: 4).flatMap { $0 })
        #expect(RumbleTestPattern.tap100.steps == Array(repeating: steps([(100, 100), (0, 250)]), count: 4).flatMap { $0 })
        #expect(RumbleTestPattern.heartbeat.steps
            == Array(repeating: steps([(100, 70), (0, 100), (100, 100), (0, 500)]), count: 4).flatMap { $0 })
        #expect(RumbleTestPattern.flutter.steps == Array(repeating: steps([(100, 20), (0, 40)]), count: 20).flatMap { $0 })
    }

    @Test func rawValuesMatchTheHostMotorScale() {
        #expect(RumbleTestPattern.raw(0) == 0)
        #expect(RumbleTestPattern.raw(25) == 16383)
        #expect(RumbleTestPattern.raw(50) == 32767)
        #expect(RumbleTestPattern.raw(100) == 65535)
    }

    @Test func presetsAreActiveUntilAnAdvancedEditMakesCustom() {
        var configuration = RumbleConfiguration()
        #expect(configuration.activePreset == .original)
        #expect(!configuration.translatorEnabled)
        configuration.applyPreset(.kickStart)
        #expect(configuration.activePreset == .kickStart)
        #expect(configuration.translatorEnabled)
        #expect(configuration.translation == RumblePreset.kickStart.profile)
        // An edit is Custom even when its values equal a preset's
        configuration.saveCustom(RumblePreset.soft.profile, translator: true)
        #expect(configuration.activePreset == nil)
        #expect(configuration.translation == RumblePreset.soft.profile)
        configuration.saveCustom(RumbleProfile(gain: 2), translator: false)
        #expect(configuration.savedProfile == RumbleProfile(gain: 2))
        #expect(configuration.translation == RumbleProfile())
        configuration.applyPreset(.pulsing)
        #expect(configuration.custom == nil)
        #expect(configuration.activePreset == .pulsing)
    }

    @Test func customRoundTripsAndOldDataLoadsAsPreset() throws {
        var configuration = RumbleConfiguration()
        configuration.applyPreset(.pulsing)
        configuration.saveCustom(RumbleProfile(gain: 1.5, curve: 0.75, minimumAmplitude: 12, kickMilliseconds: 40, lowWeight: 0.5,
                                               highWeight: 0.25, smoothing: 0.3, pulseMilliseconds: 20), translator: true)
        let restored = try JSONDecoder().decode(RumbleConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(restored == configuration)
        #expect(restored.activePreset == nil)

        let old = try JSONDecoder().decode(RumbleConfiguration.self, from: Data(#"{"enabled":true,"profile":"KICK_ONLY"}"#.utf8))
        #expect(old.custom == nil)
        #expect(old.activePreset == .kickStart)
        #expect(old.translation == RumblePreset.kickStart.profile)

        let partial = try JSONDecoder().decode(RumbleConfiguration.self,
            from: Data(#"{"custom":{"translator":true,"profile":{"gain":2}}}"#.utf8))
        #expect(partial.custom == RumbleCustom(profile: RumbleProfile(gain: 2), translator: true))

        let malformed = try JSONDecoder().decode(RumbleConfiguration.self, from: Data(#"{"profile":"GENTLE","custom":5}"#.utf8))
        #expect(malformed.activePreset == .soft)
    }
}
