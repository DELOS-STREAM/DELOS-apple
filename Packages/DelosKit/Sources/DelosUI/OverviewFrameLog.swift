#if DEBUG && canImport(UIKit)
import OSLog
import QuartzCore
import UIKit

/// DEBUG only: the frame times of the overview's opening and closing, logged under the category `OverviewMotion` when
/// the flight lands (frames, mean and 95th percentile interval, the longest, and the frames that took over 1.5 times
/// the display's frame), with a trace of the flight: its progress as each frame drew it, the steps of the closing
/// ([mark]) and every long frame, in milliseconds from the start. Read them with
/// `log show --predicate 'category == "OverviewMotion"'`.
@MainActor
final class OverviewFrameLog: NSObject {
    static let shared = OverviewFrameLog()
    private static let logger = Logger(subsystem: "io.github.meitoncz.delos", category: "OverviewMotion")
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var started: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var trace: [String] = []
    private var lastProgress = Double.nan
    private var label = ""

    func start(_ label: String) {
        stop()
        self.label = label
        intervals.removeAll(keepingCapacity: true)
        trace.removeAll(keepingCapacity: true)
        lastProgress = .nan
        last = 0
        started = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// The flight drew its cover at [progress] (noted when it changed).
    func progress(_ progress: Double) {
        guard link != nil, progress != lastProgress else { return }
        lastProgress = progress
        note(String(format: "f=%.3f", progress))
    }

    /// A step of the motion happened now.
    func mark(_ step: String) {
        note(step)
    }

    private func note(_ text: String) {
        guard link != nil else { return }
        trace.append("\(Int((CACurrentMediaTime() - started) * 1000)):\(text)")
    }

    func stop() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        for chunk in stride(from: 0, to: trace.count, by: 24) {
            let line = trace[chunk..<min(chunk + 24, trace.count)].joined(separator: " ")
            Self.logger.notice("\(self.label, privacy: .public) trace \(line, privacy: .public)")
        }
        let frame = 1000 / Double(max(UIScreen.main.maximumFramesPerSecond, 1))
        guard !intervals.isEmpty else { return }
        let sorted = intervals.sorted()
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let hitches = intervals.filter { $0 > frame * 1.5 }.count
        Self.logger.notice("""
            \(self.label, privacy: .public) frames=\(self.intervals.count) mean=\(mean, format: .fixed(precision: 2))ms \
            p95=\(p95, format: .fixed(precision: 2))ms max=\(sorted.last ?? 0, format: .fixed(precision: 2))ms \
            hitches=\(hitches) target=\(frame, format: .fixed(precision: 2))ms
            """)
    }

    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 {
            let interval = (link.timestamp - last) * 1000
            intervals.append(interval)
            let frame = 1000 / Double(max(UIScreen.main.maximumFramesPerSecond, 1))
            if interval > frame * 1.5 { note(String(format: "long=%.0fms", interval)) }
        }
        last = link.timestamp
    }
}
#endif
