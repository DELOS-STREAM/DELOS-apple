import DelosCore
import DelosMedia
import Foundation

/// What a diagnostic report says about the device and the setup (`DeviceInfo` of DELOS for Android, diag/DeviceInfo.kt). Only
/// facts that help to reproduce a problem: no PC names, addresses, tokens, API keys, account names or game list ever enter it.
public struct DeviceInfo: Sendable, Equatable {
    public var delosVersion: String
    /// "debug" or "release".
    public var buildType: String
    public var buildNumber: String
    /// The kind of device ("iPhone", "iPad", "Apple TV", "Mac").
    public var deviceKind: String
    /// The model identifier ("iPhone17,1", "Mac16,10").
    public var model: String
    /// The system's name and version ("iOS 26.1").
    public var system: String
    public var systemBuild: String
    public var chip: String
    public var architecture: String
    /// The Metal device's name.
    public var gpu: String
    public var screen: String
    /// The kind of the active network; never its name.
    public var network: String
    public var locale: String
    /// The UTC offset ("UTC+01:00"), not the region: the region would say where the user lives.
    public var timeZone: String
    /// The stream settings in a fixed order: label to value (``StreamSettingsSnapshot``).
    public var settings: [(String, String)]

    public init(delosVersion: String, buildType: String, buildNumber: String, deviceKind: String, model: String, system: String,
                systemBuild: String, chip: String, architecture: String, gpu: String, screen: String, network: String, locale: String,
                timeZone: String, settings: [(String, String)]) {
        self.delosVersion = delosVersion
        self.buildType = buildType
        self.buildNumber = buildNumber
        self.deviceKind = deviceKind
        self.model = model
        self.system = system
        self.systemBuild = systemBuild
        self.chip = chip
        self.architecture = architecture
        self.gpu = gpu
        self.screen = screen
        self.network = network
        self.locale = locale
        self.timeZone = timeZone
        self.settings = settings
    }

    public static func == (lhs: DeviceInfo, rhs: DeviceInfo) -> Bool { lhs.format() == rhs.format() }

    /// The block at the top of every report, one `Label: value` line per fact.
    public func format() -> String {
        var lines = [
            "Delos: \(delosVersion) (\(buildType)), build \(buildNumber)",
            "Device: \(deviceKind) (\(model))",
            "System: \(system), build \(systemBuild)",
            "Chip: \(chip) (\(architecture))",
            "GPU: \(gpu)",
            "Screen: \(screen)",
            "Network: \(network)",
            "Locale: \(locale), time zone \(timeZone)",
            "Stream settings:",
        ]
        lines += settings.map { "  \($0.0): \($0.1)" }
        return lines.joined(separator: "\n")
    }

    /// "UTC+01:00" for [seconds] east of UTC.
    public static func utcOffset(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        let hours = minutes / 60, rest = minutes % 60
        return "UTC\(sign)\(hours < 10 ? "0" : "")\(hours):\(rest < 10 ? "0" : "")\(rest)"
    }
}

/// The stream settings a report lists (`StreamSettingsSnapshot` of DELOS for Android): a fixed list, never the whole stored
/// settings, so a PC name, an API key or a layout can not slip in.
public enum StreamSettingsSnapshot {
    public static func read(_ settings: StreamSettings) -> [(String, String)] {
        let upscaler = settings.bool(.upscaler)
            ? "on, mode \(settings.text(.upscalerMode)), sharpness \(settings.int(.upscalerSharpness)), supersampling \(settings.text(.upscalerSupersampling))"
            : "off"
        return [
            ("Codec", settings.codec.rawValue),
            ("Resolution", settings.resolution?.text ?? "default"),
            ("Frame rate", "\(settings.fps)"),
            ("Bitrate", settings.bitrateKbps.map { "\($0) kbps" } ?? "default"),
            ("PyroWave chroma", settings.text(.pyrowaveChroma)),
            ("HDR", settings.hdr ? "on" : "off"),
            ("Frame pacing", settings.framePacing.rawValue),
            ("Variable refresh rate", settings.text(.vrr).isEmpty ? "default" : settings.text(.vrr)),
            ("Upscaler", upscaler),
        ]
    }
}

