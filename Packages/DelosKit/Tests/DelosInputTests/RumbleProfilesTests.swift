import Foundation
import Testing
@testable import DelosInput

struct RumbleProfilesTests {
    @Test func originalUsesLegacyMotorTruncationAndWeightedMix() {
        var state = RumbleChannel()
        #expect(state.motor(65535, profile: .init(), nowMilliseconds: 0) == 255)
        #expect(state.motor(255, profile: .init(), nowMilliseconds: 0) == 0)
        #expect(state.single(low: 32768, high: 16384, profile: .init(), nowMilliseconds: 0) == 123)
        #expect(state.single(low: 65535, high: 65535, profile: .init(), nowMilliseconds: 0) == 255)
    }

    @Test func softReducesWeakAndStrongRumble() {
        var state = RumbleChannel()
        #expect(state.motor(65535, profile: RumblePreset.soft.profile, nowMilliseconds: 0) == 178)
        #expect(state.motor(32768, profile: RumblePreset.soft.profile, nowMilliseconds: 0) == 72)
    }

    @Test func kickSettlesWithoutAnotherHostPacketAndZeroCancelsIt() {
        var state = RumbleChannel()
        let profile = RumblePreset.kickStart.profile
        #expect(state.motor(16384, profile: profile, nowMilliseconds: 100) == 255)
        #expect(state.nextUpdateMilliseconds(now: 150) == 50)
        #expect(state.motor(16384, profile: profile, nowMilliseconds: 200) == 64)
        #expect(state.nextUpdateMilliseconds(now: 200) == nil)
        #expect(state.motor(0, profile: profile, nowMilliseconds: 201) == 0)
        #expect(state.motor(16384, profile: profile, nowMilliseconds: 202) == 255)
        #expect(state.motor(0, profile: profile, nowMilliseconds: 203) == 0)
        #expect(state.nextUpdateMilliseconds(now: 203) == nil)
    }

    @Test func smoothingRetainsFractionalProgressAndNeverDelaysStop() {
        var state = RumbleChannel()
        let profile = RumbleProfile(smoothing: 1)
        #expect(state.motor(256, profile: profile, nowMilliseconds: 0) == 1)
        #expect(state.motor(65535, profile: profile, nowMilliseconds: 10) == 4)
        #expect(state.motor(65535, profile: profile, nowMilliseconds: 20) == 6)
        #expect(state.motor(0, profile: profile, nowMilliseconds: 21) == 0)
        #expect(state.nextUpdateMilliseconds(now: 21) == nil)
    }

    @Test func pulseHasFloorButZeroIsSilent() {
        var state = RumbleChannel()
        let profile = RumblePreset.pulsing.profile
        #expect(profile.pulseMilliseconds == 20)
        #expect(state.motor(1, profile: profile, nowMilliseconds: 0) == 50)
        #expect(state.motor(0, profile: profile, nowMilliseconds: 1) == 0)
    }

    @Test func deviceFallbackDoesNotDoubleRumbleOrUseOtherPlayers() throws {
        var configuration = RumbleConfiguration()
        configuration.deviceFallback = true
        #expect(configuration.usesDevice(controllerCanRumble: false, controllerNumber: 0))
        #expect(!configuration.usesDevice(controllerCanRumble: true, controllerNumber: 0))
        #expect(!configuration.usesDevice(controllerCanRumble: false, controllerNumber: 1))
        configuration.deviceEnabled = true
        #expect(configuration.usesDevice(controllerCanRumble: true, controllerNumber: 0))
        configuration.enabled = false
        #expect(!configuration.usesDevice(controllerCanRumble: false, controllerNumber: 0))
        let restored = try JSONDecoder().decode(RumbleConfiguration.self, from: Data(#"{"deviceStrength":999,"profile":"removed"}"#.utf8))
        #expect(restored.deviceStrength == 200)
        #expect(restored.profile == .original)
    }

    @Test func positionalAdaptiveEffectsDecodeIndependentZones() {
        let payload: [UInt8] = [5, 0, 0xC7, 0, 0, 0, 0, 0, 80, 0]
        guard case let .feedback(values) = AdaptiveTriggerEffect.decode(type: 0x21, payload: payload) else {
            Issue.record("Expected positional feedback"); return
        }
        #expect(values[0] == 1)
        #expect(values[1] == 0)
        #expect(values[2] == 0.5)
        #expect(AdaptiveTriggerEffect.decode(type: 0x26, payload: payload) == .vibration(values, frequency: 80))
    }

    @Test func malformedAndUnsupportedAdaptiveEffectsDoNotBecomeResistance() {
        #expect(AdaptiveTriggerEffect.decode(type: 0x21, payload: [1]) == nil)
        #expect(AdaptiveTriggerEffect.decode(type: 0x27, payload: Array(repeating: 0, count: 10)) == nil)
        #expect(AdaptiveTriggerEffect.decode(type: 5, payload: []) == .off)
        #expect(AdaptiveTriggerEffect.decode(type: 0x25, payload: [0x84, 0, 7, 0, 0, 0, 0, 0, 0, 0])
            == .weapon(start: Float(2) / 9, end: Float(7) / 9, strength: 1))
        #expect(AdaptiveTriggerEffect.decode(type: 0x25, payload: [4, 0, 7, 0, 0, 0, 0, 0, 0, 0]) == nil)
    }
}
