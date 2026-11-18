import CoreMedia
@testable import DelosCore
import Foundation
import Synchronization
import Testing
@testable import DelosMedia

/// The decoder's own thread, the start code scan the core's thread runs per frame, and the throughput line.
@Suite struct DecoderThreadTests {
    /// The thread that hands a frame over never decodes it: the core's receive thread goes back to its socket at once.
    @Test(arguments: [false, true])
    func theCallersThreadOnlyHandsTheFrameOver(asynchronous: Bool) throws {
        var stream = try ReplayStream(fixture: "frames.hevc", codec: .hevc)
        let threads = Mutex<[UInt]>([])
        let decoder = VideoDecoder(
            asynchronous: asynchronous, onFrame: { _ in threads.withLock { $0.append(Self.threadID) } }, onFailure: { _ in })
        defer { decoder.invalidate() }
        for index in 0..<4 { #expect(decoder.decode(try stream.sample(index))) }
        decoder.finishFrames()
        let decoded = threads.withLock { $0 }
        #expect(decoded.count == 4)
        #expect(!decoded.contains(Self.threadID))
    }

    /// A decoder that falls a quarter of a second behind drops what waits and asks for a key frame; it takes frames again
    /// at once.
    @Test func aDecoderFarBehindDropsTheWaitingFramesAndAsksForAKeyFrame() throws {
        var stream = try ReplayStream(fixture: "frames.hevc", codec: .hevc)
        let release = DispatchSemaphore(value: 0)
        let decoded = Mutex(0)
        let failures = Mutex(0)
        // Synchronous: the first picture holds the decoder's thread until released
        let decoder = VideoDecoder(asynchronous: false, onFrame: { _ in
            if decoded.withLock({ $0 += 1; return $0 }) == 1 { release.wait() }
        }, onFailure: { _ in failures.withLock { $0 += 1 } })
        defer { decoder.invalidate() }
        #expect(decoder.decode(try stream.sample(0)))
        while decoded.withLock({ $0 }) == 0 { Thread.sleep(forTimeInterval: 0.001) }
        for index in 1...VideoDecoder.maximumPending { #expect(decoder.decode(try stream.sample(index))) }
        #expect(!decoder.decode(try stream.sample(1)))
        #expect(failures.withLock { $0 } == 1)
        release.signal()
        decoder.finishFrames()
        // The frames that waited were dropped, not decoded late
        #expect(decoded.withLock { $0 } == 1)
        #expect(decoder.decode(try stream.sample(0)))
        decoder.finishFrames()
        #expect(decoded.withLock { $0 } == 2)
    }

    @Test func discardedFramesAreNeverDecoded() throws {
        var stream = try ReplayStream(fixture: "frames.hevc", codec: .hevc)
        let release = DispatchSemaphore(value: 0)
        let decoded = Mutex(0)
        let decoder = VideoDecoder(asynchronous: false, onFrame: { _ in
            if decoded.withLock({ $0 += 1; return $0 }) == 1 { release.wait() }
        }, onFailure: { _ in })
        defer { decoder.invalidate() }
        #expect(decoder.decode(try stream.sample(0)))
        while decoded.withLock({ $0 }) == 0 { Thread.sleep(forTimeInterval: 0.001) }
        for index in 1...3 { #expect(decoder.decode(try stream.sample(index))) }
        decoder.discardPending()
        release.signal()
        decoder.finishFrames()
        #expect(decoded.withLock { $0 } == 1)
    }

    private static var threadID: UInt { UInt(bitPattern: pthread_self()) }
}

@Suite struct AnnexBScanTests {
    /// The byte-by-byte definition the `memchr` scan replaced.
    static func reference(_ bytes: [UInt8]) -> [Range<Int>] {
        var units: [Range<Int>] = []
        var unitStart: Int?
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let code = i > 0 && bytes[i - 1] == 0 ? i - 1 : i
                if let unitStart, unitStart < code { units.append(unitStart..<code) }
                unitStart = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        if let unitStart, unitStart < bytes.count { units.append(unitStart..<bytes.count) }
        return units
    }

    static func scan(_ bytes: [UInt8]) -> [Range<Int>] {
        bytes.withUnsafeBytes { raw in
            var units: [Range<Int>] = []
            AnnexB.forEachUnit(in: raw) { units.append($0) }
            return units
        }
    }

    @Test func edgeCasesMatchTheByteByByteScan() {
        let cases: [[UInt8]] = [
            [], [0], [0, 0, 1], [0, 0, 0, 1], [0, 0, 1, 0x65], [0, 0, 0, 1, 0x40, 0, 0, 1, 0x42, 1, 0, 0, 0, 1, 0x26, 9],
            [0, 0, 1, 0, 0, 1, 0, 0, 1], [1, 1, 0, 0, 1, 7, 0, 0], [0, 0, 0, 0, 0, 1, 5, 0, 0, 0], [7, 0, 1, 0, 0, 1],
        ]
        for bytes in cases { #expect(Self.scan(bytes) == Self.reference(bytes), "\(bytes)") }
    }

    @Test func randomStreamsWithStartCodesMatchTheByteByByteScan() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            var bytes = (0..<Int.random(in: 0...600, using: &generator)).map { _ in UInt8.random(in: 0...3, using: &generator) }
            for _ in 0..<Int.random(in: 0...8, using: &generator) where !bytes.isEmpty {
                let at = Int.random(in: 0..<bytes.count, using: &generator)
                bytes.insert(contentsOf: Bool.random(using: &generator) ? [0, 0, 1] : [0, 0, 0, 1], at: at)
            }
            #expect(Self.scan(bytes) == Self.reference(bytes))
        }
    }
}

@Suite struct StreamPerfTests {
    @Test func aSecondOfCountsBecomesOneLine() {
        let lines = Mutex<[String]>([])
        let perf = StreamPerf { line in lines.withLock { $0.append(line) } }
        perf.setLinkFrameRate(120)
        // 120 frames from the host, frame 61 lost, 8.33 ms apart on the host's clock
        for number in 1...121 where number != 61 {
            perf.received(
                frameNumber: number, bytes: 50_000, firstPacketUs: 1000, completeUs: 2500,
                hostTimeUs: UInt64(number) * 8333)
            perf.submitted(seconds: 0.0001)
            perf.decodeSubmitted()
            perf.decodeWaiting(1)
            perf.decodeReturned(seconds: number >= 120 ? 0.020 : 0.002)
            perf.queued()
        }
        perf.decodeWaiting(3)
        perf.dropped(.queueFull)
        perf.dropped(.skipped, count: 2)
        for tick in 0..<120 {
            perf.tick(presentation: Double(tick) / 120, shown: tick < 117, repeated: tick >= 117)
            perf.gpuFinished(seconds: 0.0005, late: tick == 0)
        }
        perf.flush(seconds: 1, thermal: .fair, lowPower: true)
        let line = lines.withLock { $0 }.first ?? ""
        #expect(line.hasPrefix(
            "StreamPerf req=0 link=120 in=120.0 gap=1 host=120.0 mbps=48.0 fecfail=- oos=- asm=1.50/1.50 submit=0.10/0.10/0.10 "))
        #expect(line.contains(" dec=120/120 decfail=0 decq=3 dect=2.00/20.00 queue=120 shown=117 drop=3 full=1 skip=2 gpu-busy=0 repeat=3 "))
        #expect(line.contains(" tick=120 tickhz=120.0 gpu=0.50/0.50 late=1 thermal=fair lpm=1"))
        // The next second starts empty and logs nothing while nothing happens
        perf.flush(seconds: 1, thermal: .nominal, lowPower: false)
        #expect(lines.withLock { $0 }.count == 1)
    }

