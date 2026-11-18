import CDelosCommon
import CoreMedia
import CoreVideo
@testable import DelosCore
import Foundation
import QuartzCore
import Synchronization
import Testing
import VideoToolbox
@testable import DelosMedia

/// The decode-to-present path at 120 Hz on this machine, in real time: a stream the Mac's hardware encoder makes (1080p and
/// 1440 × 1080 at 120 fps, noise at the stream's bitrate, so the pictures are as heavy as a game's) goes as the core's
/// decode units through ``VideoOutput`` on a "receive" thread paced at 120 fps, into the Metal renderer's pipeline, whose
/// refreshes a second thread calls at 120 Hz, drawing into an offscreen target of the iPad Pro 13" panel's size. What the
/// stages did is printed (the ``StreamPerf`` lines and a summary), nothing about the machine's speed is asserted.
///
/// A harness, not part of the normal run (each case streams for 3 s):
///
///     DELOS_STREAM_BENCH=1 swift test --filter StreamThroughputBenchmark
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DELOS_STREAM_BENCH"] != nil))
struct StreamThroughputBenchmark {
    struct Case: CustomStringConvertible, Sendable {
        var codec: CMVideoCodecType
        var width: Int
        var height: Int
        var megabitsPerSecond: Int
        var asyncDecode: Bool

        var codecName: String { codec == kCMVideoCodecType_HEVC ? "HEVC" : "H.264" }
        var description: String {
            "\(codecName) \(width)x\(height)@120 \(megabitsPerSecond) Mbps, \(asyncDecode ? "async" : "sync") decode"
        }
    }

    static let cases: [Case] = [
        Case(codec: kCMVideoCodecType_HEVC, width: 1920, height: 1080, megabitsPerSecond: 40, asyncDecode: false),
        Case(codec: kCMVideoCodecType_HEVC, width: 1920, height: 1080, megabitsPerSecond: 40, asyncDecode: true),
        Case(codec: kCMVideoCodecType_H264, width: 1920, height: 1080, megabitsPerSecond: 40, asyncDecode: false),
        Case(codec: kCMVideoCodecType_H264, width: 1920, height: 1080, megabitsPerSecond: 40, asyncDecode: true),
        Case(codec: kCMVideoCodecType_HEVC, width: 1440, height: 1080, megabitsPerSecond: 80, asyncDecode: false),
        Case(codec: kCMVideoCodecType_HEVC, width: 1440, height: 1080, megabitsPerSecond: 80, asyncDecode: true),
    ]

    static let fps = 120
    static let frames = 360
    /// The iPad Pro 13" (M5) panel in pixels: the drawable the picture is scaled into.
    static let panel = (width: 2752, height: 2064)