/// A finished report: exactly the text that is shared, copied, saved or uploaded.
public struct DiagnosticReport: Sendable, Equatable {
    public static let logHeading = "== Log"
    public static let previewTailLines = 40

    public let text: String
    public let logLines: Int

    public init(text: String, logLines: Int) {
        self.text = text
        self.logLines = logLines
    }

    public var bytes: Int { text.utf8.count }

    /// "123 KB" (Android's `sizeText`), the number in [locale]'s format.
    public static func sizeText(_ bytes: Int, locale: Locale = Locale(identifier: "en_US")) -> String {
        func decimal(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1)).locale(locale)) }
        switch bytes {
        case ..<1024: return "\(bytes) B"
        case ..<(10 * 1024): return "\(decimal(Double(bytes) / 1024)) KB"
        case ..<(1024 * 1024): return "\(bytes / 1024) KB"
        default: return "\(decimal(Double(bytes) / 1024 / 1024)) MB"
        }
    }

    /// The parts of the preview panel: the header and device block, how many log lines are left out, and the newest [tailLines]
    /// lines; nil when the whole text is short enough to show (the caller words the hidden-lines note in the user's language).
    public func preview(tailLines: Int = previewTailLines) -> (head: [String], hidden: Int, tail: [String])? {
        let lines = DiagLine.lines(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let logStart = lines.firstIndex(where: { $0.hasPrefix(Self.logHeading) }), lines.count - logStart > tailLines + 1 else {
            return nil
        }
        let head = Array(lines[...logStart])
        let tail = Array(lines.suffix(tailLines))
        return (head, lines.count - head.count - tail.count, tail)
    }
}

/// Builds the text of the report and of the short summary from the raw log; everything passes the scrubber last.
public enum DiagnosticReports {
    static let intro = "Addresses, PC names, ids and keys were removed from this text on the device before it was written. "
        + "Delos sends it only when you choose to report a problem or to share it."

    /// The whole report: header, [sections] (such as the crash of an earlier run) and the log; [tailLines] keeps only that many
    /// of the newest log lines.
    public static func build(
        info: DeviceInfo, rawLog: String, scrubber: LogScrubber, generated: String, sections: [(String, String)] = [],
        tailLines: Int? = nil
    ) -> DiagnosticReport {
        var log = DiagLine.lines(rawLog)
        if let tailLines { log = Array(log.suffix(tailLines)) }
        var text = "Delos diagnostic report\nGenerated: \(generated)\n\(intro)\n\n== Device ==\n\(info.format())\n"
        for (title, body) in sections {
            text += "\n== \(title) ==\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        text += "\n\(DiagnosticReport.logHeading) (\(log.count) lines, oldest first) ==\n"
        for line in log { text += line + "\n" }
        return DiagnosticReport(text: scrubber.scrub(text), logLines: log.count)
    }

    /// The device block and the newest [tailLines] log lines: small enough to paste into an issue by hand.
    public static func summary(info: DeviceInfo, rawLog: String, scrubber: LogScrubber, generated: String, tailLines: Int = 100) -> DiagnosticReport {
        build(info: info, rawLog: rawLog, scrubber: scrubber, generated: generated, tailLines: tailLines)
    }

    /// "2026-11-10 12:34:56 (device time)".
    public static func generated(_ date: Date = Date(), zone: TimeZone = .current) -> String {
        "\(stamp(date, zone: zone, file: false)) (device time)"
    }

    /// `delos-diagnostic-20261110-123456.txt`, the name of a saved or shared report.
    public static func fileName(_ date: Date = Date(), zone: TimeZone = .current) -> String {
        "delos-diagnostic-\(stamp(date, zone: zone, file: true)).txt"
    }

    private static func stamp(_ date: Date, zone: TimeZone, file: Bool) -> String {
        let full = DiagLine.format(
            epochMilliseconds: Int64(date.timeIntervalSince1970 * 1000), zone: zone, level: .info, tag: "", thread: "", message: "")
        // "2026-11-10 12:34:56.789 I/ [] " → the date and the time to the second
        let parts = full.split(separator: " ")
        let day = String(parts[0]), time = String(parts[1].prefix(8))
        return file ? day.replacingOccurrences(of: "-", with: "") + "-" + time.replacingOccurrences(of: ":", with: "") : "\(day) \(time)"
    }
}
