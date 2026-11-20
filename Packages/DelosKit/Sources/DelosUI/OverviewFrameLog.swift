#if DEBUG && canImport(UIKit)
import OSLog
import QuartzCore
import UIKit

/// DEBUG only: the frame times of the overview's opening and closing, logged under the category `OverviewMotion` when
/// the flight lands (frames, mean and 95th percentile interval, the longest, and the frames that took over 1.5 times
/// the display's frame). Read them with `log show --predicate 'category == "OverviewMotion"'`.
@MainActor
final class OverviewFrameLog: NSObject {
    static let shared = OverviewFrameLog()
    private static let logger = Logger(subsystem: "io.github.meitoncz.delos", category: "OverviewMotion")
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var label = ""

    func start(_ label: String) {
        stop()
        self.label = label
        intervals.removeAll(keepingCapacity: true)
        last = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
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
        if last > 0 { intervals.append((link.timestamp - last) * 1000) }
        last = link.timestamp
    }
}
#endif
