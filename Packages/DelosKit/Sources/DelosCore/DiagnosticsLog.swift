import Foundation
import Synchronization

// The app's own diagnostic log (docs/DIAGNOSTICS.md; DiagLog.kt and DiagLogWriter.kt of DELOS for Android). It lives in the
// lowest module, so the core's log sink, the decoder, the input and the shell all write into the same file.

/// Severity of a diagnostic line; [letter] is what the log shows.
public enum DiagLevel: Int, Comparable, Sendable {
    case debug, info, warn, error

    public var letter: Character {
        switch self {
        case .debug: "D"
        case .info: "I"
        case .warn: "W"
        case .error: "E"
        }
    }

    public static func < (lhs: DiagLevel, rhs: DiagLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The text of one log line, in one place so the reader (export, crash file) and the writer agree.
public enum DiagLine {
    /// A single message is cut here, so one runaway line cannot fill the 1 MiB file.
    public static let maxMessageCharacters = 8 * 1024

    /// `2026-11-10 12:34:56.789 I/Stream [main] message`, in [zone].
    public static func format(
        epochMilliseconds: Int64, zone: TimeZone, level: DiagLevel, tag: String, thread: String, message: String
    ) -> String {
        let text = message.count > maxMessageCharacters ? String(message.prefix(maxMessageCharacters)) + "… (cut)" : message
        return "\(timestamp(epochMilliseconds, zone: zone)) \(level.letter)/\(tag) [\(thread)] \(text)"
    }

    static func timestamp(_ epochMilliseconds: Int64, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let millis = Int(((epochMilliseconds % 1000) + 1000) % 1000)
        let date = Date(timeIntervalSince1970: Double(epochMilliseconds - Int64(millis)) / 1000)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ value: Int?) -> String { let v = value ?? 0; return v < 10 ? "0\(v)" : "\(v)" }
        let ms = millis < 10 ? "00\(millis)" : millis < 100 ? "0\(millis)" : "\(millis)"
        return "\(c.year ?? 0)-\(two(c.month))-\(two(c.day)) \(two(c.hour)):\(two(c.minute)):\(two(c.second)).\(ms)"
    }

    /// The lines of a raw log, without the empty last one.
    public static func lines(_ rawLog: String) -> [String] {
        var lines = rawLog.components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}

/// The rolling diagnostic log on disk: two files of at most [maxFileBytes] each in [directory] (`diag-0.log` is the one being
/// written, `diag-1.log` the previous one). Writing happens on its own background queue; ``offer(_:)`` never blocks, a full
/// queue drops the line (and a later line says how many were lost), so a flood of messages never stalls the stream, the
/// render or the input.
public final class DiagLogWriter: Sendable {
    /// Each of the two files.
    public static let maxFileBytesDefault = 1 << 20
    /// Lines waiting for the writer; more than this are dropped.
    public static let queueCapacity = 1024

    private struct Counters {
        var pending = 0
        var dropped = 0
        /// Held back by a test to fill the queue (``start()`` lets it run).
        var started = true
        var held: [String] = []
    }

    /// What only the writer queue touches.
    private struct Disk {
        var handle: FileHandle?
        var written = 0
        var buffer = Data()
    }

    public let directory: URL
    private let maxFileBytes: Int
    private let capacity: Int
    private let queue = DispatchQueue(label: "DiagLog", qos: .background)
    private let counters: Mutex<Counters>
    private let disk = Mutex(Disk())

    public init(directory: URL, maxFileBytes: Int = DiagLogWriter.maxFileBytesDefault, capacity: Int = DiagLogWriter.queueCapacity,
                start: Bool = true) {
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        self.capacity = capacity
        counters = Mutex(Counters(started: start))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Lets a writer made with `start: false` write what was queued meanwhile.
    public func start() {
        let held = counters.withLock { state -> [String] in
            state.started = true
            defer { state.held = [] }
            return state.held
        }
        for line in held { queue.async { self.write(line) } }
    }

    /// Queues one finished line (without its newline). False when it was dropped.
    @discardableResult
    public func offer(_ line: String) -> Bool {
        let accepted = counters.withLock { state -> Bool? in
            guard state.pending < capacity else {
                state.dropped += 1
                return false
            }
            state.pending += 1
            if !state.started {
                state.held.append(line)
                return nil
            }
            return true
        }
        guard let accepted else { return true }
        if accepted { queue.async { self.write(line) } }
        return accepted
    }

    /// Waits until every line queued so far is on disk, at most [timeout] seconds.
    @discardableResult
    public func flush(timeout: Double = 2) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.disk.withLock { self.flushBuffer(&$0) }
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Everything on disk, the older file first, exactly as written.
    public func readAll() -> String {
        queue.sync {
            disk.withLock { flushBuffer(&$0) }
            return [older, current].compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        }
    }

    /// The size of the log on disk in bytes.
    public func sizeBytes() -> Int {
        queue.sync {
            disk.withLock { flushBuffer(&$0) }
            return [older, current].reduce(0) { sum, file in
                sum + ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0)
            }
        }
    }

    /// Deletes both files; lines queued meanwhile start a new log.
    public func clear() {
        queue.sync {
            disk.withLock { state in
                try? state.handle?.close()
                state = Disk()
            }
            try? FileManager.default.removeItem(at: older)
            try? FileManager.default.removeItem(at: current)
        }
    }

    private var current: URL { directory.appendingPathComponent("diag-0.log") }
    private var older: URL { directory.appendingPathComponent("diag-1.log") }

    private func write(_ line: String) {
        let (lost, empty) = counters.withLock { state -> (Int, Bool) in
            state.pending -= 1
            defer { state.dropped = 0 }
            return (state.dropped, state.pending == 0)
        }
        disk.withLock { state in
            if lost > 0 { append("--- \(lost) log lines dropped (queue full) ---", &state) }
            append(line, &state)
            // The buffered bytes go to disk whenever the queue runs dry, so a crash loses almost nothing
            if empty || state.buffer.count >= 8 * 1024 { flushBuffer(&state) }
        }
    }

    private func append(_ text: String, _ state: inout Disk) {
        let bytes = Data((text + "\n").utf8)
        if state.handle == nil { open(&state) }
        // The buffered bytes count too: the queue may not run dry before the file is full
        let size = state.written + state.buffer.count
        if size > 0 && size + bytes.count > maxFileBytes { rotate(&state) }
        state.buffer.append(bytes)
    }

    private func flushBuffer(_ state: inout Disk) {
        guard !state.buffer.isEmpty else { return }
        if state.handle == nil { open(&state) }
        do {
            try state.handle?.write(contentsOf: state.buffer)
            state.written += state.buffer.count
        } catch {
            // Diagnostics must never become a problem of their own: close and try again with the next line
            try? state.handle?.close()
            state.handle = nil
        }
        state.buffer.removeAll(keepingCapacity: true)
    }

    private func open(_ state: inout Disk) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: current.path) {
            FileManager.default.createFile(atPath: current.path, contents: nil)
        }
        state.handle = try? FileHandle(forWritingTo: current)
        state.written = Int((try? state.handle?.seekToEnd()) ?? 0)
    }

