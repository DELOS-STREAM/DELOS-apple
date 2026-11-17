import CoreHaptics
import Foundation
import GameController
import OSLog

/// Owns one physical controller, or the device's Taptic engine. No timer runs for steady amplitude or idle outputs.
@MainActor
final class ControllerHaptics {
    private static let logger = Logger(subsystem: "io.github.meitoncz.delos", category: "Rumble")
    private let controller: GCController?
    private var motors: [GCHapticsLocality: Motor] = [:]
    private var last = (low: UInt16(0), high: UInt16(0), left: UInt16(0), right: UInt16(0))
    private(set) var problem: RumbleProblem?
    private(set) var adaptiveTriggerUnsupported = false
    var configuration = RumbleConfiguration() {
        didSet {
            guard configuration != oldValue else { return }
            let saved = last
            stop()
            if configuration.enabled {
                rumble(low: saved.low, high: saved.high)
                rumbleTriggers(left: saved.left, right: saved.right)
            }
        }
    }

    init(controller: GCController? = nil) { self.controller = controller }

    static var deviceAvailable: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    static func capabilities(of controller: GCController) -> (rumble: Bool, triggers: Bool) {
        let localities = controller.haptics?.supportedLocalities ?? []
        let handles = localities.contains(.handles) || localities.contains(.all)
            || localities.contains(.leftHandle) || localities.contains(.rightHandle)
        let triggers = localities.contains(.triggers)
            || localities.contains(.leftTrigger) || localities.contains(.rightTrigger)
        return (handles, triggers)
    }

    /// [strength]: the device's strength in percent instead of the configured one (the on-screen controls' rumble is full).
    func rumble(low: UInt16, high: UInt16, strength: Int? = nil) {
        last.low = low
        last.high = high
        guard configuration.enabled else { return }
        if controller == nil {
            motor(.all, active: low != 0 || high != 0)?.set(
                low: low, high: high, profile: configuration.profile.profile, strength: strength ?? configuration.deviceStrength)
        } else if controller?.haptics?.supportedLocalities.contains(.leftHandle) == true
                    && controller?.haptics?.supportedLocalities.contains(.rightHandle) == true {
            motor(.leftHandle, active: low != 0)?.set(low: low, profile: configuration.profile.profile)
            motor(.rightHandle, active: high != 0)?.set(low: high, profile: configuration.profile.profile)
        } else {
            let locality: GCHapticsLocality = controller?.haptics?.supportedLocalities.contains(.handles) == true ? .handles : .all
            motor(locality, active: low != 0 || high != 0)?.set(low: low, high: high, profile: configuration.profile.profile)
        }
    }

    func rumbleTriggers(left: UInt16, right: UInt16) {
        last.left = left
        last.right = right
        guard configuration.enabled, controller != nil else { return }
        motor(.leftTrigger, active: left != 0)?.set(low: left, profile: configuration.profile.profile)
        motor(.rightTrigger, active: right != 0)?.set(low: right, profile: configuration.profile.profile)
    }

    func adaptiveTriggers(flags: UInt8, typeLeft: UInt8, typeRight: UInt8, left: [UInt8], right: [UInt8]) {
        guard let pad = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
        guard configuration.enabled, configuration.adaptiveTriggers else {
            pad.leftTrigger.setModeOff()
            pad.rightTrigger.setModeOff()
            return
        }
        if flags & 0x08 != 0 { apply(type: typeLeft, payload: left, to: pad.leftTrigger) }
        if flags & 0x04 != 0 { apply(type: typeRight, payload: right, to: pad.rightTrigger) }
    }

    private func apply(type: UInt8, payload: [UInt8], to trigger: GCDualSenseAdaptiveTrigger) {
        guard let effect = AdaptiveTriggerEffect.decode(type: type, payload: payload) else {
            adaptiveTriggerUnsupported = true
            trigger.setModeOff()
            Self.logger.warning("Unsupported or malformed adaptive trigger effect: \(type)")
            return
        }
        effect.apply(to: trigger)
    }

    func stop() {
        motors.values.forEach { $0.stop() }
        motors.removeAll()
        last = (0, 0, 0, 0)
        if let pad = controller?.extendedGamepad as? GCDualSenseGamepad {
            pad.leftTrigger.setModeOff()
            pad.rightTrigger.setModeOff()
        }
    }