    @Test(arguments: cases)
    func decodeToPresentAt120Hz(_ bench: Case) throws {
        let units = try BenchStream.encode(bench, count: Self.frames)

        // Parsing alone (copy out of the core's buffers into a sample), as the core's thread does it per frame
        var parser = VideoSamples(codec: bench.codec == kCMVideoCodecType_HEVC ? .hevc : .h264)
        var parse: [Double] = []
        for unit in units {
            let started = CACurrentMediaTime()
            _ = try unit.bytes.withUnsafeBytes { try parser.sample(for: $0, keyFrame: unit.key) }
            parse.append(CACurrentMediaTime() - started)
        }

        let lines = Mutex<[String]>([])
        let perf = StreamPerf { line in lines.withLock { $0.append(line) } }
        let pipeline = try #require(MetalPipeline(
            pacing: .balanced, fps: Self.fps, options: VideoRenderOptions(asyncDecode: bench.asyncDecode), perf: perf))
        defer { pipeline.invalidate() }
        pipeline.useOffscreenSize(width: Self.panel.width, height: Self.panel.height)
        pipeline.setLinkFrameRate(Double(Self.fps))
        let output = VideoOutput(
            renderer: BenchRenderer(pipeline: pipeline), supportedFormats: [.h264, .hevc], hdrMetadata: { nil }, perf: perf)
        #expect(output.setup(format: bench.codec == kCMVideoCodecType_HEVC ? .hevc : .h264, width: bench.width,
                             height: bench.height, frameRate: Self.fps))

        let interval = 1.0 / Double(Self.fps)
        let start = CACurrentMediaTime() + 0.1
        let received = Mutex(false)
        // Written by the receive thread only, read after both threads ended
        let core = Mutex((submit: [Double](), behind: 0.0, refused: 0))
        let receive = Thread {
            for (i, unit) in units.enumerated() {
                let scheduled = start + Double(i) * interval
                BenchClock.wait(until: scheduled)
                let began = CACurrentMediaTime()
                let result = output.submit(unit, number: i)
                let ended = CACurrentMediaTime()
                core.withLock { c in
                    c.behind = max(c.behind, began - scheduled)
                    if result != .ok { c.refused += 1 }
                    c.submit.append(ended - began)
                }
            }
            received.withLock { $0 = true }
        }
        let refreshes = Mutex(0)
        let display = Thread {
            var k = 0
            var finishedAt: Double?
            while true {
                // A refresh phase that is not the stream's: the two clocks are never aligned
                let scheduled = start + 0.0031 + Double(k) * interval
                BenchClock.wait(until: scheduled)
                pipeline.tick(RefreshTick(presentation: scheduled + 2 * interval, refresh: interval, drawable: nil))
                k += 1
                if received.withLock({ $0 }) {
                    finishedAt = finishedAt ?? scheduled
                    if scheduled - (finishedAt ?? scheduled) > 0.1 { break }
                }
            }
            refreshes.withLock { $0 = k }
        }
        receive.qualityOfService = .userInteractive
        display.qualityOfService = .userInteractive
        receive.start()
        display.start()
        while refreshes.withLock({ $0 }) == 0 { Thread.sleep(forTimeInterval: 0.05) }
        pipeline.waitForDecodes()
        output.cleanup()
        // The last partial second is logged on the line's own queue
        Thread.sleep(forTimeInterval: 0.2)

        let counters = pipeline.counters()
        let wall = Double(Self.frames) * interval
        func ms(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))] * 1000
        }
        print("BENCH \(bench)")
        for line in lines.withLock({ $0 }) { print("  \(line)") }
        let (submit, behind, refused) = core.withLock { ($0.submit, $0.behind, $0.refused) }
        print(String(
            format: "  SUMMARY submitted %d (refused %d) in %.2f s; core thread per frame p50 %.2f p99 %.2f max %.2f ms (parse alone p50 %.2f p99 %.2f ms), worst lateness %.2f ms; decoded %d (avg %.2f ms); shown %d, dropped %d, refreshes %d, repeated %d, GPU late %d; shown rate %.1f fps",
            units.count, refused, wall, ms(submit, 0.5), ms(submit, 0.99), ms(submit, 1), ms(parse, 0.5), ms(parse, 0.99),
            behind * 1000, counters.decodedFrames ?? 0,
            (counters.accumulatedDecodeSeconds ?? 0) * 1000 / Double(max(counters.decodedFrames ?? 1, 1)),
            counters.totalFrames - counters.droppedFrames, counters.droppedFrames, counters.refreshes ?? 0,
            counters.repeatedRefreshes ?? 0, counters.lateRefreshes ?? 0,
            Double(counters.totalFrames - counters.droppedFrames) / wall))
        #expect(refused == 0)
        #expect(counters.decodedFrames == units.count)
    }
}

/// The Metal pipeline as a ``VideoRenderer`` without a layer.
private final class BenchRenderer: VideoRenderer {
    let pipeline: MetalPipeline

    init(pipeline: MetalPipeline) { self.pipeline = pipeline }

    var name: String { "bench" }
    func enqueue(_ sample: CMSampleBuffer) -> Bool { pipeline.enqueue(sample) }
    func flush() { pipeline.flush() }
    func presentationCounters() async -> VideoPresentationCounters? { pipeline.counters() }
    @MainActor var hostLayer: CALayer { CALayer() }
    @MainActor func resize(to bounds: CGRect, scale: CGFloat) {}
}

