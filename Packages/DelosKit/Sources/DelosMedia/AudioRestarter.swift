import Synchronization

/// Decides when the audio engine is started again after the system stopped it: a route or device change (headphones,
/// AirPods, an HDMI sink), a call, Siri or another interruption. The engine is touched only through the two closures, so
/// the rules are testable without a device.
final class AudioRestarter: Sendable {
    enum Event: Sendable, Equatable {
        /// `AVAudioEngineConfigurationChange`: the engine stopped because the hardware format changed.
        case configurationChange
        /// `AVAudioSession.routeChangeNotification`.
        case routeChange
        case interruptionBegan
        case interruptionEnded
    }

    private struct State {
        var wanted = false
        var interrupted = false
    }

    private let state = Mutex(State())
    private let isRunning: @Sendable () -> Bool
    private let restart: @Sendable () -> Bool

    /// - Parameters:
    ///   - isRunning: whether the engine runs now.
    ///   - restart: starts it; true when it runs.
    init(isRunning: @escaping @Sendable () -> Bool, restart: @escaping @Sendable () -> Bool) {
        self.isRunning = isRunning
        self.restart = restart
    }

    /// The stream wants sound (`start`) or no longer does (`stop`, `cleanup`): events after a stop never start it.
    func setWanted(_ wanted: Bool) {
        state.withLock {
            $0.wanted = wanted
            if !wanted { $0.interrupted = false }
        }
    }

    /// Reacts to [event]; returns true when it started the engine again.
    @discardableResult
    func handle(_ event: Event) -> Bool {
        let proceed = state.withLock { state -> Bool in
            switch event {
            case .interruptionBegan:
                state.interrupted = true
                return false
            case .interruptionEnded:
                state.interrupted = false
            case .configurationChange, .routeChange:
                // The engine cannot start while the call lasts; the end of the interruption starts it.
                if state.interrupted { return false }
            }
            return state.wanted
        }
        guard proceed, !isRunning() else { return false }
        return restart()
    }
}