    private func motor(_ locality: GCHapticsLocality, active: Bool) -> Motor? {
        if let motor = motors[locality] { return motor }
        guard active else { return nil }
        let engine: CHHapticEngine
        if let controller {
            guard let haptics = controller.haptics, haptics.supportedLocalities.contains(locality),
                  let created = haptics.createEngine(withLocality: locality) else { return nil }
            engine = created
        } else {
            guard Self.deviceAvailable else { problem = .noAmplitudeControl; return nil }
            do {
                engine = try CHHapticEngine()
                engine.playsHapticsOnly = true
            } catch {
                problem = .failed(error.localizedDescription)
                Self.logger.error("Device haptic engine creation failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        let motor = Motor(engine: engine) { [weak self] in self?.problem = .failed($0) }
        motors[locality] = motor
        return motor
    }

    @MainActor
    private final class Motor {
        private let engine: CHHapticEngine
        private let failed: @MainActor (String) -> Void
        private var player: (any CHHapticAdvancedPatternPlayer)?
        private var playing = false
        private var state = RumbleChannel()
        private var profile = RumbleProfile()
        private var low: UInt16 = 0
        private var high: UInt16?
        private var strength = 100
        private var issued = -1
        private var tick: Task<Void, Never>?
        private var pulseFailed = false

        init(engine: CHHapticEngine, failed: @escaping @MainActor (String) -> Void) {
            self.engine = engine
            self.failed = failed
            engine.stoppedHandler = { [weak self] _ in Task { @MainActor in self?.reset() } }
            engine.resetHandler = { [weak self] in Task { @MainActor in self?.reset() } }
        }

        private func reset() {
            tick?.cancel()
            tick = nil
            player = nil
            playing = false
            issued = -1
            state.reset()
        }

        func set(low: UInt16, high: UInt16? = nil, profile: RumbleProfile, strength: Int = 100) {
            if profile != self.profile { stop(); self.profile = profile; pulseFailed = false }
            self.low = low
            self.high = high
            self.strength = strength
            update()
        }

        private func update() {
            tick?.cancel()
            tick = nil
            let now = ProcessInfo.processInfo.systemUptime * 1000
            let output: Int
            if let high { output = state.single(low: low, high: high, profile: profile, nowMilliseconds: now) }
            else { output = state.motor(low, profile: profile, nowMilliseconds: now) }
            issue(min(255, output * strength / 100))
            if let delay = state.nextUpdateMilliseconds(now: now) {
                tick = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.update()
                }
            }
        }

        private func issue(_ amplitude: Int) {
            guard amplitude != issued else { return }
            do {
                if amplitude == 0 {
                    if playing { try player?.stop(atTime: CHHapticTimeImmediate) }
                    playing = false
                    issued = 0
                    return
                }
                if player == nil {
                    try engine.start()
                    let pulse = pulseFailed ? 0 : profile.pulseMilliseconds / 1000
                    let event = CHHapticEvent(eventType: .hapticContinuous,
                        parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)],
                        relativeTime: 0, duration: pulse > 0 ? pulse : 30)
                    let created = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
                    created.loopEnabled = true
                    created.loopEnd = pulse > 0 ? pulse * 2 : 30
                    player = created
                }
                try player?.sendParameters([CHHapticDynamicParameter(
                    parameterID: .hapticIntensityControl, value: Float(amplitude) / 255, relativeTime: 0)],
                    atTime: CHHapticTimeImmediate)
                if !playing { try player?.start(atTime: CHHapticTimeImmediate); playing = true }
                issued = amplitude
            } catch {
                ControllerHaptics.logger.error("Haptic playback failed: \(error.localizedDescription, privacy: .public)")
                failed(error.localizedDescription)
                reset()
                if profile.pulseMilliseconds > 0 && !pulseFailed {
                    pulseFailed = true
                    issue(amplitude)
                }
            }
        }

        func stop() {
            tick?.cancel()
            if playing {
                do { try player?.stop(atTime: CHHapticTimeImmediate) }
                catch { ControllerHaptics.logger.error("Haptic stop failed: \(error.localizedDescription, privacy: .public)"); failed(error.localizedDescription) }
            }
            engine.stop()
            reset()
        }
    }
}
