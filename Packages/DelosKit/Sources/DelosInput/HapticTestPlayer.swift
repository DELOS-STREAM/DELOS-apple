import Foundation
import GameController

/// The fixed host-motor inputs of the Debug laboratory (`RumblePattern` and `playRumblePattern` of DELOS for Android's
/// DebugInfoScreen.kt). Each step sends both host motors [Step.percent] and holds it for [Step.milliseconds]; the
/// stream's translation shapes them, including the start kick and smoothing. The raw values are Android's saved names.
public enum RumbleTestPattern: String, CaseIterable, Sendable {
    case test = "TEST", steady25 = "STEADY_25", steady50 = "STEADY_50", steady75 = "STEADY_75", steady100 = "STEADY_100"
    case ramp = "RAMP", tap30 = "TAP_30", tap60 = "TAP_60", tap100 = "TAP_100", heartbeat = "HEARTBEAT"
    case explosion = "EXPLOSION", flutter = "FLUTTER"

    public struct Step: Equatable, Sendable {
        public let percent: Int
        public let milliseconds: Int

        public init(percent: Int, milliseconds: Int) {
            self.percent = percent
            self.milliseconds = milliseconds
        }
    }

    public var steps: [Step] {
        func hold(_ percent: Int, _ milliseconds: Int) -> Step { Step(percent: percent, milliseconds: milliseconds) }
        func rise(by step: Int, holding milliseconds: Int) -> [Step] {
            stride(from: 0, through: 100, by: step).map { hold($0, milliseconds) }
        }
        func fall(by step: Int, holding milliseconds: Int) -> [Step] {
            stride(from: 100, through: 0, by: -step).map { hold($0, milliseconds) }
        }
        func repeated(_ count: Int, _ steps: [Step]) -> [Step] { Array(repeating: steps, count: count).flatMap { $0 } }
        switch self {
        case .test:
            return [hold(100, 60), hold(0, 180), hold(50, 1000), hold(0, 180)] + rise(by: 5, holding: 25) + [hold(0, 120)]
                + fall(by: 5, holding: 35)
        case .steady25: return [hold(25, 2000)]
        case .steady50: return [hold(50, 2000)]
        case .steady75: return [hold(75, 2000)]
        case .steady100: return [hold(100, 2000)]
        case .ramp: return rise(by: 2, holding: 40)
        case .tap30: return repeated(4, [hold(100, 30), hold(0, 250)])
        case .tap60: return repeated(4, [hold(100, 60), hold(0, 250)])
        case .tap100: return repeated(4, [hold(100, 100), hold(0, 250)])
        case .heartbeat: return repeated(4, [hold(100, 70), hold(0, 100), hold(100, 100), hold(0, 500)])
        case .explosion: return fall(by: 2, holding: 40)
        case .flutter: return repeated(20, [hold(100, 20), hold(0, 40)])
        }
    }

    /// The raw host-motor value of [percent], as Android computes it (`percent * 65535 / 100`).
    public static func raw(_ percent: Int) -> UInt16 { UInt16(percent * 65535 / 100) }
}

/// The vibration of the Debug laboratory. Every output is a ``ControllerHaptics``, so a pattern plays exactly as a stream's
/// rumble would (same translation, 16 ms kick and smoothing updates); the plain tests play a fixed amplitude on this
/// device's haptic engine or on a controller's.
@MainActor
public final class HapticTestPlayer {
    /// Plays the low motor's eight-bit amplitude unchanged: the plain tests' fixed strength (Android's one-shot and
    /// waveform at an amplitude, which bypass the translator).
    private static let direct: RumbleConfiguration = {
        var configuration = RumbleConfiguration()
        configuration.saveCustom(RumbleProfile(lowWeight: 1, highWeight: 0), translator: true)
        return configuration
    }()

    private var pattern: ControllerHaptics?
    private var device: ControllerHaptics?
    private var controllers: [ObjectIdentifier: ControllerHaptics] = [:]
    /// The end of a one-second test, per output.
    private var timers: [ObjectIdentifier: Task<Void, Never>] = [:]

