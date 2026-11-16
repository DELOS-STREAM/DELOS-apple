import Foundation

/// Lets the app leave a running stream before it quits (the Mac: Command-Q, or closing the window, which quits the
/// app). A stream screen registers how it leaves while it is shown; the app's termination handler calls ``leaveAll``
/// and quits once the streams are closed, or after a time-out, so a stuck connection cannot keep the app open.
@MainActor
public final class StreamShutdown {
    public static let shared = StreamShutdown()

    private var leavers: [UUID: @MainActor () async -> Void] = [:]

    public init() {}

    /// Whether a stream is shown, which the app has to close before it quits.
    public var hasStream: Bool { !leavers.isEmpty }

    /// Registers how the stream screen leaves; returns the token to give back to ``unregister(_:)``.
    func register(_ leave: @escaping @MainActor () async -> Void) -> UUID {
        let id = UUID()
        leavers[id] = leave
        return id
    }

    func unregister(_ id: UUID) {
        leavers[id] = nil
    }

    /// Leaves every registered stream (Disconnect: the game keeps running on the PC); returns when they have, or after
    /// `timeout`.
    public func leaveAll(timeout: Duration = .seconds(5)) async {
        let all = Array(leavers.values)
        guard !all.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = Gate(continuation)
            Task { @MainActor in
                for leave in all { await leave() }
                gate.open()
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                gate.open()
            }
        }
    }

    /// Resumes its continuation once, for whichever of the leaving and the time-out ends first.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }
}