/// A host frame as the core hands it over: Annex B, the parameter sets before a key frame's slices.
struct BenchUnit: Sendable {
    var bytes: [UInt8]
    var key: Bool
}

extension VideoOutput {
    /// Submits a frame as the core's decode unit `number` (one buffer, the host's presentation time at 120 fps).
    fileprivate func submit(_ frame: BenchUnit, number: Int) -> DecodeResult {
        frame.bytes.withUnsafeBufferPointer { buffer in
            // The core's buffers are not written through: the frame is only read
            let data = UnsafeMutableRawPointer(mutating: buffer.baseAddress!).assumingMemoryBound(to: CChar.self)
            var entry = LENTRY(next: nil, data: data, length: Int32(buffer.count), bufferType: BUFFER_TYPE_PICDATA)
            return withUnsafeMutablePointer(to: &entry) { pointer in
                var unit = DECODE_UNIT()
                unit.frameNumber = Int32(number + 1)
                unit.frameType = frame.key ? FRAME_TYPE_IDR : FRAME_TYPE_PFRAME
                unit.fullLength = Int32(buffer.count)
                unit.presentationTimeUs = UInt64(number) * 1_000_000 / UInt64(StreamThroughputBenchmark.fps)
                unit.bufferList = pointer
                return withUnsafePointer(to: &unit) { submit(DecodeUnit($0)) }
            }
        }
    }
}

enum BenchClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Sleeps until `seconds` on the `CACurrentMediaTime` clock.
    static func wait(until seconds: Double) {
        let delta = seconds - CACurrentMediaTime()
        guard delta > 0 else { return }
        let ticks = UInt64(delta * 1_000_000_000) * UInt64(timebase.denom) / UInt64(timebase.numer)
        mach_wait_until(mach_absolute_time() + ticks)
    }
}

enum BenchStream {
    /// `count` frames of noise (8 different pictures in turn), one key frame first, no B-frames, at the case's bitrate.
    static func encode(_ bench: StreamThroughputBenchmark.Case, count: Int) throws -> [BenchUnit] {
        let frames = SyntheticStream.Collected()
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(bench.width), height: Int32(bench.height), codecType: bench.codec,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw SyntheticStream.EncodeFailure.session(status) }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 100_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 120 as CFNumber)
        let bitrate = bench.megabitsPerSecond * 1_000_000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        // Noise compresses badly: a hard limit keeps each second at the stream's bitrate, as a host's encoder does
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_DataRateLimits, value: [bitrate / 8 / 10, 0.1] as CFArray)
        VTCompressionSessionPrepareToEncodeFrames(session)
        let pictures = try (0..<8).map { _ in try noise(width: bench.width, height: bench.height) }
        for i in 0..<count {
            let encoded = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pictures[i % pictures.count], presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 120),
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil
            ) { status, _, sample in
                if status == noErr, let sample { frames.add(sample) }
            }
            guard encoded == noErr else { throw SyntheticStream.EncodeFailure.frame(encoded) }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return try frames.take().map { try annexB($0, hevc: bench.codec == kCMVideoCodecType_HEVC) }
    }

    /// A picture of random luma and chroma.
    static func noise(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        guard CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { throw SyntheticStream.EncodeFailure.frame(-1) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            arc4random_buf(base, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        return buffer
    }

    /// The encoder's length-prefixed sample as the host sends it: start codes, and a key frame's parameter sets first.
    static func annexB(_ sample: CMSampleBuffer, hevc: Bool) throws -> BenchUnit {
        let key = MetalPipeline.isKeyFrame(sample)
        var bytes: [UInt8] = []
        if key, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            var index = 0
            repeat {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = hevc
                    ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                        parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                        parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                guard status == noErr, let pointer else { break }
                bytes += [0, 0, 0, 1] + UnsafeBufferPointer(start: pointer, count: size)
                index += 1
            } while index < count
        }
        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        var data = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: data.count, destination: &data)
        var offset = 0
        while offset + 4 <= data.count {
            let length = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            bytes += [0, 0, 0, 1] + data[(offset + 4)..<(offset + 4 + length)]
            offset += 4 + length
        }
        return BenchUnit(bytes: bytes, key: key)
    }
}