    /// The core's packet counters are cumulative: the line shows what changed in its second.
    @Test func theCoresPacketCountersAreShownPerSecond() {
        let lines = Mutex<[String]>([])
        let perf = StreamPerf { line in lines.withLock { $0.append(line) } }
        let counters = Mutex(RTPStatistics(
            packets: 0, fecPackets: 0, fecRecovered: 0, fecFailed: 2, outOfSequence: 5, invalid: 0, fecInvalid: 0))
        perf.setPacketSource { counters.withLock { $0 } }
        perf.received(frameNumber: 1, bytes: 1, firstPacketUs: 0, completeUs: 0, hostTimeUs: 0)
        perf.flush(seconds: 1, thermal: .nominal, lowPower: false)
        counters.withLock { $0.fecFailed = 3; $0.outOfSequence = 9 }
        perf.received(frameNumber: 2, bytes: 1, firstPacketUs: 0, completeUs: 0, hostTimeUs: 0)
        perf.flush(seconds: 1, thermal: .nominal, lowPower: false)
        let all = lines.withLock { $0 }
        #expect(all.count == 2)
        #expect(all.first?.contains(" fecfail=2 oos=5 ") == true)
        #expect(all.last?.contains(" fecfail=1 oos=4 ") == true)
    }

    @Test func aNoteIsOneLine() {
        let lines = Mutex<[String]>([])
        let perf = StreamPerf { line in lines.withLock { $0.append(line) } }
        perf.note("launch mode=1440x1080x120")
        #expect(lines.withLock { $0 } == ["StreamPerf launch mode=1440x1080x120"])
    }

    @Test func percentilesUseTheNearestRank() {
        let sorted = (1...100).map(Double.init)
        #expect(StreamPerf.Samples.percentile(sorted, 0.5) == 50)
        #expect(StreamPerf.Samples.percentile(sorted, 0.99) == 99)
        #expect(StreamPerf.Samples.percentile([], 0.5) == nil)
        #expect(StreamPerf.Samples.percentile([4], 0.99) == 4)
    }
}
