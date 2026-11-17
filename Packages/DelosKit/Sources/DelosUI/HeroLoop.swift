import CoreGraphics
import DelosData
import Foundation

/// How an animated game background loops without a jump (`HeroLoopTimeline` of DELOS for Android). Each pass plays once:
/// during the last [fadeMillis] of a pass the next one starts at its first frame and fades in over it, so at the loop point
/// the new pass is already fully visible and the old one is dropped. The next pass starts [periodMillis] (the loop's
/// length less the fade) after the one before it. Times are milliseconds since the newest pass started.
struct HeroLoopTimeline: Equatable {
    let loopMillis: Int
    let fadeMillis: Int

    /// A loop shorter than this keeps the plain loop: the fade would be most of it.
    static let minLoop = 1500
    /// The length of the fade (a third of the loop at most).
    static let fade = 700
    /// How long before a pass starts it is decoded.
    static let decodeLead = 500

    /// From the start of a pass to the start of the next one.
    var periodMillis: Int { loopMillis - fadeMillis }

    /// When, in a pass, the next one is decoded: ``decodeLead`` before it starts, which is never during the fade of this pass.
    var decodeAtMillis: Int { periodMillis - Self.decodeLead }

    /// How far the fade of the pass that has run for [sinceStart] ms is, 0 (just started, invisible) to 1 (fully visible,
    /// the pass before it is dropped).
    func progress(_ sinceStart: Double) -> Double { min(max(sinceStart / Double(fadeMillis), 0), 1) }

    /// The timeline of an animation that takes [loopMillis] a pass, nil when it is too short (or unknown, 0) to fade.
    static func of(loopMillis: Int) -> HeroLoopTimeline? {
        loopMillis < minLoop ? nil : HeroLoopTimeline(loopMillis: loopMillis, fadeMillis: min(fade, loopMillis / 3))
    }
}

/// The playing passes of a looping game background (`LoopedAnimation`, see ``HeroLoopTimeline``): [bottom] plays alone, or
/// is on its way out while the newer pass fades in over it. Passes are decoded one at a time, shortly before they start, and
/// dropped when they end: outside of the fade the cost is one playing animation. Drawn from ``frame(at:)`` at every
/// display frame while it plays; when it does not, it stays on the frame it shows, and ``restart()`` plays the newest pass
/// from its start again.
@MainActor
final class LoopedAnimation {
    struct Frame {
        let bottom: CGImage
        /// The incoming pass and how far it has faded in (0…1, eased).
        let top: CGImage?
        let mix: Double
    }

    private let timeline: HeroLoopTimeline?
    private let decode: @MainActor () async -> AnimationPlayer?
    private var bottom: AnimationPlayer
    private var top: AnimationPlayer?
    /// The pass that starts next, decoded and not started yet.
    private var next: AnimationPlayer?
    private var decodingNext = false
    /// Without a [timeline], or once a next pass could not be decoded, the first pass repeats forever by itself.
    private var plain: Bool
    /// When the newest pass started (ms); nil until it is drawn.
    private var anchor: Double?
    private var mix = 0.0

    private init(first: AnimationPlayer, timeline: HeroLoopTimeline?, decode: @escaping @MainActor () async -> AnimationPlayer?) {
        bottom = first
        self.timeline = timeline
        self.decode = decode
        plain = timeline == nil
    }

    /// The looping animation of [data] decoded no wider than [maxWidth], each frame passed through [render]; nil when it does
    /// not play.
    static func load(_ data: Data, maxWidth: Int, render: @escaping @Sendable (CGImage) -> CGImage?) async -> LoopedAnimation? {
        guard let first = await AnimationPlayer.load(data, maxWidth: maxWidth, repeats: false, render: render) else { return nil }
        let timeline = HeroLoopTimeline.of(loopMillis: first.info.loopMillis)
        if timeline == nil { first.repeatForever() }
        return LoopedAnimation(first: first, timeline: timeline) {
            await AnimationPlayer.load(data, maxWidth: maxWidth, repeats: false, render: render)
        }
    }

    func frame(at date: Date) -> Frame {
        let now = date.timeIntervalSinceReferenceDate * 1000
        let anchor = anchor ?? now
        self.anchor = anchor
        if let timeline, !plain {
            let elapsed = now - anchor
            if let incoming = top {
                // Fading: the newer pass replaces the older one once fully visible
                let progress = timeline.progress(elapsed)
                if progress >= 1 {
                    bottom = incoming
                    top = nil
                    mix = 0
                } else {
                    mix = Motion.ease(progress)
                }
            } else if let pass = next {
                // The loop point is a fade away: the next pass starts and fades in
                if elapsed >= Double(timeline.periodMillis) {
                    next = nil
                    top = pass
                    self.anchor = now
                    mix = 0
                }
            } else if !decodingNext, elapsed >= Double(timeline.decodeAtMillis) {
                decodingNext = true
                Task { [weak self] in
                    let pass = await self?.decode()
                    guard let self else { return }
                    decodingNext = false
                    if let pass {
                        next = pass
                    } else {
                        // No second pass: the first one loops on its own
                        plain = true
                        bottom.repeatForever()
                    }
                }
            }
        }
        return Frame(bottom: bottom.frame(at: date), top: top?.frame(at: date), mix: mix)
    }

    /// Plays again after a pause, from the start of the newest pass (of the passes that were fading, the newer one stays).
    func restart() {
        if let incoming = top {
            bottom = incoming
            top = nil
            mix = 0
        }
        bottom.restart()
        anchor = nil
    }
}
