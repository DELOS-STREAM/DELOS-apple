import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#endif

// The markers a run leaves for the next start (docs/DIAGNOSTICS.md; CrashReporter.kt, CrashFile.kt and CrashText.kt of DELOS
// for Android): the crash file with its marker, and the session marker. Everything stays in the app's own files; nothing is sent.

/// What a crash leaves for the next start: who crashed, the stack trace and the newest log lines (`CrashRecord`).
public struct CrashRecord: Sendable, Equatable {
    public var whenMs: Int64
    public var pid: Int32
    public var thread: String
    /// `NSInvalidArgumentException: message` or `SIGSEGV (signal 11)`, one line.
    public var exception: String
    /// The exception line, then one `at <symbol> (<image>)` line per frame.
    public var stackTrace: String
    /// The newest lines of the diagnostic log, raw: they are scrubbed when the report is built. Empty after a signal, whose
    /// handler may not read files.
    public var logTail: [String]

    public init(whenMs: Int64, pid: Int32, thread: String, exception: String, stackTrace: String, logTail: [String]) {
        self.whenMs = whenMs
        self.pid = pid
        self.thread = thread
        self.exception = exception
        self.stackTrace = stackTrace
        self.logTail = logTail
    }
}

/// The text form of a ``CrashRecord`` (the crash file) and the short sentences made from it (`CrashFile`).
public enum CrashFile {
    /// How many log lines the crash file keeps.
    public static let logTailLines = 200
    /// A stack trace is cut here, so one crash cannot fill the log (`CrashText.MAX_TRACE_CHARS`).
    public static let maxTraceCharacters = 6_000

    static let title = "Delos crash report"
    static let stackHeading = "== Stack trace =="
    static let logHeading = "== Last log lines =="

    /// The record of a crash: [exception] (only its first line is kept), the raw [frames] of `callStackSymbols` or
    /// `backtrace_symbols` and the newest lines of [rawLog].
    public static func record(whenMs: Int64, pid: Int32, thread: String, exception: String, frames: [String], rawLog: String) -> CrashRecord {
        let head = String((exception.components(separatedBy: "\n").first ?? "").prefix(300))
        var trace = ([head] + frames.map(frameLine)).joined(separator: "\n")
        if trace.count > maxTraceCharacters { trace = String(trace.prefix(maxTraceCharacters)) + "\n… (stack trace cut)" }
        return CrashRecord(whenMs: whenMs, pid: pid, thread: thread, exception: head, stackTrace: trace,
                           logTail: Array(DiagLine.lines(rawLog).suffix(logTailLines)))
    }

    public static func format(_ record: CrashRecord) -> String {
        var lines = [
            title, "Time: \(record.whenMs)", "Process: \(record.pid)", "Thread: \(record.thread)", "Exception: \(record.exception)",
            stackHeading, record.stackTrace, logHeading,
        ]
        lines += record.logTail
        return lines.joined(separator: "\n") + "\n"
    }

