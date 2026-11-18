import DelosCore
import DelosData
import DelosMedia
import Foundation
import SwiftUI

/// Android's statistics overlay (`StreamStatsPanel`, StreamStats.kt:196-293): the full panel in the profile's corner
/// (`ui_stats_position`), or the compact line at the top center. Technical units match Android; every phrase comes from its
/// catalog. The frame rate is Android's green (`FPS_GREEN`).
struct StreamStatsOverlay: View {
    let statistics: StreamStatistics
    let overlay: StatisticsOverlay
    var position = StatsPosition.topLeft
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    /// The frame rate's colour in both forms (`FPS_GREEN`, StreamStats.kt:322).
    static let fpsGreen = RGBA(red: 0x7E / 255, green: 0xE2 / 255, blue: 0xA8 / 255)

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
        let head = StatisticsLine.head(statistics)
        let rest = StatisticsLine.rest(statistics, tail: L("stream_stats_compact_tail"), low: L("stream_stats_compact_low"))
        let shape = Capsule()
        func figures(_ text: String) -> String { wraps ? StatisticsLine.keepingFiguresTogether(text) : text }
        return (Text(verbatim: figures(head)).foregroundStyle(Self.fpsGreen.color).fontWeight(.semibold) + Text(verbatim: figures(rest)))
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
                Text(verbatim: "\(number(statistics.renderingFPS)) FPS" + (statistics.vrr ? " VRR" : ""))
                    .foregroundStyle(Self.fpsGreen.color)
                Text(verbatim: " · \(statistics.codec)\(statistics.hdr ? " HDR" : "")")
            }
            .font(DelosFonts.figtree(stage.tpx(20), .semibold))
            // The upscaler's sizes under the first line: the stream, what it reconstructs at, the picture (StreamStats.kt:246-252)
            if let upscale = statistics.upscale {
                Text(verbatim: UpscalerSizeText.statistics(streamWidth: statistics.width, streamHeight: statistics.height, sizes: upscale))
                    .font(DelosFonts.figtree(stage.tpx(17)))
                    .foregroundStyle(colors.text.color.opacity(0.75))
            }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Self.alignment(position))
        .environment(\.glassOverMedia, true)
        .allowsHitTesting(false)
    }

    /// Where the full panel sits for [position] (StreamStats.kt:188-206).
    static func alignment(_ position: StatsPosition) -> Alignment {
        switch position {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    /// The panel's rows in Android's order (StreamStats.kt:255-270); a reading the stream does not have is left out with its
    /// label.
    private var rows: [(label: String, value: String)] {
        var result = [(L("stream_stats_decoder"), statistics.renderer)]
        result.append((L("stream_stats_incoming"), "\(number(statistics.incomingFPS)) FPS"))
        if let fps = statistics.renderingFPS {
            result.append((L("stream_stats_rendering"), "\(number(fps)) FPS"))
        }
        if let low = statistics.onePercentLowText {
            result.append((L("stream_stats_one_percent_low", 1), low))
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
        if let upscaling = statistics.upscalingText {
            result.append((L("stream_stats_upscaling"), upscaling))
        }
        if let queue = statistics.frameQueueText {
            result.append((L("stream_stats_frame_queue"), queue))
        }
        if let sharpen = statistics.sharpenPassText {
            result.append((L("stream_stats_sharpen_pass"), sharpen))
        }
        // The renderer's decoded-to-presented latency; the display layer reports only how late its frames were shown
        if let latency = statistics.renderLatencyText {
            result.append((L("stream_stats_render_latency"), latency))
        } else if let delay = statistics.presentationDelayMilliseconds {
            result.append((L("stream_stats_render_latency"), "\(number(delay, places: 2)) ms"))
        }
        if let total = statistics.totalMilliseconds {
            result.append((L("stream_stats_total_latency"), "\(number(total)) ms"))
        }
        result.append((L("stream_stats_bandwidth"), StatisticsLine.bandwidth(kibPerSecond: statistics.bandwidthKiBPerSecond)))
        if let loss = statistics.lostFramesPercent {
            result.append((L("stream_stats_lost_frames"), "\(number(loss, places: 2)) %"))
        }
        if let encryption = statistics.encryption {
            result.append((L("stream_stats_encryption"), Self.encryptionText(encryption)))
        }
        return result
    }

    /// "Video: On · Audio: Off · Control: On" (`StreamEncryption.text`, diag/StreamEncryption.kt:21-36).
    static func encryptionText(_ encryption: StreamEncryption) -> String {
        func word(_ value: Bool?) -> String {
            switch value {
            case true?: L("common_on")
            case false?: L("common_off")
            case nil: L("stream_encryption_unknown")
            }
        }
        return L("stream_encryption_value", word(encryption.video), word(encryption.audio), word(encryption.control))
    }

    private func number(_ value: Double?, places: Int = 1) -> String {
        guard let value else { return "—" }
        return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), places, value)
    }
}