    public init() {}

    isolated deinit { timers.values.forEach { $0.cancel() } }

    /// Whether [controller] has a motor the stream's rumble can play.
    public static func vibrates(_ controller: GCController) -> Bool { ControllerHaptics.capabilities(of: controller).rumble }

    /// The amplitude, 0...255, the running pattern's translation issues now.
    public var patternAmplitude: Int { pattern?.amplitude ?? 0 }

    /// Why the running pattern could not play as its profile asks.
    public var patternProblem: RumbleProblem? { pattern?.problem }

    /// Plays [pattern] through [profile] on this device's engine, replacing any pattern that plays; returns when it ends,
    /// when its task is cancelled or when another pattern or ``stopPattern()`` replaces it. The caller stops the output.
    public func play(_ pattern: RumbleTestPattern, profile: RumbleProfile) async {
        stopPattern()
        let output = ControllerHaptics()
        var configuration = RumbleConfiguration()
        configuration.saveCustom(profile, translator: true)
        output.configuration = configuration
        self.pattern = output
        for step in pattern.steps {
            guard self.pattern === output, !Task.isCancelled else { return }
            let raw = RumbleTestPattern.raw(step.percent)
            output.rumble(low: raw, high: raw, strength: 100)
            do { try await Task.sleep(for: .milliseconds(step.milliseconds)) } catch { return }
        }
    }

    public func stopPattern() {
        pattern?.stop()
        pattern = nil
    }

    /// One second at full strength on this device.
    public func vibrateDeviceOnce() { once(deviceOutput()) }

    /// Vibrates this device at [strength] (1...255) until ``stopDevice()``; a new strength takes over at once.
    public func vibrateDevice(strength: Int) { hold(deviceOutput(), strength: strength) }

    public func stopDevice() {
        guard let device else { return }
        cancelTimer(device)
        device.stop()
    }

    /// One second at full strength on [controller].
    public func vibrateOnce(_ controller: GCController) { once(output(for: controller)) }

    /// Vibrates every controller of [controllers] that can at [strength] (1...255) until ``stopControllers()``; the
    /// controllers no longer listed stop.
    public func vibrate(_ controllers: [GCController], strength: Int) {
        let listed = Set(controllers.map(ObjectIdentifier.init))
        for (key, output) in self.controllers where !listed.contains(key) {
            cancelTimer(output)
            output.stop()
            self.controllers[key] = nil
        }
        for controller in controllers where Self.vibrates(controller) { hold(output(for: controller), strength: strength) }
    }

    public func stopControllers() {
        for output in controllers.values {
            cancelTimer(output)
            output.stop()
        }
        controllers.removeAll()
    }

    public func stopAll() {
        stopPattern()
        stopDevice()
        stopControllers()
    }

    private func deviceOutput() -> ControllerHaptics {
        if let device { return device }
        let created = ControllerHaptics()
        created.configuration = Self.direct
        device = created
        return created
    }

    private func output(for controller: GCController) -> ControllerHaptics {
        let key = ObjectIdentifier(controller)
        if let output = controllers[key] { return output }
        let created = ControllerHaptics(controller: controller)
        created.configuration = Self.direct
        controllers[key] = created
        return created
    }

    private func hold(_ output: ControllerHaptics, strength: Int) {
        cancelTimer(output)
        let raw = UInt16(min(255, max(1, strength))) << 8
        output.rumble(low: raw, high: raw, strength: 100)
    }

    private func once(_ output: ControllerHaptics) {
        hold(output, strength: 255)
        let key = ObjectIdentifier(output)
        timers[key] = Task { [weak self, weak output] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            output?.rumble(low: 0, high: 0, strength: 100)
            self?.timers[key] = nil
        }
    }

    private func cancelTimer(_ output: ControllerHaptics) {
        timers.removeValue(forKey: ObjectIdentifier(output))?.cancel()
    }
}
