import Foundation
import Testing
@testable import DelosCore

/// The rolling log, its lines and the crash file (DiagLogWriterTest, CrashFileTest and StreamEventsTest of DELOS for Android).
struct DiagnosticsLogTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func linesAreWrittenInOrderAndReadBackExactly() {
        let writer = DiagLogWriter(directory: directory())
        for line in ["one", "two", "three"] { writer.offer(line) }
        #expect(writer.readAll() == "one\ntwo\nthree\n")
    }

    @Test func theFileRotatesAndTheOldestLinesGoFirst() throws {
        // 100 bytes per file; every line is 10 bytes with its newline
        let folder = directory()
        let writer = DiagLogWriter(directory: folder, maxFileBytes: 100)
        for index in 0..<25 { writer.offer(String(format: "line-%04d", index)) }
        let all = writer.readAll()
        let lines = DiagLine.lines(all)
        #expect(all.utf8.count <= 200)
        #expect(lines.last == "line-0024")
        #expect(lines == lines.indices.map { String(format: "line-%04d", 25 - lines.count + $0) })
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["diag-0.log", "diag-1.log"])
    }

    @Test func aWriterOnTheSameDirectoryAppendsToTheExistingFile() {
        let folder = directory()
        let first = DiagLogWriter(directory: folder)
        first.offer("before")
        first.flush()
        let next = DiagLogWriter(directory: folder)
        next.offer("after")
        #expect(next.readAll() == "before\nafter\n")
    }

    @Test func aFullQueueDropsLinesInsteadOfBlockingAndSaysSoLater() {
        let writer = DiagLogWriter(directory: directory(), capacity: 2, start: false)
        let results = (1...5).map { writer.offer("l\($0)") }
        #expect(results == [true, true, false, false, false])
        writer.start()
        #expect(writer.readAll() == "--- 3 log lines dropped (queue full) ---\nl1\nl2\n")
    }

    @Test func clearRemovesBothFilesAndLoggingStartsAgain() {
        let writer = DiagLogWriter(directory: directory(), maxFileBytes: 30)
        for index in 1...10 { writer.offer("line \(index)") }
        writer.clear()
        #expect(writer.readAll().isEmpty)
        #expect(writer.sizeBytes() == 0)
        writer.offer("fresh")
        #expect(writer.readAll() == "fresh\n")
    }

    @Test func sizeIsTheBytesOnDisk() {
        let writer = DiagLogWriter(directory: directory())
        writer.offer("abc")
        writer.flush()
        #expect(writer.sizeBytes() == 4)
    }

    @Test func aLineCarriesTimeLevelTagThreadAndMessage() {
        let line = DiagLine.format(epochMilliseconds: 0, zone: TimeZone(identifier: "UTC")!, level: .warn, tag: "Stream", thread: "main",
                                   message: "decoder failed")
        #expect(line == "1970-01-01 00:00:00.000 W/Stream [main] decoder failed")
        let later = DiagLine.format(epochMilliseconds: 1_762_777_296_789, zone: TimeZone(identifier: "UTC")!, level: .info, tag: "A", thread: "t", message: "m")
        #expect(later == "2025-11-10 12:21:36.789 I/A [t] m")
    }

    @Test func aRunawayMessageIsCut() {
        let line = DiagLine.format(epochMilliseconds: 0, zone: .gmt, level: .info, tag: "T", thread: "t",
                                   message: String(repeating: "x", count: DiagLine.maxMessageCharacters * 2))
        #expect(line.count < DiagLine.maxMessageCharacters + 100)
        #expect(line.hasSuffix("(cut)"))
    }

    @Test func theNegotiatedLineNamesCodecChromaAndHdr() {
        let hevc = StreamLogLines.negotiated(format: .hevcMain10, width: 1920, height: 1080, fps: 120, bitrateKbps: 80_000)
        #expect(hevc.hasPrefix("Negotiated video: HEVC 4:2:0 10-bit (HDR) 1920x1080 at 120 fps, bitrate 80000 kbps"))
        let h264 = StreamLogLines.negotiated(format: .h264, width: 1280, height: 720, fps: 60, bitrateKbps: 20_000)
        #expect(h264.hasPrefix("Negotiated video: H.264 4:2:0 8-bit (SDR) 1280x720 at 60 fps"))
        let av1 = StreamLogLines.negotiated(format: .av1High444, width: 3840, height: 2160, fps: 60, bitrateKbps: 1)
        #expect(av1.hasPrefix("Negotiated video: AV1 4:4:4 8-bit (SDR)"))
    }
}

