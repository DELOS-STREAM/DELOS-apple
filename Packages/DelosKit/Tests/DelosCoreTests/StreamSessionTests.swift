import CDelosCommon
import Darwin
import Synchronization
import Testing
@testable import DelosCore

/// The C core keeps one connection in global state, so every test that starts it or claims the bridge runs serially.
@Suite(.serialized) struct StreamSessionTests {
    private let configuration = StreamConfiguration(
        width: 1280, height: 720, fps: 60, bitrateKbps: 10_000, remoteInputKey: .random())

    /// A TCP port on 127.0.0.1 that nothing listens on: bound by the system, then closed.
    private func closedLocalPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(fd, pointer, length) == 0 && getsockname(fd, pointer, &length) == 0
            }
        }
        try #require(bound)
        return UInt16(bigEndian: address.sin_port)
    }

    /// The core retries a refused RTSP connection for 10 seconds before it gives up, so this test takes that long.
    @Test func aClosedPortFailsTheRTSPHandshake() async throws {
        let port = try closedLocalPort()
        let server = ServerInformation(
            address: "127.0.0.1", appVersion: "7.1.431.-1", rtspSessionURL: "rtsp://127.0.0.1:\(port)",
            codecModeSupport: .h264)
        let session = StreamSession()

        let error = await #expect(throws: StreamError.self) {
            try await session.start(server: server, configuration: configuration)
        }
        #expect(error == .stageFailed(.rtspHandshake, errorCode: ECONNREFUSED))

        var events: [StreamEvent] = []
        for await event in session.events { events.append(event) }
        #expect(
            events == [
                .stageStarting(.platformInit), .stageComplete(.platformInit),
                .stageStarting(.nameResolution), .stageComplete(.nameResolution),
                .stageStarting(.audioStreamInit), .stageComplete(.audioStreamInit),
                .stageStarting(.rtspHandshake), .stageFailed(.rtspHandshake, errorCode: ECONNREFUSED),
            ])
        // The session released the core: a new one can start
        #expect(CoreBridge.current == nil)
    }

    /// Interrupting the start: `true` calls `stop()`, `false` cancels the starting task.
    @Test(arguments: [true, false])
    func interruptingTheHandshakeEndsTheStartEarly(byStop: Bool) async throws {
        let port = try closedLocalPort()
        let server = ServerInformation(
            address: "127.0.0.1", appVersion: "7.1.431.-1", rtspSessionURL: "rtsp://127.0.0.1:\(port)",
            codecModeSupport: .h264)
        let session = StreamSession()
        let clock = ContinuousClock()
        let started = clock.now
        let start = Task { () -> StreamError? in
            do throws(StreamError) {
                try await session.start(server: server, configuration: configuration)
                return nil
            } catch {
                return error
            }
        }

        // The core retries the refused RTSP connection for 10 s; interrupt it once the handshake has begun
        for await event in session.events where event == .stageStarting(.rtspHandshake) {
            if byStop {
                await session.stop()
            } else {
                start.cancel()
            }
            break
        }
        let error = await start.value

        #expect(error == .cancelled)
        #expect(clock.now - started < .seconds(5))
        #expect(CoreBridge.current == nil)
    }

    /// A configuration the core refuses before the first stage: packets smaller than one 16-byte FEC block.
    private var tooSmallPackets: StreamConfiguration {
        var configuration = configuration
        configuration.packetSize = 8
        return configuration
    }

    @Test func anInvalidConfigurationIsRejectedBeforeTheFirstStage() async {
        let server = ServerInformation(address: "127.0.0.1", appVersion: "7.1.431.-1", codecModeSupport: .h264)
        let session = StreamSession()

        let error = await #expect(throws: StreamError.self) {
            try await session.start(server: server, configuration: tooSmallPackets)
        }
        #expect(error == .rejected(code: -1))
        var events: [StreamEvent] = []
        for await event in session.events { events.append(event) }
        #expect(events.isEmpty)
    }

    @Test func aSessionStartsOnlyOnce() async {
        let server = ServerInformation(address: "127.0.0.1", appVersion: "7.1.431.-1", codecModeSupport: .h264)
        let session = StreamSession()
        _ = try? await session.start(server: server, configuration: tooSmallPackets)

        let error = await #expect(throws: StreamError.self) {
            try await session.start(server: server, configuration: configuration)
        }
        #expect(error == .alreadyStarted)
    }

    @Test func onlyOneSessionHoldsTheCore() async {
        let (_, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
        let holder = CoreContext(events: continuation, video: nil, audio: nil, onTermination: {})
        #expect(CoreBridge.claim(holder))
        defer { CoreBridge.release(holder) }

        let server = ServerInformation(address: "127.0.0.1", appVersion: "7.1.431.-1", codecModeSupport: .h264)
        let error = await #expect(throws: StreamError.self) {
            try await StreamSession().start(server: server, configuration: configuration)
        }
        #expect(error == .anotherSessionActive)
    }

    @Test func stoppingAnIdleSessionFinishesItsEvents() async {
        let session = StreamSession()
        await session.stop()
        var count = 0
        for await _ in session.events { count += 1 }
        #expect(count == 0)
    }

    @Test func inputWithoutAStreamReportsNotConnected() {
        let session = StreamSession()
        #expect(throws: InputError.notConnected) { try session.sendMouseMove(deltaX: 3, deltaY: -2) }
        #expect(throws: InputError.notConnected) { try session.sendMouseButton(.left, pressed: true) }
        #expect(throws: InputError.notConnected) {
            try session.sendKey(code: 0x41, pressed: true, modifiers: .shift)
        }
        #expect(throws: InputError.notConnected) {
            try session.sendController(number: 0, activeGamepadMask: 0x1, state: ControllerState(buttons: .a))
        }
        #expect(throws: InputError.notConnected) { try session.sendScroll(clicks: 1) }
        #expect(throws: InputError.notConnected) {
            try session.sendTouch(.down, pointerID: 1, x: 0.5, y: 0.5, pressureOrDistance: 1)
        }
    }

    @Test func listenerCallbacksBecomeEvents() async {
        let (events, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
        let terminated = Mutex(false)
        let context = CoreContext(
            events: continuation, video: nil, audio: nil, onTermination: { terminated.withLock { $0 = true } })
        #expect(CoreBridge.claim(context))
        defer { CoreBridge.release(context) }

        let callbacks = CoreBridge.listenerCallbacks()
        callbacks.stageStarting(STAGE_CONTROL_STREAM_START)
        callbacks.stageFailed(STAGE_CONTROL_STREAM_START, 42)
        callbacks.connectionStatusUpdate(CONN_STATUS_POOR)
        callbacks.rumble(1, 0x1000, 0x2000)
        callbacks.setControllerLED(2, 255, 128, 0)
        var left: [UInt8] = Array(1...10)
        var right: [UInt8] = Array(11...20)
        callbacks.setAdaptiveTriggers(0, UInt8(DS_EFFECT_LEFT_TRIGGER), 0x21, 0x26, &left, &right)
        callbacks.connectionTerminated(ML_ERROR_NO_VIDEO_TRAFFIC)

        var received: [StreamEvent] = []
        for await event in events { received.append(event) }
        #expect(
            received == [
                .stageStarting(.controlStreamStart),
                .stageFailed(.controlStreamStart, errorCode: 42),
                .connectionStatus(.poor),
                .rumble(controller: 1, lowFrequency: 0x1000, highFrequency: 0x2000),
                .controllerLED(controller: 2, red: 255, green: 128, blue: 0),
                .adaptiveTriggers(
                    controller: 0, eventFlags: 0x08, typeLeft: 0x21, typeRight: 0x26, left: Array(1...10),
                    right: Array(11...20)),
                .terminated(.noVideoTraffic),
            ])
        #expect(context.failedStage.withLock { $0?.stage } == .controlStreamStart)
        #expect(terminated.withLock { $0 })
    }

    @Test func videoCallbacksReachTheSink() throws {
        let sink = RecordingVideoSink()
        let (_, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
        let context = CoreContext(events: continuation, video: sink, audio: nil, onTermination: {})
        #expect(CoreBridge.claim(context))
        defer { CoreBridge.release(context) }

        let callbacks = CoreBridge.videoCallbacks(capabilities: [.directSubmit])
        #expect(callbacks.capabilities == CAPABILITY_DIRECT_SUBMIT)
        #expect(callbacks.setup(VIDEO_FORMAT_H265_MAIN10, 3840, 2160, 120, nil, 0) == 0)

        var sps: [CChar] = [0x67, 0x64]
        var picture: [CChar] = [0x65, 0x01, 0x02]
        let result = sps.withUnsafeMutableBufferPointer { spsBytes in
            picture.withUnsafeMutableBufferPointer { pictureBytes in
                var second = LENTRY(
                    next: nil, data: pictureBytes.baseAddress, length: 3, bufferType: BUFFER_TYPE_PICDATA)
                return withUnsafeMutablePointer(to: &second) { secondPointer in
                    var first = LENTRY(
                        next: secondPointer, data: spsBytes.baseAddress, length: 2, bufferType: BUFFER_TYPE_SPS)
                    var unit = DECODE_UNIT()
                    unit.frameNumber = 77
                    unit.frameType = FRAME_TYPE_IDR
                    unit.fullLength = 5
                    unit.colorspace = UInt8(COLORSPACE_REC_2020)
                    return withUnsafeMutablePointer(to: &first) { firstPointer in
                        unit.bufferList = firstPointer
                        return callbacks.submitDecodeUnit(&unit)
                    }
                }
            }
        }

        #expect(result == DR_NEED_IDR)
        let recorded = sink.recorded.withLock { $0 }
        #expect(recorded.format == .hevcMain10)
        #expect(recorded.size == [3840, 2160, 120])
        #expect(recorded.frameNumber == 77)
        #expect(recorded.isIDR)
        #expect(recorded.colorSpace == .rec2020)
        #expect(recorded.buffers == [.sps: [0x67, 0x64], .pictureData: [0x65, 0x01, 0x02]])
        #expect(recorded.order == [.sps, .pictureData])
    }

    @Test func audioCallbacksReachTheSink() {
        let sink = RecordingAudioSink()
        let (_, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
        let context = CoreContext(events: continuation, video: nil, audio: sink, onTermination: {})
        #expect(CoreBridge.claim(context))
        defer { CoreBridge.release(context) }

        let callbacks = CoreBridge.audioCallbacks(capabilities: [])
        var opus = OPUS_MULTISTREAM_CONFIGURATION()
        opus.sampleRate = 48000
        opus.channelCount = 6
        opus.streams = 4
        opus.coupledStreams = 2
        opus.samplesPerFrame = 240
        opus.mapping = (0, 4, 1, 5, 2, 3, 9, 9)
        #expect(callbacks.`init`(AudioConfiguration.surround51.rawValue, &opus, nil, 0) == 0)
        #expect(callbacks.`init`(0x1234, &opus, nil, 0) == -1)

        var packet: [CChar] = [1, 2, 3]
        callbacks.decodeAndPlaySample(&packet, 3)
        callbacks.decodeAndPlaySample(nil, 0)

        let recorded = sink.recorded.withLock { $0 }
        #expect(recorded.layout == .surround51)
        #expect(
            recorded.opus
                == OpusMultistreamConfiguration(
                    sampleRate: 48000, channelCount: 6, streams: 4, coupledStreams: 2, samplesPerFrame: 240,
                    mapping: [0, 4, 1, 5, 2, 3]))
        #expect(recorded.packets == [[1, 2, 3], nil])
    }
}