    /// The record in [text], or nil when it is not (completely) a crash file. The raw frames a signal handler wrote become
    /// `at` lines, and the frames of the handler itself (up to `_sigtramp`) are dropped.
    public static func parse(_ text: String) -> CrashRecord? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == title, let stack = lines.firstIndex(of: stackHeading), let log = lines.firstIndex(of: logHeading),
              log > stack else { return nil }
        func header(_ name: String) -> String? {
            lines[..<stack].first { $0.hasPrefix("\(name): ") }.map { String($0.dropFirst(name.count + 2)) }
        }
        guard let when = header("Time").flatMap({ Int64($0) }), let pid = header("Process").flatMap({ Int32($0) }),
              let thread = header("Thread"), let exception = header("Exception") else { return nil }
        var trace = Array(lines[(stack + 1)..<log])
        if let tramp = trace.lastIndex(where: { $0.contains("_sigtramp") }) {
            // The frames above `_sigtramp` are the signal handler's own; the exception line stays first
            trace = Array(trace.prefix(1)) + trace[(tramp + 1)...]
        }
        trace = trace.map { $0.hasPrefix("at ") || !looksLikeRawFrame($0) ? $0 : frameLine($0) }
        var tail = Array(lines[(log + 1)...])
        while tail.last?.isEmpty == true { tail.removeLast() }
        return CrashRecord(whenMs: when, pid: pid, thread: thread, exception: exception, stackTrace: trace.joined(separator: "\n"), logTail: tail)
    }

    /// `NSInvalidArgumentException: boom (at DelosUI.Foo.bar)`: what the card and the issue title say.
    public static func summary(_ record: CrashRecord) -> String {
        let colon = record.exception.firstIndex(of: ":")
        let type = String(record.exception[..<(colon ?? record.exception.endIndex)]).components(separatedBy: ".").last ?? ""
        let message = colon.map { String(record.exception[record.exception.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
        let head = message.isEmpty ? type : "\(type): \(message)"
        let text = topFrame(record.stackTrace).map { "\(head) (at \($0))" } ?? head
        return String(text.prefix(180))
    }

    /// The first frame of DELOS's own code (its modules are named `Delos…`), else the first frame: the symbol without its
    /// arguments and image.
    public static func topFrame(_ stackTrace: String) -> String? {
        let frames = stackTrace.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("at ") }
            .map { String($0.dropFirst(3).prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces) }
        return frames.first { $0.hasPrefix("Delos") && !$0.contains("CrashReporter") } ?? frames.first
    }

    /// The exception line and the first [frames] frames: short enough for the prefilled issue.
    public static func shortTrace(_ record: CrashRecord, frames: Int = 12) -> String {
        let lines = record.stackTrace.components(separatedBy: "\n")
        let head = lines.prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("at ") }
        let traceFrames = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("at ") }.prefix(frames)
        return (head + traceFrames).joined(separator: "\n")
    }

    /// One line of `backtrace_symbols` or `callStackSymbols` (`3   DELOS   0x0000000104a1c2f8 $s7DelosUI3FooV3baryyF + 120`) as
    /// `at DelosUI.Foo.bar() -> () (DELOS)`; a line of another shape is kept as it is.
    public static func frameLine(_ raw: String) -> String {
        let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
        guard looksLikeRawFrame(raw), parts.count >= 4 else { return raw }
        var symbol = parts[3...].map(String.init)
        if symbol.count >= 3, symbol[symbol.count - 2] == "+" { symbol.removeLast(2) }
        return "at \(demangle(symbol.joined(separator: " "))) (\(parts[1]))"
    }

    private static func looksLikeRawFrame(_ line: String) -> Bool {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        return parts.count >= 4 && Int(parts[0]) != nil && parts[2].hasPrefix("0x")
    }

    /// A Swift symbol in its readable form; other symbols are returned as they are.
    static func demangle(_ symbol: String) -> String {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") else { return symbol }
        return symbol.withCString { pointer in
            guard let readable = swiftDemangle(pointer, UInt(strlen(pointer)), nil, nil, 0) else { return symbol }
            defer { free(readable) }
            return String(cString: readable)
        }
    }
}

/// The runtime's demangler (the same one `swift demangle` uses).
@_silgen_name("swift_demangle")
private func swiftDemangle(
    _ mangled: UnsafePointer<CChar>?, _ length: UInt, _ output: UnsafeMutablePointer<CChar>?, _ outputSize: UnsafeMutablePointer<UInt>?,
    _ flags: UInt32
) -> UnsafeMutablePointer<CChar>?

/// The marker the previous process left (`SessionRecord`): [inForeground] is true while the app is in front, so a process
/// that the system ended in the background does not count as a problem.
public struct SessionRecord: Sendable, Equatable {
    public var pid: Int32
    public var startedAtMs: Int64
    public var updatedAtMs: Int64
    public var inForeground: Bool

    public init(pid: Int32, startedAtMs: Int64, updatedAtMs: Int64, inForeground: Bool) {
        self.pid = pid
        self.startedAtMs = startedAtMs
        self.updatedAtMs = updatedAtMs
        self.inForeground = inForeground
    }

    public func format() -> String { "\(inForeground ? "foreground" : "background") \(pid) \(startedAtMs) \(updatedAtMs)" }

    public static func parse(_ text: String) -> SessionRecord? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ")
        guard parts.count == 4, ["foreground", "background"].contains(parts[0]), let pid = Int32(parts[1]), let started = Int64(parts[2]),
              let updated = Int64(parts[3]) else { return nil }
        return SessionRecord(pid: pid, startedAtMs: started, updatedAtMs: updated, inForeground: parts[0] == "foreground")
    }
}

/// Leaves the markers the next start reads (`CrashReporter`): an uncaught Objective-C exception or a fatal signal (a Swift
/// runtime error traps with one) writes `crash.txt` and then `crash.marker`, and the app's foreground state keeps
/// `session.marker` up to date. A file without its marker is an interrupted write and is ignored. With "Keep diagnostic logs"
/// off nothing is written.
public enum CrashReporter {
    static let crashFileName = "crash.txt"
    static let crashMarkerName = "crash.marker"
    static let sessionMarkerName = "session.marker"

