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