struct CrashFileTests {
    private let frames = [
        "0   SwiftUI                             0x00000001a0b1c2d4 $s7SwiftUI4ViewPAAE7onClickyyF + 40",
        "1   DELOS                               0x0000000104a1c2f8 $s7DelosUI15DebugInfoScreenV9testCrashyyF + 120",
        "2   UIKitCore                           0x00000001a1b2c3d4 -[UIApplication sendEvent:] + 300",
    ]
    private let log = (1...500).map { "2026-11-10 12:00:00.000 I/App [main] line \($0)" }.joined(separator: "\n") + "\n"

    @Test func theRecordKeepsTheExceptionOneLineAndTheNewest200LogLines() {
        let record = CrashFile.record(whenMs: 1_700_000_000_000, pid: 4321, thread: "main", exception: "NSInvalidArgumentException: first\nsecond",
                                      frames: frames, rawLog: log)
        #expect(record.exception == "NSInvalidArgumentException: first")
        #expect(record.logTail.count == CrashFile.logTailLines)
        #expect(record.logTail.first?.hasSuffix("line 301") == true)
        #expect(record.logTail.last?.hasSuffix("line 500") == true)
    }

    @Test func formatAndParseRoundTrip() {
        let record = CrashFile.record(whenMs: 1_700_000_000_000, pid: 4321, thread: "main", exception: "NSRangeException: boom", frames: frames, rawLog: log)
        #expect(CrashFile.parse(CrashFile.format(record)) == record)
    }

    @Test func aTruncatedOrForeignFileIsNotACrashRecord() {
        #expect(CrashFile.parse("") == nil)
        #expect(CrashFile.parse("something else\nTime: 1") == nil)
        let complete = CrashFile.format(CrashFile.record(whenMs: 1, pid: 1, thread: "t", exception: "E: x", frames: frames, rawLog: log))
        #expect(CrashFile.parse(String(complete[..<complete.range(of: "== Last log lines ==")!.lowerBound])) == nil)
        #expect(CrashFile.parse(complete.components(separatedBy: "\n").prefix(3).joined(separator: "\n")) == nil)
    }

    @Test func framesAreReadableAndTheSummaryNamesOurTopFrame() {
        let record = CrashFile.record(whenMs: 1, pid: 1, thread: "main", exception: "NSInvalidArgumentException: boom", frames: frames, rawLog: "")
        #expect(record.stackTrace.contains("at DelosUI.DebugInfoScreen.testCrash() -> () (DELOS)"))
        #expect(CrashFile.summary(record) == "NSInvalidArgumentException: boom (at DelosUI.DebugInfoScreen.testCrash)")
    }

    @Test func withoutOurFrameTheFirstFrameIsUsed() {
        let record = CrashFile.record(whenMs: 1, pid: 1, thread: "t", exception: "E: x", frames: [frames[2]], rawLog: "")
        #expect(CrashFile.summary(record) == "E: x (at -[UIApplication sendEvent:])")
    }

    @Test func theShortTraceKeepsTheExceptionLineAndTheFirstFrames() {
        let record = CrashFile.record(whenMs: 1, pid: 1, thread: "main", exception: "E: x", frames: frames, rawLog: "")
        let short = CrashFile.shortTrace(record, frames: 2)
        #expect(short.components(separatedBy: "\n").count == 3)
        #expect(short.hasPrefix("E: x"))
    }

    /// What the signal handler writes: raw frames, its own frames above `_sigtramp`, no log lines.
    @Test func aSignalHandlersFileBecomesAReadableRecord() throws {
        let text = """
            Delos crash report
            Time: 1700000000123
            Process: 77
            Thread: main
            Exception: SIGTRAP (signal 5)
            == Stack trace ==
            SIGTRAP (signal 5)
            0   DELOS                               0x0000000100000010 $s9DelosCore13CrashReporterO6signalyyF + 10
            1   libsystem_platform.dylib            0x0000000180000020 _sigtramp + 56
            2   DELOS                               0x0000000104a1c2f8 $s7DelosUI15DebugInfoScreenV9testCrashyyF + 120
            == Last log lines ==

            """
        let record = try #require(CrashFile.parse(text))
        #expect(record.pid == 77)
        #expect(record.logTail.isEmpty)
        #expect(!record.stackTrace.contains("_sigtramp"))
        #expect(!record.stackTrace.contains("CrashReporter"))
        #expect(CrashFile.summary(record) == "SIGTRAP (signal 5) (at DelosUI.DebugInfoScreen.testCrash)")
    }

    @Test func theSessionMarkerTextRoundTrips() {
        let record = SessionRecord(pid: 123, startedAtMs: 1000, updatedAtMs: 2000, inForeground: true)
        #expect(SessionRecord.parse(record.format()) == record)
        var background = record
        background.inForeground = false
        #expect(background.format() == "background 123 1000 2000")
        #expect(SessionRecord.parse("garbage") == nil)
        #expect(SessionRecord.parse("running 1 2 3") == nil)
    }
}
