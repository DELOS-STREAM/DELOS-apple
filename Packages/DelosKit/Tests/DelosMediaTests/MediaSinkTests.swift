import AVFAudio
import Testing
@testable import DelosCore
@testable import DelosMedia

@Suite struct AudioRingTests {
    @Test func readsInOrderAndPadsWithSilence() {
        let ring = AudioRing(channels: 2, capacityFrames: 8, maxFrames: 8)
        [1, 2, 3, 4].map(Float.init).withUnsafeBufferPointer { ring.write($0) }
        var out = [Float](repeating: 9, count: 6)
        let real = out.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        #expect(real == 4)
        #expect(out == [1, 2, 3, 4, 0, 0])
        #expect(ring.queuedFrames == 0)
    }

    @Test func aBurstPastTheLimitDropsTheOldestSamples() {
        // At most 2 frames of 2 channels: writing 4 frames keeps the newest 2
        let ring = AudioRing(channels: 2, capacityFrames: 8, maxFrames: 2)
        (1...8).map(Float.init).withUnsafeBufferPointer { ring.write($0) }
        #expect(ring.queuedFrames == 2)
        var out = [Float](repeating: 0, count: 4)
        _ = out.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        #expect(out == [5, 6, 7, 8])
    }

    @Test func wrapsAroundTheEndOfTheBuffer() {
        let ring = AudioRing(channels: 1, capacityFrames: 4, maxFrames: 4)
        var out = [Float](repeating: 0, count: 3)
        [1, 2, 3].map(Float.init).withUnsafeBufferPointer { ring.write($0) }
        _ = out.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        [4, 5, 6].map(Float.init).withUnsafeBufferPointer { ring.write($0) }
        _ = out.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        #expect(out == [4, 5, 6])
    }

    @Test func aFullRingKeepsTheFramesThatFitWhileNothingReads() {
        let ring = AudioRing(channels: 1, capacityFrames: 4, maxFrames: 2)
        [1, 2, 3].map(Float.init).withUnsafeBufferPointer { ring.write($0) }
        [4, 5, 6].map(Float.init).withUnsafeBufferPointer { ring.write($0) }
        var out = [Float](repeating: 9, count: 4)
        let real = out.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        // The ring held 1…4; the reader keeps the newest two
        #expect(real == 2)
        #expect(out == [3, 4, 0, 0])
    }

    /// The decoder's thread writes while the render thread reads, without a lock: every frame arrives once, in order,
    /// with its channels together.
    @Test func aWriterAndAReaderOnTwoThreadsSeeEveryFrameInOrder() async {
        let ring = AudioRing(channels: 2, capacityFrames: 64, maxFrames: 64)
        let frames = 200_000
        let writer = Task.detached {
            var block = [Float](repeating: 0, count: 2 * 5)
            var next = 1
            while next <= frames {
                let count = min(5, frames - next + 1)
                // Wait for room: nothing is dropped, so the reader must see every frame
                while ring.queuedFrames + count > ring.maxFrames { await Task.yield() }
                for i in 0..<count {
                    block[2 * i] = Float(next + i)
                    block[2 * i + 1] = Float(next + i)
                }
                block.withUnsafeBufferPointer { ring.write(UnsafeBufferPointer(rebasing: $0.prefix(count * 2))) }
                next += count
            }
        }
        let reader = Task.detached { () -> (next: Int, torn: Int) in
            var out = [Float](repeating: 0, count: 2 * 7)
            var next = 1
            var torn = 0
            let deadline = ContinuousClock.now + .seconds(20)
            while next <= frames, ContinuousClock.now < deadline {
                let real = out.withUnsafeMutableBufferPointer { ring.read(into: $0) }
                if real == 0 { await Task.yield() }
                for frame in 0..<(real / 2) {
                    if out[2 * frame] != Float(next) || out[2 * frame + 1] != Float(next) { torn += 1 }
                    next += 1
                }
            }
            return (next, torn)
        }
        await writer.value
        let result = await reader.value

        #expect(result.next == frames + 1)
        #expect(result.torn == 0)
    }
}

@Suite struct VideoOutputTests {
    @Test func theHostsFormatSelectsTheCodec() {
        #expect(VideoOutput.codec(for: .h264) == .h264)
        #expect(VideoOutput.codec(for: .hevcMain10) == .hevc)
        #expect(VideoOutput.codec(for: .av1Main10) == .av1)
        #expect(VideoOutput.codec(for: .pyroWave) == nil)
    }
}

@Suite struct AudioOutputTests {
    /// The engine accepts the stream's audio format: the first device stream crashed in setup when it did not.
    @Test(arguments: [AudioConfiguration.stereo, .surround51, .surround71])
    func setupConnectsTheEngine(audio: AudioConfiguration) {
        let channels = audio.channelCount
        let opus = OpusMultistreamConfiguration(
            // The host's layouts: stereo 1 coupled stream, 5.1 four streams (two coupled), 7.1 five (three coupled)
            sampleRate: 48000, channelCount: channels, streams: [2: 1, 6: 4, 8: 5][channels]!,
            coupledStreams: [2: 1, 6: 2, 8: 3][channels]!, samplesPerFrame: 240, mapping: (0..<channels).map(UInt8.init))
        let output = AudioOutput()
        #expect(output.setup(configuration: audio, opus: opus))
        output.cleanup()
    }

