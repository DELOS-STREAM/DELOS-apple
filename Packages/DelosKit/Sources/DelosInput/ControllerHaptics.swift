import CoreHaptics
import GameController

/// The rumble motors of one game controller, driven by the host's rumble requests (as Moonlight for iOS's
/// `HapticContext`): the low-frequency motor is the left handle, the high-frequency motor the right handle, and the
/// trigger motors the triggers. Each motor is a CoreHaptics engine of the controller playing one endless continuous
/// event whose intensity follows the host's amplitude; amplitude 0 stops it.
@MainActor
final class ControllerHaptics {
    private let controller: GCController
    private var motors: [GCHapticsLocality: Motor] = [:]

    init(controller: GCController) {
        self.controller = controller
    }

    /// Whether the controller has the motors for rumble and for trigger rumble.
    static func capabilities(of controller: GCController) -> (rumble: Bool, triggers: Bool) {
        let localities = controller.haptics?.supportedLocalities ?? []
        return (localities.contains(.handles), localities.contains(.triggers))
    }

    func rumble(low: UInt16, high: UInt16) {
        motor(.leftHandle)?.set(amplitude: low)
        motor(.rightHandle)?.set(amplitude: high)
    }

    func rumbleTriggers(left: UInt16, right: UInt16) {
        motor(.leftTrigger)?.set(amplitude: left)
        motor(.rightTrigger)?.set(amplitude: right)
    }

    func stop() {
        motors.values.forEach { $0.stop() }
        motors.removeAll()
    }

    private func motor(_ locality: GCHapticsLocality) -> Motor? {
        if let motor = motors[locality] { return motor }
        guard let haptics = controller.haptics, haptics.supportedLocalities.contains(locality),
              let engine = haptics.createEngine(withLocality: locality) else { return nil }
        let motor = Motor(engine: engine)
        motors[locality] = motor
        return motor
    }

    @MainActor
    private final class Motor {
        private let engine: CHHapticEngine
        private var player: (any CHHapticAdvancedPatternPlayer)?
        private var playing = false

        init(engine: CHHapticEngine) {
            self.engine = engine
            // The engine stops when the app goes to the background; the next amplitude starts it again
            engine.stoppedHandler = { [weak self] _ in
                Task { @MainActor in self?.reset() }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in self?.reset() }
            }
        }

        private func reset() {
            player = nil
            playing = false
        }

        func set(amplitude: UInt16) {
            if amplitude == 0 {
                if playing { try? player?.stop(atTime: CHHapticTimeImmediate) }
                playing = false
                return
            }
            do {
                if player == nil {
                    try engine.start()
                    // Intensity 1: the dynamic intensity below is multiplied by it
                    let event = CHHapticEvent(
                        eventType: .hapticContinuous,
                        parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)],
                        relativeTime: 0, duration: TimeInterval(GCHapticDurationInfinite))
                    player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
                }
                let intensity = CHHapticDynamicParameter(
                    parameterID: .hapticIntensityControl, value: Float(amplitude) / 65535, relativeTime: 0)
                try player?.sendParameters([intensity], atTime: CHHapticTimeImmediate)
                if !playing {
                    try player?.start(atTime: CHHapticTimeImmediate)
                    playing = true
                }
            } catch {
                // This request is lost; the next one starts the engine and the player again
                reset()
            }
        }

        func stop() {
            try? player?.stop(atTime: CHHapticTimeImmediate)
            engine.stop()
            player = nil
            playing = false
        }
    }
}
