import DelosMedia
import Foundation
import SwiftUI

/// Android's full StreamStats panel. Technical units match Android; every phrase comes from its catalog.
struct StreamStatsOverlay: View {
    let statistics: StreamStatistics
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        let readings = rows
        VStack(alignment: .leading, spacing: stage.px(10)) {
            HStack(spacing: 0) {
                Text(verbatim: "\(statistics.width) × \(statistics.height) · ")
                Text(verbatim: "\(number(statistics.renderingFPS)) FPS")
                    .foregroundStyle(colors.accent2.color)
                Text(verbatim: " · \(statistics.codec)\(statistics.hdr ? " HDR" : "")")
            }
            .font(DelosFonts.figtree(stage.px(20), .semibold))
            Grid(alignment: .leading, horizontalSpacing: stage.px(24), verticalSpacing: 0) {
                ForEach(readings.indices, id: \.self) { index in
                    GridRow {
                        Text(readings[index].label).foregroundStyle(colors.text2.color)
                        Text(verbatim: readings[index].value).foregroundStyle(colors.text.color)
                    }
                    .frame(minHeight: stage.px(25.5), alignment: .leading)
                }
            }
            .font(DelosFonts.figtree(stage.px(17)))
        }
        .monospacedDigit()
        .foregroundStyle(colors.text.color)
        .padding(.horizontal, stage.px(22))
        .padding(.vertical, stage.px(16))
        .background {
            GlassShape(RoundedRectangle(cornerRadius: stage.px(18)), tint: colors.surface, role: .panel)
        }
        .overlay {
            RoundedRectangle(cornerRadius: stage.px(18)).stroke(colors.line.color, lineWidth: stage.px(1))
        }
        .fixedSize()
        .padding(.leading, stage.px(40 + stage.safe.leading))
        .padding(.trailing, stage.px(40 + stage.safe.trailing))
        .padding(.top, stage.px(32 + stage.safe.top))
        .padding(.bottom, stage.px(32 + stage.safe.bottom))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.glassOverMedia, true)
        .allowsHitTesting(false)
    }

    private var rows: [(label: String, value: String)] {
        var result = [(L("stream_stats_decoder"), "AVSampleBufferDisplayLayer")]
        result.append((L("stream_stats_incoming"), "\(number(statistics.incomingFPS)) FPS"))
        if let fps = statistics.renderingFPS {
            result.append((L("stream_stats_rendering"), "\(number(fps)) FPS"))
        }
        if let network = statistics.networkMilliseconds, let variance = statistics.networkVarianceMilliseconds {
            result.append((L("stream_stats_network"), "\(number(network, places: 0)) ms ± \(number(variance, places: 0)) ms"))
        }
        if let average = statistics.hostAverageMilliseconds,
           let minimum = statistics.hostMinimumMilliseconds, let maximum = statistics.hostMaximumMilliseconds {
            result.append((L("stream_stats_pc_processing"), "\(number(average)) ms (\(number(minimum))–\(number(maximum)))"))
        }
        if let delay = statistics.presentationDelayMilliseconds {
            result.append((L("stream_stats_render_latency"), "\(number(delay, places: 2)) ms"))
        }
        let kib = statistics.bandwidthKiBPerSecond
        let bytes = kib >= 1000 ? "\(number(kib / 1024)) MB/s" : "\(Int(kib)) KB/s"
        let mbps = kib * 1024 * 8 / 1_000_000
        result.append((L("stream_stats_bandwidth"), "\(bytes) · \(number(mbps, places: mbps >= 100 ? 0 : 1)) Mb/s"))
        if let loss = statistics.lostFramesPercent {
            result.append((L("stream_stats_lost_frames"), "\(number(loss, places: 2)) %"))
        }
        // AVSampleBufferVideoRenderer does not expose decoding time. Omit that line and total latency;
        // enqueue CPU duration and presentation lateness are not substitutes for decoder latency.
        return result
    }

    private func number(_ value: Double?, places: Int = 1) -> String {
        guard let value else { return "—" }
        return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), places, value)
    }
}
