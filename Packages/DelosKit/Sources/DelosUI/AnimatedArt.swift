import CoreGraphics
import DelosData
import ImageIO
import SwiftUI

/// When animated artwork plays and how much of it plays at once (`AnimatedPlayback` of DELOS for Android). The animation of
/// a hero, a tile or a logo follows the same rules as the rest of the app's motion: nothing moves with reduced motion or
/// the system's Reduce Motion, and nothing runs where it cannot be seen.
enum AnimatedPlayback {
    /// The most pixels a decoded frame of an Artwork screen tile has across.
    static let tileWidth = 520
    /// A hero frame is decoded at half the hero area (2100 px) at most, which the blur hides anyway.
    static let heroWidth = 1050
    /// How long a game must stay the focused one before its animated hero starts (the still hero shows meanwhile), ms.
    static let heroDwell = 500.0
    /// How long an animated hero that stopped (the focus moved on, a portal opened) stays paused on its last frame before it
    /// is released and the still hero shows, ms. Longer than the 900 ms cross-fade to the next game and the 800 ms fade-out,
    /// which remove the hero themselves.
    static let heroHold = 1000.0

    /// Whether the animated hero may start: playing is allowed ([animate]) and the game has been focused for ``heroDwell``.
    static func heroMayPlay(animate: Bool, dwelledMillis: Double) -> Bool { animate && dwelledMillis >= heroDwell }

    /// Whether the animation of a view plays now. [visible]: the view is on screen and not covered; [foreground]: the app
    /// is active; [streaming]: a stream is being started or runs; [systemReduceMotion]: the system's Reduce Motion
    /// (Android's animations-off developer setting is the closest one).
    static func shouldPlay(visible: Bool, foreground: Bool, streaming: Bool, reducedMotion: Bool, systemReduceMotion: Bool) -> Bool {
        visible && foreground && !streaming && !reducedMotion && !systemReduceMotion
    }

    /// Whether [layer] stops the library's animated artwork (`layerStopsDashboardArt`): a dialog covers the screen. A
    /// context menu does not: the covers stay visible beside its card (only dimmed), so they keep playing, without a restart.
    static func layerStopsLibraryArt(_ layer: Layers.Layer?) -> Bool {
        switch layer {
        case nil, .context?: false
        case .dialog?, .buttonCapture?: true
        }
    }

    /// The size a [width] × [height] animation is decoded at: never enlarged, the shape kept, and no bigger than the view it
    /// is drawn in needs. With only [maxWidth] it is that many pixels across at most. With a [maxHeight] too, the view is
    /// [maxWidth] × [maxHeight]: a cropped animation (not [fit]) is decoded just big enough to cover it, a [fit] one just big
    /// enough to fit in it.
    static func decodeSize(width: Int, height: Int, maxWidth: Int, maxHeight: Int = .max, fit: Bool = false) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (1, 1) }
        let byWidth = Double(maxWidth) / Double(width)
        let scale = min(maxHeight == .max ? byWidth
            : fit ? min(byWidth, Double(maxHeight) / Double(height))
            : max(byWidth, Double(maxHeight) / Double(height)), 1)
        if scale >= 1 { return (width, height) }
        return (max(Int((Double(width) * scale).rounded()), 1), max(Int((Double(height) * scale).rounded()), 1))
    }
}

/// The clock of a playing animation: which frame shows and when the next one is due, as the Android platform's
/// `AnimatedImageDrawable` keeps it (`onDraw` in hwui). Each frame stays for its duration
/// (``AnimatedImageInfo/frameMillis(unclampedSeconds:clampedSeconds:gif:)``), measured from when it was due, so the
/// animation keeps its pace; at most one frame changes per display frame, so a frame of 0 ms shows for one; and a frame
/// that came late (it was still being decoded, the screen was not drawn) keeps its whole time instead of the following ones
/// rushing by. Times in milliseconds of any clock.
struct FrameClock: Equatable {
    let durations: [Int]
    /// The animation repeats forever; else it plays once and stops on its last frame.
    var repeats: Bool
    /// The frame shown.
    private(set) var index = 0
    /// The pass ended on the last frame (only without [repeats]); a single frame never moves.
    private(set) var finished: Bool
    /// The animation's own time, which runs while it is drawn.
    private var time: Double
    private var lastDraw: Double
    /// When, in [time], the next frame shows.
    private var due: Double

    init(durations: [Int], repeats: Bool, now: Double) {
        self.durations = durations
        self.repeats = repeats
        finished = durations.count < 2
        time = now
        lastDraw = now
        due = now + Double(durations.first ?? 0)
    }

    /// The frame that shows next, nil once the pass has ended.
    var nextIndex: Int? { finished ? nil : (index + 1) % durations.count }

    /// A display frame at [now]: the clock runs on, and the next frame shows if it is due and [ready] (decoded). True when
    /// it does.
    mutating func draw(at now: Double, ready: Bool) -> Bool {
        time += now - lastDraw
        lastDraw = now
        guard let next = nextIndex, ready, time >= due else { return false }
        let shownAt = due
        index = next
        if !repeats, index == durations.count - 1 {
            finished = true
            return true
        }
        due += Double(durations[index])
        // Shown only now, it would be gone at once: the clock goes back to when this frame was due
        if time >= due { time = shownAt }
        return true
    }
}

/// One playing animation: the frame shown and the next one, decoded ahead, nothing more (a frame of a tile is a few MB). The
/// view draws ``frame(at:)`` at every display frame while it plays; ``restart()`` plays it from the first frame again.
@MainActor
final class AnimationPlayer {
    let info: AnimatedImageInfo
    private let decoder: AnimatedFrameDecoder
    /// The first frame, kept for a restart.
    private let first: CGImage
    private var repeats: Bool
    private var clock: FrameClock?
    private var current: CGImage
    private var next: (index: Int, image: CGImage)?
    private var decoding: Int?