    private struct State {
        var directory: URL?
        var startedAtMs: Int64 = 0
        var previousSession: SessionRecord?
    }

    private static let state = Mutex(State())
    private static let writer = DispatchQueue(label: "DiagSession", qos: .utility)

    /// The marker of the process before this one, read before this process overwrote it.
    public static var previousSession: SessionRecord? { state.withLock { $0.previousSession } }

    /// Installs the exception and signal handlers (each still ends the process the way it would have without them) and starts
    /// the session marker; safe to call again.
    public static func install(directory: URL = DiagLog.defaultDirectory) {
        let first = state.withLock { state -> Bool in
            guard state.directory == nil else { return false }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            state.directory = directory
            state.startedAtMs = nowMs()
            state.previousSession = (try? String(contentsOf: directory.appendingPathComponent(sessionMarkerName), encoding: .utf8))
                .flatMap(SessionRecord.parse)
            return true
        }
        guard first else { return }
        crashCaptureOn.store(DiagLog.isEnabled, ordering: .relaxed)
        setForeground(false)
        installExceptionHandler()
        installSignalHandlers(directory)
    }

    /// The app came to the front or left it (the session marker).
    public static func setForeground(_ foreground: Bool) {
        guard let (directory, started) = state.withLock({ state in state.directory.map { ($0, state.startedAtMs) } }) else { return }
        let text = SessionRecord(pid: getpid(), startedAtMs: started, updatedAtMs: nowMs(), inForeground: foreground).format()
        writer.async { writeAtomically(directory.appendingPathComponent(sessionMarkerName), text) }
    }

    /// The crash the last run left, or nil when there is none or its write was interrupted.
    public static func readCrash() -> CrashRecord? {
        guard let directory = state.withLock({ $0.directory }),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(crashMarkerName).path) else { return nil }
        return (try? String(contentsOf: directory.appendingPathComponent(crashFileName), encoding: .utf8)).flatMap(CrashFile.parse)
    }

    /// Removes the crash files once the problem has been reported or dismissed.
    public static func clearCrash() {
        guard let directory = state.withLock({ $0.directory }) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(crashMarkerName))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(crashFileName))
    }

    /// Follows "Keep diagnostic logs" (``DiagLog/setEnabled(_:defaults:)``).
    static func setCaptureEnabled(_ on: Bool) { crashCaptureOn.store(on, ordering: .relaxed) }

    // MARK: Objective-C exceptions

    private static func installExceptionHandler() {
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            // A crash inside the handler must not hide the original one; the abort() that follows is not a second crash
            if crashCaptureOn.load(ordering: .relaxed), crashClaimed.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged {
                CrashReporter.record(exception)
            }
            previousExceptionHandler?(exception)
        }
    }

    private static func record(_ exception: NSException) {
        guard let directory = state.withLock({ $0.directory }) else { return }
        let thread = Thread.isMainThread ? "main" : (Thread.current.name.flatMap { $0.isEmpty ? nil : $0 } ?? "background")
        let line = "\(exception.name.rawValue): \(exception.reason ?? "")"
        DiagLog.e("Crash", "Uncaught exception on thread \(thread): \(line)\n" + exception.callStackSymbols.joined(separator: "\n"))
        DiagLog.flush()
        let now = nowMs()
        let record = CrashFile.record(whenMs: now, pid: getpid(), thread: thread, exception: line, frames: exception.callStackSymbols,
                                      rawLog: DiagLog.readAll())
        writeAtomically(directory.appendingPathComponent(crashFileName), CrashFile.format(record))
        // The marker comes last: a crash file without it is an interrupted write and is ignored
        writeAtomically(directory.appendingPathComponent(crashMarkerName), "\(now) \(getpid())")
    }

    // MARK: Signals

    /// The fatal signals: SIGTRAP is how a Swift runtime error (a failed precondition, an index out of range) ends the process.
    private static let fatalSignals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP]

    private static func installSignalHandlers(_ directory: URL) {
        // Everything the handler touches exists before it can run: it may not allocate
        crashPath = strdup(directory.appendingPathComponent(crashFileName).path)
        markerPath = strdup(directory.appendingPathComponent(crashMarkerName).path)
        frames = .allocate(capacity: Int(maxFrames))
        digits = .allocate(capacity: 24)
        previousActions = .allocate(capacity: Int(NSIG))
        previousActions?.initialize(repeating: sigaction(), count: Int(NSIG))
        // A stack overflow leaves no stack for the handler: it runs on its own (tvOS has no alternate signal stack)
        #if !os(tvOS)
        let size = 64 * 1024
        var stack = stack_t(ss_sp: malloc(size), ss_size: size, ss_flags: 0)
        _ = sigaltstack(&stack, nil)
        #endif
        for signal in fatalSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = onFatalSignal
            action.sa_flags = SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, previousActions.map { $0 + Int(signal) })
        }
    }

    /// Milliseconds since 1970, the clock of every marker.
    public static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

    private static func writeAtomically(_ target: URL, _ text: String) {
        try? Data(text.utf8).write(to: target, options: .atomic)
    }
}

