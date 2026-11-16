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
            sampleRate: 48000, channelCount: channels, streams: channels == 2 ? 1 : 4,
            coupledStreams: channels == 2 ? 1 : 2, samplesPerFrame: 240, mapping: (0..<channels).map(UInt8.init))
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
}