    private init(info: AnimatedImageInfo, decoder: AnimatedFrameDecoder, first: CGImage, repeats: Bool) {
        self.info = info
        self.decoder = decoder
        self.first = first
        self.repeats = repeats
        current = first
    }

    /// The animation of [data] decoded for a view of [maxWidth] × [maxHeight] pixels (``AnimatedPlayback/decodeSize``) with
    /// its first frame ready; nil when it does not play or cannot be decoded. [repeats]: forever, else once.
    static func load(_ data: Data, maxWidth: Int, maxHeight: Int = .max, fit: Bool = false, repeats: Bool = true,
                     render: (@Sendable (CGImage) -> CGImage?)? = nil) async -> AnimationPlayer? {
        let loaded = await Task.detached(priority: .userInitiated) { () -> (AnimatedImageInfo, AnimatedFrameDecoder, CGImage)? in
            guard let info = AnimatedImageInfo.of(data) else { return nil }
            let size = AnimatedPlayback.decodeSize(width: info.width, height: info.height, maxWidth: maxWidth, maxHeight: maxHeight, fit: fit)
            guard let decoder = AnimatedFrameDecoder(data: data, maxPixelSize: max(size.width, size.height), render: render),
                  let first = await decoder.frame(0) else { return nil }
            return (info, decoder, first)
        }.value
        guard let loaded, !Task.isCancelled else { return nil }
        return AnimationPlayer(info: loaded.0, decoder: loaded.1, first: loaded.2, repeats: repeats)
    }

    /// Repeats forever from now on (a looped hero whose next pass could not be decoded).
    func repeatForever() {
        repeats = true
        clock?.repeats = true
    }

    /// The pass has ended on its last frame.
    var finished: Bool { clock?.finished ?? false }

    /// The frame to draw at [date]; the first call starts the clock.
    func frame(at date: Date) -> CGImage {
        let now = date.timeIntervalSinceReferenceDate * 1000
        guard var clock else {
            clock = FrameClock(durations: info.durations, repeats: repeats, now: now)
            prefetch()
            return current
        }
        let upcoming = clock.nextIndex
        if clock.draw(at: now, ready: upcoming != nil && next?.index == upcoming), let next {
            current = next.image
            self.next = nil
        }
        self.clock = clock
        prefetch()
        return current
    }

    /// From the first frame at the next draw (the Android platform's `start()` after a `stop()`).
    func restart() {
        clock = nil
        current = first
        next = nil
        decoding = nil
    }

    private func prefetch() {
        guard let index = clock?.nextIndex, next?.index != index, decoding != index else { return }
        decoding = index
        Task { [weak self, decoder] in
            let image = await decoder.frame(index)
            guard let self, self.decoding == index else { return }
            self.decoding = nil
            if let image { self.next = (index, image) }
        }
    }
}

/// An animation to play and what names it: a new [key] (another file, a new version of the artwork) loads it again.
struct AnimatedSource: Equatable, Sendable {
    let key: String
    let data: Data

    static func == (a: AnimatedSource, b: AnimatedSource) -> Bool { a.key == b.key }
}

/// The playing animation of an image over its still first frame, which the caller draws underneath (`AnimatedArtLayer`):
/// decoded for a view of [width] × [height] pixels (cropped to fill it, or [fit] whole) only while [playing], released
/// when it stops (the still shows then), and played from its first frame again when the app comes back to the
/// foreground. Nothing is drawn until the first frame is decoded; then it fades in.
struct AnimatedArtLayer: View {
    let source: AnimatedSource?
    let playing: Bool
    let width: Int
    var height = Int.max
    var fit = false
    var alignment = Alignment.center
    /// True once the animation has faded in over the still, false as soon as it is released: the caller hides the still
    /// meanwhile, so a transparent animation does not show the first frame through it.
    var covering: Binding<Bool>?
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AnimationPlayer?
    @State private var shown = false

    private struct LoadKey: Equatable {
        let source: AnimatedSource?
        let playing: Bool
        let width: Int
        let height: Int
        let fit: Bool
    }

    var body: some View {
        let foreground = scenePhase == .active
        ZStack {
            if let player {
                TimelineView(.animation(paused: !foreground)) { context in
                    Image(decorative: player.frame(at: context.date), scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: fit ? .fit : .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                }
                .clipped()
                .opacity(shown ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: LoadKey(source: source, playing: playing, width: width, height: height, fit: fit)) {
            shown = false
            player = nil
            covering?.wrappedValue = false
            guard playing, let source else { return }
            guard let loaded = await AnimationPlayer.load(source.data, maxWidth: width, maxHeight: height, fit: fit) else { return }
            player = loaded
            withAnimation(Motion.fadeIn) { shown = true } completion: { if shown { covering?.wrappedValue = true } }
        }
        .onChange(of: foreground) { _, now in if now { player?.restart() } }
    }
}

extension Motion {
    /// An animation's fade-in over its still (`Motion.FADE` with `Motion.Ease`).
    static var fadeIn: Animation { .timingCurve(0.25, 0.1, 0.25, 1, duration: fade / 1000) }
}

extension EnvironmentValues {
    /// Something of the shell covers the screen's animated artwork: the side menu or the portal into a PC (the root sets it).
    @Entry var shellCoversArt = false
    /// Animated artwork may play on this screen now (the library's or the Artwork screen's rule); each view adds whether it is
    /// itself on screen.
    @Entry var artMotion = false
}