    private func rotate(_ state: inout Disk) {
        flushBuffer(&state)
        try? state.handle?.close()
        state.handle = nil
        try? FileManager.default.removeItem(at: older)
        try? FileManager.default.moveItem(at: current, to: older)
        open(&state)
    }
}

/// The app's diagnostic log: INFO and above in a release build, DEBUG as well in a debug build, kept only on this device in
/// a small rolling file until the user shares it. Calls before ``start(directory:defaults:)``, with "Keep diagnostic logs"
/// off or below the level do nothing, so a call may stay in a hot path's error branch.
public enum DiagLog {
    /// The "Keep diagnostic logs" switch, device-wide (Android's `diag_logs_enabled` in the default preferences).
    public static let enabledKey = "diag_logs_enabled"

    private struct State {
        var writer: DiagLogWriter?
        var enabled = true
        var minLevel = DiagLevel.info
    }

    private static let state = Mutex(State())
    /// The native log of the core is limited to this many lines per second (a flood of the same warning).
    private static let nativeLimit = Mutex((second: Int64(0), count: 0))

    /// The folder of the log and of the crash files: Application Support/diagnostics.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("diagnostics", isDirectory: true)
    }

    /// Starts the log in [directory]; safe to call again. [processLine] is the first line of this run.
    public static func start(directory: URL = defaultDirectory, defaults: UserDefaults = .standard, processLine: String) {
        let started = state.withLock { state -> Bool in
            guard state.writer == nil else { return false }
            state.enabled = storedEnabled(defaults)
            #if DEBUG
            state.minLevel = .debug
            #else
            state.minLevel = .info
            #endif
            state.writer = DiagLogWriter(directory: directory)
            return true
        }
        // A process start is the boundary the reader of the log needs most
        if started { i("App", processLine) }
    }

    /// Whether lines are written now.
    public static var isEnabled: Bool { state.withLock { $0.enabled } }

    /// The stored switch; on by default.
    public static func storedEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Turns the log on or off and remembers it for the device. Off: nothing is written; what is on disk stays until cleared.
    public static func setEnabled(_ on: Bool, defaults: UserDefaults = .standard) {
        state.withLock { $0.enabled = on }
        CrashReporter.setCaptureEnabled(on)
        defaults.set(on, forKey: enabledKey)
    }

    public static func d(_ tag: String, _ message: String) { log(.debug, tag, message) }
    public static func i(_ tag: String, _ message: String) { log(.info, tag, message) }
    public static func w(_ tag: String, _ message: String) { log(.warn, tag, message) }
    public static func e(_ tag: String, _ message: String) { log(.error, tag, message) }

    public static func log(_ level: DiagLevel, _ tag: String, _ message: String) {
        let sink = state.withLock { state -> DiagLogWriter? in
            guard state.enabled, level >= state.minLevel else { return nil }
            return state.writer
        }
        guard let sink else { return }
        let now = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
        // Formatted here: the thread is only known to the caller
        sink.offer(DiagLine.format(epochMilliseconds: now, zone: .current, level: level, tag: tag, thread: threadName(), message: message))
    }

    /// A line of the streaming core's own log (its log callback), at most 60 per second.
    public static func native(_ tag: String, _ message: String) {
        let now = Int64(Date().timeIntervalSince1970)
        let allowed = nativeLimit.withLock { limit -> Bool in
            if limit.second != now { limit = (now, 0) }
            limit.count += 1
            return limit.count <= 60
        }
        guard allowed else { return }
        log(.info, tag, message.trimmingCharacters(in: .newlines))
    }

    /// The whole log as written, oldest line first; empty before ``start(directory:defaults:processLine:)``.
    public static func readAll() -> String { writer?.readAll() ?? "" }

    public static func sizeBytes() -> Int { writer?.sizeBytes() ?? 0 }

    /// Waits briefly until the lines queued so far are on disk (the crash handler calls this).
    public static func flush() { writer?.flush(timeout: 0.5) }

    public static func clear() { writer?.clear() }

    private static var writer: DiagLogWriter? { state.withLock { $0.writer } }

    private static func threadName() -> String {
        if Thread.isMainThread { return "main" }
        if let name = Thread.current.name, !name.isEmpty { return name }
        return String(cString: __dispatch_queue_get_label(nil))
    }
}

/// The sentences of the stream events in the diagnostic log, in one place so they are tested (`StreamEvents` of DELOS for Android).
public enum StreamLogLines {
    /// What the host and the client settled on: codec, chroma, HDR, size, rate and the bitrate asked for.
    public static func negotiated(format: VideoFormats, width: Int, height: Int, fps: Int, bitrateKbps: Int) -> String {
        let codec = if !format.isDisjoint(with: .allPyroWave) { "PyroWave" }
            else if !format.isDisjoint(with: .allAV1) { "AV1" }
            else if !format.isDisjoint(with: .allHEVC) { "HEVC" }
            else if !format.isDisjoint(with: .allH264) { "H.264" }
            else { "unknown" }
        let chroma = format.isDisjoint(with: .yuv444) ? "4:2:0" : "4:4:4"
        let hdr = format.isDisjoint(with: .tenBit) ? "8-bit (SDR)" : "10-bit (HDR)"
        return "Negotiated video: \(codec) \(chroma) \(hdr) \(width)x\(height) at \(fps) fps, bitrate \(bitrateKbps) kbps "
            + "(format 0x\(String(format.rawValue, radix: 16, uppercase: true)))"
    }
}
