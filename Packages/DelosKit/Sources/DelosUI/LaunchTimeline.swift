import Foundation

/// The numbers of the launch scene: `HyperspaceConfig`, `LaunchOverlay` and `StreamLoader` of DELOS for Android
/// (docs/LAUNCH_TRANSITION.md, "Timeline, activation and bounded waits"), in stage pixels and seconds.
enum LaunchLook {
    /// The tunnel is drawn at 0.6 of the size and scaled up (1152 × 648 at 1920 × 1080).
    static let renderScale = 0.6
    /// The exit: 2.2 s, 0.5 s with reduced motion.
    static let openingSeconds = 2.2
    static let reducedOpeningSeconds = 0.5
    /// Where the exit's first leg ends (`LaunchArrival.READY_CHECK_AT`): the second leg runs on from here.
    static let openingCheckpoint = 0.6
    /// Each connection line is told this long at least.
    static let lineSeconds = 1.2
    /// The information block fades during the first 34 % of the exit.
    static let infoFadeEnd = 0.34
    /// How far the ring fills in the library's own part of the launch before the stream takes over, and how long that takes.
    static let handoffProgress = 0.3
    static let handoffSeconds = 0.7
    /// Each connection stage moves the progress by 8 % up to 92 %, over 0.6 s.
    static let stageStep = 0.08
    static let stageCap = 0.92
    static let progressSeconds = 0.6
    /// The progress fills up this fast once the game runs.
    static let finishSeconds = 0.25
    /// The longest the reveal waits for the first presented frame.
    static let frameWaitSeconds = 3.0
    /// The weights of the palette's accents in the tunnel.
    static let accentGain = 1.5
    static let accent2Gain = 1.3
    static let accent3Gain = 0.5

    // The information block
    static let infoWidth = 1000.0
    static let infoBottom = 100.0
    /// The Cancel pill under the information: 64 high, 16 above the bottom edge, 12 clear of the information.
    static let cancelHeight = 64.0
    static let cancelBottom = 16.0
    static let cancelGap = 12.0
    static let logoWidth = 440.0
    static let logoHeight = 124.0
    static let titleSize = 58.0
    static let parametersSize = 17.0
    static let parametersTracking = 2.0
    static let stageSize = 23.0
    static let stageLineHeight = 1.35
    static let trackWidth = 360.0
    static let trackHeight = 3.0
    static let percentSize = 15.0
    static let percentTracking = 3.0
    /// The calm scene of reduced motion: the third accent at 16 % into the background.
    static let calmAlpha = 0.16

    /// The information block's opacity at the exit's [opening] (0…1).
    static func infoAlpha(opening: Double) -> Double {
        1 - unit(unit(opening) / infoFadeEnd)
    }

    static func unit(_ value: Double) -> Double { value.isNaN ? 0 : min(max(value, 0), 1) }
}

/// The tunnel's travel is the integral of its speed over time, never time times the current speed: connection stages move
/// the progress in steps, and a speed that multiplied the elapsed time would make the tunnel leap at every step
/// (`HyperspaceTravel`).
enum LaunchTravel {
    /// Time constant (seconds) with which the speed's progress follows the real progress.
    static let followSeconds = 0.55
    /// Longest frame step that counts (a stalled frame must not throw the tunnel forward).
    static let maxStep = 0.1
    static let velocity = 0.9
    static let acceleration = 2.6

    static func speed(progress: Double) -> Double { velocity + progress * progress * acceleration }

    /// [smoothed] moved towards [target] over [dt] seconds (exponential approach, never overshoots).
    static func follow(_ smoothed: Double, toward target: Double, dt: Double) -> Double {
        let step = min(max(dt, 0), maxStep)
        return smoothed + (target - smoothed) * (1 - exp(-step / followSeconds))
    }

    /// [travel] advanced by one frame of [dt] seconds at the speed of [smoothed].
    static func advance(_ travel: Double, smoothed: Double, dt: Double) -> Double {
        travel + speed(progress: smoothed) * min(max(dt, 0), maxStep)
    }
}

/// The tunnel's state between frames: the travel integral, the smoothed progress and the last frame's time (`TunnelRun`).
final class LaunchTunnelRun {
    private(set) var travel = 0.0
    private(set) var smoothed = 0.0
    private var last: Double?

