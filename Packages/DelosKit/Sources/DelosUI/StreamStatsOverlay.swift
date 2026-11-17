import DelosData
import DelosMedia
import Foundation
import SwiftUI

/// Android's statistics overlay (`StreamStatsPanel`): the full panel in the top left corner, or the compact line at the top
/// center. Technical units match Android; every phrase comes from its catalog.
struct StreamStatsOverlay: View {
    let statistics: StreamStatistics
    let overlay: StatisticsOverlay
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        switch overlay {
        case .off: EmptyView()
        case .full: fullPanel
        case .compact: compactLine
        }
    }

    /// The compact line: one capsule of text at the top center (`CompactLine`): 18 px text, 24 px beside it and 8 px
    /// above and below, 20 px under the top of the stage. A compact stage may break it in two balanced, centered lines, only after a
    /// separator.
    private var compactLine: some View {
        let wraps = stage.compact
        let line = StatisticsLine.text(statistics, tail: L("stream_stats_compact_tail"))
        let shape = Capsule()
        return Text(verbatim: wraps ? StatisticsLine.keepingFiguresTogether(line) : line)
            .font(DelosFonts.figtree(stage.tpx(StreamMenuLayout.statsCompactTextSize)))
            .lineSpacing(stage.tpx(StreamMenuLayout.statsCompactTextSize) * (StreamMenuLayout.statsCompactLineHeight - 1.2))
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .foregroundStyle(colors.text.color)
            .padding(.horizontal, stage.px(24))
            .padding(.vertical, stage.px(StreamMenuLayout.statsCompactPaddingY))
            .background { GlassShape(shape, tint: colors.surface, role: .panel) }
            .overlay { shape.stroke(colors.line.color, lineWidth: stage.px(1)) }
            .padding(.horizontal, stage.px(40 + max(stage.safe.leading, stage.safe.trailing)))
            .padding(.top, stage.px(StreamMenuLayout.statsCompactTop + stage.safe.top))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.glassOverMedia, true)
            .allowsHitTesting(false)
    }

    @ViewBuilder private var fullPanel: some View {
        let readings = rows
        VStack(alignment: .leading, spacing: stage.px(10)) {
            HStack(spacing: 0) {
                Text(verbatim: "\(statistics.width) × \(statistics.height) · ")
                Text(verbatim: "\(number(statistics.renderingFPS)) FPS")
                    .foregroundStyle(colors.accent2.color)
                Text(verbatim: " · \(statistics.codec)\(statistics.hdr ? " HDR" : "")")
            }
            .font(DelosFonts.figtree(stage.tpx(20), .semibold))
            Grid(alignment: .leading, horizontalSpacing: stage.px(24), verticalSpacing: 0) {
                ForEach(readings.indices, id: \.self) { index in
                    GridRow {
                        Text(readings[index].label).foregroundStyle(colors.text2.color)
                        Text(verbatim: readings[index].value).foregroundStyle(colors.text.color)
                    }
                    .frame(minHeight: stage.px(25.5), alignment: .leading)
                }
            }
            .font(DelosFonts.figtree(stage.tpx(17)))
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
        var result = [(L("stream_stats_decoder"), statistics.renderer)]
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
        if let decoding = statistics.decodingText {
            result.append((L("stream_stats_decoding"), decoding))
        }
        if let queue = statistics.frameQueueText {
            result.append((L("stream_stats_frame_queue"), queue))
        }
        if let delay = statistics.presentationDelayMilliseconds {
            result.append((L("stream_stats_render_latency"), "\(number(delay, places: 2)) ms"))
        }
        result.append((L("stream_stats_bandwidth"), StatisticsLine.bandwidth(kibPerSecond: statistics.bandwidthKiBPerSecond)))
        if let loss = statistics.lostFramesPercent {
            result.append((L("stream_stats_lost_frames"), "\(number(loss, places: 2)) %"))
        }
        // Total latency is left out: neither renderer reports it. The renderer's own readings (decode time per picture,
        // queue, skipped, repeated and late frames) are only what the Metal renderer measures itself.
        return result
    }

    private func number(_ value: Double?, places: Int = 1) -> String {
        guard let value else { return "—" }
        return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), places, value)
    }
}