// What the signal handler uses: set up once by `installSignalHandlers` before the handler is installed, never changed after.
private let maxFrames: Int32 = 64
private nonisolated(unsafe) var crashPath: UnsafeMutablePointer<CChar>?
private nonisolated(unsafe) var markerPath: UnsafeMutablePointer<CChar>?
private nonisolated(unsafe) var frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
private nonisolated(unsafe) var digits: UnsafeMutablePointer<UInt8>?
private nonisolated(unsafe) var previousActions: UnsafeMutablePointer<sigaction>?
private nonisolated(unsafe) var previousExceptionHandler: (@convention(c) (NSException) -> Void)?
/// "Keep diagnostic logs", readable from a signal handler.
private let crashCaptureOn = Atomic(true)
/// The first crash of the process claims the file: the abort() after an exception or a second fault writes nothing more.
private let crashClaimed = Atomic(false)

/// Writes the crash file with only async-signal-safe calls, then puts the previous handler back and raises the signal again,
/// so the process ends as it would have (and the system's crash report is made).
private func onFatalSignal(_ signal: Int32) {
    if crashCaptureOn.load(ordering: .relaxed), crashClaimed.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged,
       let crashPath, let markerPath {
        let fd = open(crashPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if fd >= 0 {
            var now = timeval()
            gettimeofday(&now, nil)
            writeText(fd, "Delos crash report\nTime: ")
            writeNumber(fd, Int64(now.tv_sec) * 1000 + Int64(now.tv_usec / 1000))
            writeText(fd, "\nProcess: ")
            writeNumber(fd, Int64(getpid()))
            writeText(fd, pthread_main_np() != 0 ? "\nThread: main\nException: " : "\nThread: background\nException: ")
            writeSignal(fd, signal)
            writeText(fd, "\n== Stack trace ==\n")
            writeSignal(fd, signal)
            writeText(fd, "\n")
            if let frames {
                let count = backtrace(frames, maxFrames)
                backtrace_symbols_fd(frames, count, fd)
            }
            writeText(fd, "== Last log lines ==\n")
            close(fd)
            let marker = open(markerPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            if marker >= 0 {
                writeText(marker, "signal\n")
                close(marker)
            }
        }
    }
    if let previousActions {
        sigaction(signal, previousActions + Int(signal), nil)
    } else {
        var fallback = sigaction()
        fallback.__sigaction_u.__sa_handler = SIG_DFL
        sigaction(signal, &fallback, nil)
    }
    raise(signal)
}

private func writeText(_ fd: Int32, _ text: StaticString) {
    _ = write(fd, text.utf8Start, text.utf8CodeUnitCount)
}

private func writeNumber(_ fd: Int32, _ value: Int64) {
    guard let digits else { return }
    var rest = max(0, value)
    var count = 0
    repeat {
        digits[23 - count] = UInt8(ascii: "0") + UInt8(rest % 10)
        rest /= 10
        count += 1
    } while rest > 0 && count < 24
    _ = write(fd, digits + (24 - count), count)
}

/// `SIGSEGV (signal 11)`.
private func writeSignal(_ fd: Int32, _ signal: Int32) {
    switch signal {
    case SIGSEGV: writeText(fd, "SIGSEGV")
    case SIGBUS: writeText(fd, "SIGBUS")
    case SIGILL: writeText(fd, "SIGILL")
    case SIGFPE: writeText(fd, "SIGFPE")
    case SIGABRT: writeText(fd, "SIGABRT")
    case SIGTRAP: writeText(fd, "SIGTRAP")
    default: writeText(fd, "SIGNAL")
    }
    writeText(fd, " (signal ")
    writeNumber(fd, Int64(signal))
    writeText(fd, ")")
}