    /// One frame at [time] seconds with the real [progress] and the exit's [opening]; the travel freezes once the exit
    /// starts (the shader integrates the exit itself).
    func step(time: Double, progress: Double, opening: Double) {
        let dt = last.map { time - $0 } ?? 0
        last = time
        smoothed = LaunchTravel.follow(smoothed, toward: min(max(progress, 0), 1), dt: dt)
        if opening <= 0 { travel = LaunchTravel.advance(travel, smoothed: smoothed, dt: dt) }
    }
}

/// A FIFO of the connection lines in which every real stage gets its full visible time (`LaunchStageQueue`), on a
/// monotonic clock in nanoseconds.
struct LaunchStageQueue {
    private var pending: [String] = []
    private var shownAt: Int64
    private let minimumMillis: Int64

    private(set) var currentLine: String?

    init(initialLine: String? = nil, initialShownAt: Int64 = 0, minimumMillis: Int64 = Int64(LaunchLook.lineSeconds * 1000)) {
        currentLine = initialLine
        shownAt = initialShownAt
        self.minimumMillis = minimumMillis
    }

    /// Enqueuing never changes the visible line; [advance] supplies its actual presentation time.
    mutating func enqueue(_ line: String) {
        pending.append(line)
    }

    /// A late frame advances only one stage and starts that stage's own full time, without catching up.
    @discardableResult
    mutating func advance(at now: Int64) -> Bool {
        guard !pending.isEmpty, remainingMillis(at: now) <= 0 else { return false }
        currentLine = pending.removeFirst()
        shownAt = now
        return true
    }

    /// What is left of the visible line's time, rounded up to whole milliseconds.
    func remainingMillis(at now: Int64) -> Int64 {
        guard currentLine != nil else { return 0 }
        let elapsed = max(now - shownAt, 0)
        return max(minimumMillis - elapsed / 1_000_000, 0)
    }

    func isDrained(at now: Int64) -> Bool { pending.isEmpty && remainingMillis(at: now) == 0 }

    /// The game runs: the lines still queued are not told.
    mutating func dropPending() { pending.removeAll() }
}

/// The scene's one clock, in seconds, and its animations (`Animatable.animateTo` of Compose): a value that moves from where
/// it is to a target over a time with an easing.
struct LaunchTween: Equatable {
    var from: Double
    var to: Double
    var start: Double
    var duration: Double

    init(_ value: Double) {
        from = value
        to = value
        start = 0
        duration = 0
    }

    func value(at now: Double) -> Double {
        guard duration > 0 else { return to }
        return from + (to - from) * Motion.easeOut(min(max((now - start) / duration, 0), 1))
    }

    /// Starts moving towards [target] from where the value is at [now].
    mutating func move(to target: Double, at now: Double, over seconds: Double) {
        from = value(at: now)
        to = target
        start = now
        duration = seconds
    }
}

/// The launch scene's choreography (`LoaderScene` of Android's StreamLoader.kt) as a value that the tests step: the ring
/// fills to the stage's progress, the connection lines are told in turn, and once the game runs and its first frame is
/// presented (at most 3 s) the bar fills up, the information fades and the tunnel opens over the picture.
struct LaunchTimeline {
    enum Phase: Equatable {
        /// Connecting: the progress follows the stages, the lines are told.
        case connecting
        /// The game runs; waiting for the first presented frame, at most ``LaunchLook/frameWaitSeconds``.
        case awaitingFrame(since: Double)
        /// The bar fills up to 100 %.
        case finishing(until: Double)
        /// The exit: the tunnel opens (plain fades with reduced motion).
        case opening(since: Double)
        case done
    }

    private(set) var phase = Phase.connecting
    private(set) var queue: LaunchStageQueue
    let reducedMotion: Bool
    private var progress: LaunchTween
    private var target = LaunchLook.handoffProgress
    private var firstFrame = false

    /// - Parameters:
    ///   - now: the clock in seconds when the scene appears.
    ///   - line: the first connection line, told from the start.
    init(now: Double, line: String?, reducedMotion: Bool) {
        self.reducedMotion = reducedMotion
        queue = LaunchStageQueue(initialLine: line, initialShownAt: Self.nanos(now))
        progress = LaunchTween(0)
        // The library's part of the launch: the ring fills to 30 %
        progress.move(to: LaunchLook.handoffProgress, at: now, over: LaunchLook.handoffSeconds)
    }