private final class RecordingVideoSink: VideoDecodeUnitSink {
    struct Recorded {
        var format: VideoFormats = []
        var size: [Int] = []
        var frameNumber = 0
        var isIDR = false
        var colorSpace: ColorSpace?
        var buffers: [DecodeBufferType: [UInt8]] = [:]
        var order: [DecodeBufferType] = []
    }

    let recorded = Mutex(Recorded())
    var capabilities: VideoDecoderCapabilities { [] }

    func setup(format: VideoFormats, width: Int, height: Int, frameRate: Int) -> Bool {
        recorded.withLock {
            $0.format = format
            $0.size = [width, height, frameRate]
        }
        return true
    }

    func start() {}
    func stop() {}
    func cleanup() {}

    func submit(_ unit: borrowing DecodeUnit) -> DecodeResult {
        var buffers: [DecodeBufferType: [UInt8]] = [:]
        var order: [DecodeBufferType] = []
        unit.forEachBuffer { type, bytes in
            buffers[type] = Array(bytes)
            order.append(type)
        }
        let frameNumber = unit.frameNumber
        let isIDR = unit.isIDRFrame
        let colorSpace = unit.colorSpace
        recorded.withLock {
            $0.frameNumber = frameNumber
            $0.isIDR = isIDR
            $0.colorSpace = colorSpace
            $0.buffers = buffers
            $0.order = order
        }
        return .needIDRFrame
    }
}

private final class RecordingAudioSink: AudioSampleSink {
    struct Recorded {
        var layout: AudioConfiguration?
        var opus: OpusMultistreamConfiguration?
        var packets: [[UInt8]?] = []
    }

    let recorded = Mutex(Recorded())
    var capabilities: AudioRendererCapabilities { [] }

    func setup(configuration: AudioConfiguration, opus: OpusMultistreamConfiguration) -> Bool {
        recorded.withLock {
            $0.layout = configuration
            $0.opus = opus
        }
        return true
    }

    func start() {}
    func stop() {}
    func cleanup() {}

    func decodeAndPlay(_ packet: UnsafeRawBufferPointer?) {
        let bytes = packet.map { Array($0) }
        recorded.withLock { $0.packets.append(bytes) }
    }
}