    @Test func theRenderBlockSplitsInterleavedSamplesIntoChannels() throws {
        let ring = AudioRing(channels: 2, capacityFrames: 16, maxFrames: 16)
        [1, -1, 2, -2, 3, -3].map(Float.init).withUnsafeBufferPointer { ring.write($0) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        pcm.frameLength = 4
        var silence = ObjCBool(false)
        var time = AudioTimeStamp()
        let block = AudioOutput.renderBlock(ring: ring)
        #expect(block(&silence, &time, 4, pcm.mutableAudioBufferList) == noErr)
        let left = Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: 4))
        let right = Array(UnsafeBufferPointer(start: pcm.floatChannelData![1], count: 4))
        #expect(left == [1, 2, 3, 0])
        #expect(right == [-1, -2, -3, 0])
    }

    /// The host's 5.1 order (front left, front right, center, LFE, back left, back right) with a different constant on
    /// each channel, through the stream's format into an engine that renders offline into [output].
    private func renderSurround(into output: AVAudioFormat, speakers: [AudioChannelLabel] = []) throws -> [[Float]] {
        let values: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
        let ring = AudioRing(channels: 6, capacityFrames: 4096, maxFrames: 4096)
        let frames = 512
        let interleaved = (0..<frames).flatMap { _ in values }
        interleaved.withUnsafeBufferPointer { ring.write($0) }
        let format = try #require(AudioOutput.format(sampleRate: 48000, channels: 6))
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: AVAudioFrameCount(frames))
        let source = AVAudioSourceNode(format: format, renderBlock: AudioOutput.renderBlock(ring: ring))
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        if let named = AudioOutput.outputFormat(hardware: engine.outputNode.outputFormat(forBus: 0), speakers: speakers) {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: named)
        }
        try engine.start()
        defer { engine.stop() }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(frames)))
        #expect(try engine.renderOffline(AVAudioFrameCount(frames), to: buffer) == .success)
        // The last sample of each channel: the mixer's ramps are over by then
        return (0..<Int(buffer.format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
        }
    }

    /// A device with two speakers plays a surround stream mixed down (Android's audio framework does the same with a
    /// 5.1 track): the center reaches both sides, each side keeps its own front channel.
    @Test func surroundIsMixedDownOnStereo() throws {
        let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let channels = try renderSurround(into: stereo)
        let left = try #require(channels[0].last), right = try #require(channels[1].last)
        #expect(left > 0.1 && right > 0.2)
        #expect(right - left > 0.05)
    }

    /// Six channels in a discrete layout: an output that does not name its speakers (AVAudioFormat needs a layout above
    /// two channels; an output without names has a discrete one).
    private func unnamedSixChannels() throws -> AVAudioFormat {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 6))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
        #expect(!AudioOutput.namesSpeakers(format.channelLayout))
        #expect(AudioOutput.namesSpeakers(AudioOutput.format(sampleRate: 48000, channels: 6)?.channelLayout))
        return format
    }

    /// An output of six channels in another order (HDMI's: left, right, LFE, center, surrounds) gets every channel of
    /// the stream on the speaker of the same name.
    @Test func surroundKeepsItsChannelsOnASurroundRoute() throws {
        let hdmi = try unnamedSixChannels()
        let speakers = [
            kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_LFEScreen, kAudioChannelLabel_Center,
            kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
        ]
        let channels = try renderSurround(into: hdmi, speakers: speakers)
        let last = channels.map { $0.last ?? 0 }
        for (got, want) in zip(last, [Float(0.1), 0.2, 0.4, 0.3, 0.5, 0.6]) { #expect(abs(got - want) < 0.001) }
    }

    @Test func anOutputThatNamesItsSpeakersOrHasTwoKeepsTheEnginesConnection() throws {
        let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        #expect(AudioOutput.outputFormat(hardware: stereo, speakers: [kAudioChannelLabel_Left, kAudioChannelLabel_Right]) == nil)
        let named = try #require(AudioOutput.format(sampleRate: 48000, channels: 6))
        #expect(AudioOutput.outputFormat(hardware: named, speakers: Array(repeating: kAudioChannelLabel_Left, count: 6)) == nil)
        let unnamed = try unnamedSixChannels()
        #expect(AudioOutput.outputFormat(hardware: unnamed, speakers: []) == nil)
        #expect(AudioOutput.outputFormat(hardware: unnamed, speakers: Array(repeating: kAudioChannelLabel_Unknown, count: 6)) == nil)
    }
}

struct FrameTimesTests {
    @Test func onePercentLowNeedsAHundredFramesAndUsesTheSlowest() {
        var times = FrameTimes()
        var now: UInt64 = 1_000
        times.add(now)
        for i in 0..<199 {
            now += i == 50 || i == 100 ? 50_000_000 : 10_000_000
            times.add(now)
            if i == 97 { #expect(times.onePercentLow == nil) }
        }
        // 199 intervals: the slowest 1 (199 / 100) is 50 ms, so 20 FPS
        #expect(abs((times.onePercentLow ?? 0) - 20) < 0.001)
        // A still picture longer than half a second is no hitch
        times.add(now + 600_000_000)
        #expect(abs((times.onePercentLow ?? 0) - 20) < 0.001)
    }

    @Test func totalLatencySumsWhatIsMeasured() {
        var s = StreamStatistics(width: 1, height: 1, codec: "H.264", hdr: false, incomingFPS: 60, bandwidthKiBPerSecond: 0, videoPackets: 0, fecPackets: 0)
        #expect(s.totalMilliseconds == nil)
        s.networkMilliseconds = 5
        s.hostAverageMilliseconds = 3
        s.decodeMilliseconds = 2
        #expect(s.totalMilliseconds == 10)
    }
}
