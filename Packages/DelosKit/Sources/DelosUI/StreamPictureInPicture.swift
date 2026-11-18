import DelosMedia
import Foundation

/// What AVKit's Picture in Picture window did with the stream (``StreamController/pictureInPicture(_:)``).
enum PictureInPictureEvent: Equatable {
    /// The window takes the stream (AVKit's will-start): the observer mode begins.
    case starting
    /// The window could not start.
    case failed
    /// The window closed: `restored` when the player went back to the app from it (its restore button), not when it was
    /// closed with its own button.
    case stopped(restored: Bool)
}

#if os(iOS)
import AVKit
import UIKit

/// AVKit's Picture in Picture for the stream (`checkbox_enable_pip`, Android's `StreamWindowController` PiP): the
/// controller over ``PictureInPictureVideo``'s sample buffer display layer, a live source (no seeking, never paused, an
/// infinite time range). The system starts it on its own when the app leaves while ``allowed`` (the stream runs, on this
/// device's own screen); the window gets the compressed frames from its start until it stops (``PictureInPictureVideo/route(to:)``),
/// and the stream hears each step (``PictureInPictureEvent``). Back in the app, a window still up is closed: the stream is
/// shown in the app again.
@MainActor
final class StreamPictureInPicture: NSObject {
    private let video: PictureInPictureVideo
    private var controller: AVPictureInPictureController?
    var onEvent: @MainActor (PictureInPictureEvent) -> Void = { _ in }
    /// The system may start the window when the app leaves. Turned off, a window that shows the stream closes (the stream
    /// ended or failed, or it went to another screen).
    var allowed = false {
        didSet {
            guard allowed != oldValue, let controller else { return }
            controller.canStartPictureInPictureAutomaticallyFromInline = allowed
            if !allowed, controller.isPictureInPictureActive { controller.stopPictureInPicture() }
        }
    }
    /// The player asked to go back to the app from the window (before it stops).
    private var restoring = false
    private nonisolated(unsafe) var activeObserver: (any NSObjectProtocol)?

    init(video: PictureInPictureVideo) {
        self.video = video
        super.init()
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: video.contentLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        self.controller = controller
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let controller = self?.controller, controller.isPictureInPictureActive else { return }
                controller.stopPictureInPicture()
            }
        }
    }

    deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    private func willStart() {
        video.route(to: .pictureInPicture)
        onEvent(.starting)
    }

    private func failed() {
        video.route(to: .main)
        onEvent(.failed)
    }

    private func didStop() {
        let restored = restoring
        restoring = false
        onEvent(.stopped(restored: restored))
    }

    /// AVKit calls its delegates on the main thread; anything else is brought there in order.
    private nonisolated func onMain(_ body: @escaping @MainActor @Sendable (StreamPictureInPicture) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(self) }
        } else {
            DispatchQueue.main.async { [self] in MainActor.assumeIsolated { body(self) } }
        }
    }
}

extension StreamPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onMain { $0.willStart() }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error
    ) {
        onMain { $0.failed() }
    }

    /// The frames go back to the stream's renderer as the window starts to close, so its picture is there again when the
    /// app is.
    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onMain { $0.video.route(to: .main) }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onMain { $0.didStop() }
    }

    /// The stream's screen never went away: it is restored as it is.
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        onMain { $0.restoring = true }
        completionHandler(true)
    }
}

/// A live stream: nothing to pause, seek or skip.
extension StreamPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
#endif
