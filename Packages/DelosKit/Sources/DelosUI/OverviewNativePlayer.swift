import AVFoundation
import CoreImage
import DelosData
import SwiftUI

/// A Steam movie in AVPlayer for ``OverviewVideo``: one player item (Steam's HLS master playlist, else its MP4), its state
/// reported every 250 ms and on each change of the player's or the item's status, the first frame on screen reported from
/// the layer, and DELOS's commands. A load that fails or does not get ready within 15 s is the video's error. Everything
/// goes once the viewer browses away or closes (``invalidate()``): the player pauses and drops its item.
@MainActor
final class OverviewNativePlayback {
    let player: AVPlayer
    private weak var video: OverviewVideo?
    private let generation: Int
    private var observations: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var endObserver: (any NSObjectProtocol)?
    private var watchdog: Task<Void, Never>?
    private weak var layer: AVPlayerLayer?
    private var ended = false
    private var invalidated = false
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    private nonisolated static let imageContext = CIContext()

    init(url: URL, video: OverviewVideo) {
        self.video = video
        generation = video.generation
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        item.add(output)
        player.isMuted = video.muted || OverviewVideo.startsMuted
        player.volume = Float(video.volume / 100)
        #if os(iOS) || os(tvOS)
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        #endif
        let changed: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.refresh() } }
        observations = [
            item.observe(\.status) { _, _ in changed() },
            player.observe(\.timeControlStatus) { _, _ in changed() },
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ended = true
                self?.refresh()
            }
        }
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.current, self.player.currentItem?.status != .readyToPlay else { return }
            self.fail()
        }
    }

    private var current: Bool { !invalidated && video?.generation == generation }

    /// Shows the player in [layer] and tells the video it is ready for commands.
    func attach(_ layer: AVPlayerLayer) {
        guard current, let video else { return }
        self.layer = layer
        layer.player = player
        observations.append(layer.observe(\.isReadyForDisplay) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in
                guard let self, self.current else { return }
                self.video?.firstFrame()
            }
        })
        video.attach(self, generation: generation)
        refresh()
    }

    /// Plays or pauses; at the end, plays from the start. The player's status change reports the new state.
    func setPlaying(_ on: Bool) {
        guard !invalidated else { return }
        if on {
            if ended {
                ended = false
                player.seek(to: .zero)
            }
            Self.activateAudio()
            player.play()
        } else {
            player.pause()
        }
    }

    func seek(by seconds: Double) { seek(to: player.currentTime().seconds + seconds) }

    func seek(to seconds: Double) {
        guard !invalidated, let item = player.currentItem else { return }
        let end = item.duration.seconds
        let target = max(0, end.isFinite ? min(seconds, end) : seconds)
        ended = false
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
        refresh()
    }

    /// [value]: 0…1; above 0 the sound comes on.
    func setVolume(_ value: Double) {
        player.volume = Float(min(max(value, 0), 1))
        if value > 0 { player.isMuted = false }
        refresh()
    }
    /// Copies a single decoded frame only when browsing away, never on playback ticks.
    func snapshot() async -> CGImage? {
        guard current, let buffer = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) else { return nil }
        // The retained decoded buffer crosses only into the render task; AVPlayer stays on the main actor.
        nonisolated(unsafe) let held = buffer
        return await Task.detached(priority: .userInitiated) {
            let image = CIImage(cvPixelBuffer: held)
            return Self.imageContext.createCGImage(image, from: image.extent)
        }.value
    }

    /// The player pauses and lets its item go; nothing is reported from now on.
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        watchdog?.cancel()
        observations.forEach { $0.invalidate() }
        observations = []
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        layer?.player = nil
        if let video { video.detach(self) }
    }

    /// The player's state as YouTube's codes (1 playing, 3 buffering, 2 paused, 0 ended), its time, length, the share
    /// loaded ahead of the start, the sound.
    private func refresh() {
        guard current, let video, let item = player.currentItem else { return }
        if item.status == .failed {
            fail()
            return
        }
        let time = player.currentTime().seconds
        let duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
        let state = switch player.timeControlStatus {
        case .playing: 1
        case .waitingToPlayAtSpecifiedRate: 3
        default: ended ? 0 : 2
        }
        let buffered = item.loadedTimeRanges.map(\.timeRangeValue).filter { $0.start.seconds <= time + 1 }.map(\.end.seconds).max() ?? 0
        video.report(state: state, time: time.isFinite ? time : 0, duration: duration, muted: player.isMuted,
                     loaded: duration > 0 ? buffered / duration : 0, volume: Double(player.volume) * 100)
    }

    /// The movie cannot load: the player goes first, so the video's error does not reach back into it.
    private func fail() {
        let video = video
        invalidate()
        video?.fail(-1)
    }

    /// The trailer's sound plays like a video's: the playback category (also with the silent switch on), unless the
    /// session already has it (a stream's, the interface sounds').
    private static func activateAudio() {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback { try? session.setCategory(.playback, mode: .moviePlayback) }
        try? session.setActive(true)
        #endif
    }
}

/// The view of a Steam movie: an `AVPlayerLayer` that letterboxes the video on black, takes no input (the viewer's tap
/// layer and dock drive it) and is in the normal view hierarchy, so the dock's glass blurs the moving picture under it.
@MainActor
struct OverviewNativePlayer {
    let url: URL
    let video: OverviewVideo

    func makeCoordinator() -> OverviewNativePlayback { OverviewNativePlayback(url: url, video: video) }
}

#if os(iOS) || os(tvOS)
final class OverviewPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

extension OverviewNativePlayer: UIViewRepresentable {
    func makeUIView(context: Context) -> OverviewPlayerView {
        let view = OverviewPlayerView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.playerLayer.videoGravity = .resizeAspect
        context.coordinator.attach(view.playerLayer)
        return view
    }
    func updateUIView(_ view: OverviewPlayerView, context: Context) {}
    static func dismantleUIView(_ view: OverviewPlayerView, coordinator: OverviewNativePlayback) { coordinator.invalidate() }
}
#else
final class OverviewPlayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = playerLayer
        wantsLayer = true
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension OverviewNativePlayer: NSViewRepresentable {
    func makeNSView(context: Context) -> OverviewPlayerView {
        let view = OverviewPlayerView()
        context.coordinator.attach(view.playerLayer)
        return view
    }
    func updateNSView(_ view: OverviewPlayerView, context: Context) {}
    static func dismantleNSView(_ view: OverviewPlayerView, coordinator: OverviewNativePlayback) { coordinator.invalidate() }
}
#endif
