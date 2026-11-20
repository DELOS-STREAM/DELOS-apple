import Foundation
import OSLog

/// Debug builds only: how fast animated artwork really plays, read from a device's console (issue #15). Once a second
/// each playing animation logs one line as a notice of the subsystem `io.github.meitoncz.delos`, category `ArtFPS`:
///
///     ArtFPS sgdb/<pc>/<app>/hero#2 420x336 shown=24.0/s file=24.0/s waited=0 dec=8.1/9.0ms n=24
///
/// - the animation's ``AnimatedSource/key`` (the passes of a game background, which overlap in their cross-fade, count
///   together) and the size its frames are drawn at;
/// - `shown`: new frames drawn a second; `file`: the rate the file's own timing has (its frames over one pass);
/// - `waited`: display frames at which the next frame was due but not decoded yet (decoding holds the animation back);
/// - `dec`: mean and longest milliseconds from asking for a frame to having it on the main actor (decoded, rendered for a
///   game background, and handed back), and how many frames that was.
///
/// On a Mac that sees the device (Console.app with the device selected shows the same lines):
///
///     log stream --level info --predicate 'subsystem == "io.github.meitoncz.delos" && category == "ArtFPS"'
///
/// Release builds compile it to nothing.
@MainActor enum ArtFPS {
    #if DEBUG
    private static let logger = Logger(subsystem: "io.github.meitoncz.delos", category: "ArtFPS")

    private struct Meter {
        var start: Double
        var last: Double
        var shown = 0
        var waited = 0
        var decodes: [Double] = []
    }

    private static var meters: [String: Meter] = [:]
    #endif

    /// A display frame of the animation [label] at [now] (ms): [shown] a new frame, or [waited] for the due one's decoding.
    /// [width] × [height]: the size its frames are drawn at; [fileRate]: frames a second by its file. The line is logged
    /// once a second; after a pause (no display frame for a second) the count starts again.
    static func drew(_ label: String, at now: Double, shown: Bool, waited: Bool, width: Int, height: Int, fileRate: Double) {
        #if DEBUG
        var meter = meters[label].flatMap { now - $0.last < 1000 ? $0 : nil } ?? Meter(start: now, last: now)
        meter.last = now
        if shown { meter.shown += 1 }
        if waited { meter.waited += 1 }
        let elapsed = now - meter.start
        if elapsed >= 1000 {
            let rate = Double(meter.shown) * 1000 / elapsed
            let mean = meter.decodes.isEmpty ? 0 : meter.decodes.reduce(0, +) / Double(meter.decodes.count)
            let line = String(format: "ArtFPS %@ %dx%d shown=%.1f/s file=%.1f/s waited=%d dec=%.1f/%.1fms n=%d", label, width, height,
                              rate, fileRate, meter.waited, mean, meter.decodes.max() ?? 0, meter.decodes.count)
            logger.notice("\(line, privacy: .public)")
            meter = Meter(start: now, last: now)
        }
        meters[label] = meter
        #endif
    }

    /// A frame of the animation [label] arrived on the main actor [millis] after it was asked for.
    static func decoded(_ label: String, millis: Double) {
        #if DEBUG
        meters[label]?.decodes.append(millis)
        #endif
    }
}
