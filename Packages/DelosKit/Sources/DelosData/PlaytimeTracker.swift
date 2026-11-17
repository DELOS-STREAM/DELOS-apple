import Foundation

/// Accumulates the time one stream is actually connected (`PlaytimeTracker` of DELOS for Android). Pure logic: `clock`
/// is a monotonic time in seconds and `sink` receives every elapsed slice as it is flushed, so the stored total is
/// always the sum of the slices written so far. Nothing is open between flushes: a crash or kill loses at most the
/// time since the last ``flush()``, and a restart can neither lose nor double count anything. Main actor only.
@MainActor
public final class PlaytimeTracker {
    private let clock: () -> Double
    private let sink: (Double) -> Void
    private var mark: Double?

    /// - Parameters:
    ///   - clock: monotonic seconds .
    ///   - sink: called with each slice in seconds, e.g. adding it to a ``PlaytimeStore``.
    public init(clock: @escaping () -> Double = PlaytimeTracker.systemClock, sink: @escaping (Double) -> Void) {
        self.clock = clock
        self.sink = sink
    }

    /// Whether time is counting now.
    public var running: Bool { mark != nil }

    /// The stream is connected: time counts from now. A call while it counts changes nothing.
    public func start() {
        if mark == nil { mark = clock() }
    }

    /// Writes the time since the last flush; call about every 30 s while streaming.
    public func flush() {
        guard let last = mark else { return }
        let now = clock()
        mark = now
        let delta = now - last
        if delta > 0 { sink(delta) }
    }

    /// The stream ended, was dropped or was suspended: the rest is written and counting stops until ``start()``.
    public func end() {
        flush()
        mark = nil
    }

    /// Seconds of a monotonic clock (system uptime).
    public nonisolated static func systemClock() -> Double { ProcessInfo.processInfo.systemUptime }
}
