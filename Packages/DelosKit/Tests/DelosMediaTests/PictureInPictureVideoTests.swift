import CoreMedia
import Foundation
import QuartzCore
import Synchronization
import Testing
@testable import DelosMedia

/// Counts what reaches the stream's renderer.
private final class CountingRenderer: VideoRenderer {
    let enqueued = Mutex(0)
    let flushes = Mutex(0)

    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        enqueued.withLock { $0 += 1 }
        return true
    }

    func flush() { flushes.withLock { $0 += 1 } }

    var name: String { "Counting" }
    func presentationCounters() async -> VideoPresentationCounters? { nil }
    @MainActor var hostLayer: CALayer { CALayer() }
    @MainActor func resize(to bounds: CGRect, scale: CGFloat) {}
}

@Suite struct PictureInPictureRouteTests {
    @Test func theStreamsRendererGetsTheFramesAndTheLayerCopiesItsPictures() {
        var route = PictureInPictureRoute()
        #expect(route.mirrors)
        #expect(route.next(keyFrame: false) == (false, .main))
        // The same target again changes nothing
        route.set(.main)
        #expect(route.next(keyFrame: false) == (false, .main))
    }

    @Test func theWindowStartsAtAKeyFrameAfterOneFlush() {
        var route = PictureInPictureRoute()
        route.set(.pictureInPicture)
        #expect(!route.mirrors)
        // Refused until the key frame (an IDR request), flushed once
        #expect(route.next(keyFrame: false) == (true, .awaitKeyFrame))
        #expect(route.next(keyFrame: false) == (false, .awaitKeyFrame))
        #expect(route.next(keyFrame: true) == (false, .pictureInPicture))
        #expect(route.next(keyFrame: false) == (false, .pictureInPicture))
    }

    @Test func aKeyFrameRightAfterTheChangeGoesToTheWindowAtOnce() {
        var route = PictureInPictureRoute()
        route.set(.pictureInPicture)
        #expect(route.next(keyFrame: true) == (true, .pictureInPicture))
    }

    @Test func backFromTheWindowTheStreamsRendererStartsOverAndTheCopyResumes() {
        var route = PictureInPictureRoute()
        route.set(.pictureInPicture)
        _ = route.next(keyFrame: true)
        route.set(.main)
        #expect(route.mirrors)
        // The stream's renderer is flushed and waits for its key frame on its own
        #expect(route.next(keyFrame: false) == (true, .main))
        #expect(route.next(keyFrame: false) == (false, .main))
    }

    @Test func aWindowThatStopsBeforeItsFirstFrameLeavesNothingWaiting() {
        var route = PictureInPictureRoute()
        route.set(.pictureInPicture)
        route.set(.main)
        #expect(route.next(keyFrame: false) == (true, .main))
        route.set(.pictureInPicture)
        #expect(route.next(keyFrame: false) == (true, .awaitKeyFrame))
    }
}

@MainActor
@Suite struct PictureInPictureVideoTests {
    @Test func theDisplayLayerIsItsOwnContentAndNothingIsRerouted() throws {
        let layer = DisplayLayerRenderer()
        let video = PictureInPictureVideo(wrapping: layer)
        #expect(video.sharesLayer)
        #expect(video.contentLayer === layer.layer)
        #expect(video.hostLayer === layer.layer)
        video.route(to: .pictureInPicture)
        let frames = try SyntheticStream.encode(codec: kCMVideoCodecType_H264, width: 320, height: 240, count: 3)
        // Every frame still goes to the display layer, which decodes it whatever the window does
        for frame in frames { #expect(video.enqueue(frame)) }
    }

    @Test func theMetalRendererGetsALayerOfItsOwnUnderneath() throws {
        guard let metal = MetalRenderer(pacing: .phaseLock, fps: 60) else { return }
        let video = PictureInPictureVideo(wrapping: metal)
        #expect(!video.sharesLayer)
        #expect(video.hostLayer is CAMetalLayer)
        #expect(video.contentLayer !== video.hostLayer)
        video.resize(to: CGRect(x: 0, y: 0, width: 640, height: 360), scale: 2)
        #expect(video.contentLayer.frame.size == CGSize(width: 640, height: 360))
    }

    @Test func whileTheWindowShowsTheStreamTheFramesGoToItsLayerFromAKeyFrame() throws {
        let main = CountingRenderer()
        let video = PictureInPictureVideo(wrapping: main)
        let frames = try SyntheticStream.encode(codec: kCMVideoCodecType_H264, width: 320, height: 240, count: 62)
        let key = try #require(frames.first)
        let delta = try #require(frames.dropFirst().first { !MetalPipeline.isKeyFrame($0) })
        #expect(video.enqueue(key) && video.enqueue(delta))
        #expect(main.enqueued.withLock { $0 } == 2)

        video.route(to: .pictureInPicture)
        // A frame that is no key frame is refused (VideoOutput asks the host for one); the stream's renderer gets nothing
        #expect(!video.enqueue(delta))
        #expect(video.enqueue(key))
        #expect(video.enqueue(delta))
        #expect(main.enqueued.withLock { $0 } == 2)
        #expect(main.flushes.withLock { $0 } == 0)

        video.route(to: .main)
        #expect(video.enqueue(delta))
        // Back: the stream's renderer is flushed once and gets the frames again
        #expect(main.flushes.withLock { $0 } == 1)
        #expect(main.enqueued.withLock { $0 } == 3)
    }
}