    static func nanos(_ seconds: Double) -> Int64 { Int64((seconds * 1e9).rounded()) }

    var currentLine: String? { queue.currentLine }

    /// A connection stage started: [line] is told in turn, and the ring moves on by 8 % (up to 92 %).
    mutating func stage(line: String, at now: Double) {
        guard phase == .connecting else { return }
        queue.enqueue(line)
        target = min(target + LaunchLook.stageStep, LaunchLook.stageCap)
        progress.move(to: target, at: now, over: LaunchLook.progressSeconds)
    }

    /// The game runs; the lines queued behind the current one are not told.
    mutating func gameRuns(at now: Double) {
        guard phase == .connecting else { return }
        queue.dropPending()
        phase = .awaitingFrame(since: now)
    }

    /// The renderer presented a frame.
    mutating func framePresented() {
        firstFrame = true
    }

    /// One frame at [now].
    mutating func update(at now: Double) {
        if phase == .connecting { queue.advance(at: Self.nanos(now)) }
        switch phase {
        case .awaitingFrame(let since) where firstFrame || now - since >= LaunchLook.frameWaitSeconds:
            progress.move(to: 1, at: now, over: LaunchLook.finishSeconds)
            phase = .finishing(until: now + LaunchLook.finishSeconds)
        case .finishing(let until) where now >= until:
            phase = .opening(since: now)
        case .opening(let since) where now - since >= openingSeconds:
            phase = .done
        default:
            break
        }
    }

    var openingSeconds: Double { reducedMotion ? LaunchLook.reducedOpeningSeconds : LaunchLook.openingSeconds }

    /// The ring's progress, 0…1.
    func progress(at now: Double) -> Double { progress.value(at: now) }

    /// The exit's opening, 0…1: linear over its time (the two legs of Android's exit add up to it).
    func opening(at now: Double) -> Double {
        switch phase {
        case .opening(let since): min(max((now - since) / openingSeconds, 0), 1)
        case .done: 1
        default: 0
        }
    }

    var isActive: Bool { phase != .done }
}

/// The scene that leaves a stream (`StreamExit` of DELOS for Android), in seconds since it began.
enum ExitLook {
    /// The stream behind blurs up to 50 stage px over 0.45 s, and zooms in by 12 % over 2.4 s.
    static let blur = 50.0
    static let blurSeconds = 0.45
    static let zoom = 1.12
    static let zoomSeconds = 2.4
    /// The background comes in over 0.7 s (0.25 s with reduced motion).
    static let coverSeconds = 0.7
    static let reducedCoverSeconds = 0.25
    /// The last moments fade the scene into the flat background color: from 1.15 s over 0.33 s (from 0.35 s over 0.2 s).
    static let flatAt = 1.15
    static let flatSeconds = 0.33
    static let reducedFlatAt = 0.35
    static let reducedFlatSeconds = 0.2
    /// The library comes back after this long (0.7 s with reduced motion).
    static let handoffSeconds = 1.5
    static let reducedHandoffSeconds = 0.7

    static func handoff(reduced: Bool) -> Double { reduced ? reducedHandoffSeconds : handoffSeconds }

    /// How far the stream has zoomed in, as a scale, at [time].
    static func scale(at time: Double, reduced: Bool) -> Double {
        reduced ? 1 : 1 + (zoom - 1) * Motion.easeOut(LaunchLook.unit(time / zoomSeconds))
    }

    /// The blur radius in stage px.
    static func blurRadius(at time: Double, reduced: Bool) -> Double {
        reduced ? 0 : blur * LaunchLook.unit(time / blurSeconds)
    }

    /// How much of the stream is covered by the DELOS background (0…1).
    static func cover(at time: Double, reduced: Bool) -> Double {
        Motion.easeOut(LaunchLook.unit(time / (reduced ? reducedCoverSeconds : coverSeconds)))
    }

    /// How much of the scene is faded into the flat color (0…1).
    static func flat(at time: Double, reduced: Bool) -> Double {
        let start = reduced ? reducedFlatAt : flatAt
        return Motion.easeOut(LaunchLook.unit((time - start) / (reduced ? reducedFlatSeconds : flatSeconds)))
    }
}
