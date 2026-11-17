import DelosMedia
import Foundation

/// The text of the statistics overlay's compact line (`CompactLine` of `StreamStatsPanel` in DELOS for Android): the frame
/// rate, the bandwidth and the tail of Android's `stream_stats_compact_tail` ("Network 11 ms · Decode 2.1 ms · Total 14 ms · Lost 0.0 %"),
/// each part only when the stream has the reading.
enum StatisticsLine {
    /// What separates the parts of the line, in every language of the catalog.
    static let separator = "  ·  "

    /// The line. [tail] is the catalog's `stream_stats_compact_tail` (its placeholders: 1 network ms, 2 decode ms, 3 total
    /// latency ms, 4 lost frames percent). The parts of the tail are told apart by their placeholder, so a language
    /// that reorders them keeps its order. The Total part is never shown: neither renderer reports a total latency (the
    /// full panel leaves its Total latency row out for the same reason), and a part whose reading is missing is left out
    /// with its label.
    static func text(_ statistics: StreamStatistics, tail: String) -> String {
        var parts = ["\(frames(statistics)) FPS"]
        parts.append(bandwidth(kibPerSecond: statistics.bandwidthKiBPerSecond))
        let tailText = tailText(statistics, template: tail)
        if !tailText.isEmpty { parts.append(tailText) }
        return parts.joined(separator: separator)
    }

    /// The frame rate shown: the pictures shown per second, "—" while the renderer has not reported them.
    static func frames(_ statistics: StreamStatistics) -> String {
        statistics.renderingFPS.map { String(Int($0.rounded())) } ?? "—"
    }

    /// The tail of the line: the parts of [template] whose reading the stream has, joined with ``separator``.
    static func tailText(_ statistics: StreamStatistics, template: String) -> String {
        let network = statistics.networkMilliseconds.map { Int($0.rounded()) }
        let decode = statistics.decodeMilliseconds.map { number($0) }
        let loss = statistics.lostFramesPercent.map { number($0) }
        return template.components(separatedBy: separator).compactMap { part -> String? in
            switch placeholder(of: part) {
            case 1?: network.map { String(format: part, locale: posix, $0, "", "", "") }
            case 2?: decode.map { String(format: part, locale: posix, 0, $0, "", "") }
            case 4?: loss.map { String(format: part, locale: posix, 0, "", "", $0) }
            default: nil
            }
        }
        .joined(separator: separator)
    }

    /// Bytes and bits like the full panel and the classic overlay ("2.3 MB/s · 19.4 Mb/s").
    static func bandwidth(kibPerSecond kib: Double) -> String {
        let bytes = kib >= 1000 ? "\(number(kib / 1024)) MB/s" : "\(Int(kib)) KB/s"
        let megabits = kib * 1024 * 8 / 1_000_000
        return "\(bytes) · \(number(megabits, places: megabits >= 100 ? 0 : 1)) Mb/s"
    }

    /// [text] with every space made non-breaking except the ones right after a middle dot: a narrow stage may then wrap
    /// the line only between two parts, after the separator (`keepFigures` of Android).
    static func keepingFiguresTogether(_ text: String) -> String {
        var result = ""
        var afterDot = false
        for character in text {
            switch character {
            case "·": result.append(character); afterDot = true
            case " ": result.append(afterDot ? " " : "\u{00A0}")
            default: result.append(character); afterDot = false
            }
        }
        return result
    }

    static func number(_ value: Double, places: Int = 1) -> String {
        String(format: "%.*f", locale: posix, places, value)
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// The number of the first positional placeholder (`%2$s`) in [part].
    private static func placeholder(of part: String) -> Int? {
        guard let match = part.firstMatch(of: /%(\d)\$/) else { return nil }
        return Int(match.1)
    }
}
