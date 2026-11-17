import Foundation

/// The arrival of the stream's picture at the end of the launch scene (`LaunchArrival` and the `STREAM_*` numbers of
/// `HyperspaceConfig` of DELOS for Android): while the tunnel opens, the live picture waits zoomed to 118 % and blurred,
/// then springs in to 100 % with a short squash, skew, wave and RGB split, and ends exactly on the plain picture.
///
/// The pose is a function of the exit's opening (0…1, linear over the exit's 2.2 s); ``MetalPipeline`` evaluates it at
/// each refresh's presentation time and draws the picture through the arrival pass (`arrivalFragment`).
enum LaunchArrival {
    /// From here on the pass runs: below it the tunnel covers the picture entirely.
    static let activateAt = 0.55
    /// Where the settling starts: until then the picture waits at the initial zoom and full blur.
    static let settleStart = 0.68
    static let initialZoom = 1.18
    static let decay = 6.0
    static let springDamping = 3.8
    static let springFrequency = 15.0
    static let squish = 0.10
    static let springZoom = 0.025
    /// The wave's amplitude in source pixels (times 0.45 in the shader).
    static let warp = 70.0
    /// The blur's radius in source pixels, sampled from the picture's mip levels.
    static let blur = 20.0
    /// The RGB split's peak in source pixels.
    static let chromatic = 9.0

    /// Whether the pass runs at [opening]: from ``activateAt`` until the opening is complete.
    static func shouldActivate(_ opening: Double) -> Bool {
        opening.isFinite && opening >= activateAt && opening < 1
    }

    /// The pose at [opening]. Negative, invalid and complete openings give the exact identity.
    static func pose(opening: Double) -> ArrivalPose {
        guard opening >= 0, opening < 1 else { return .identity }
        let x = unit((opening - settleStart) / (1 - settleStart))
        let end = unit((x - 0.80) / 0.20)
        let envelope = max(0, 1 - end * end * end * (end * (end * 6 - 15) + 10))
        let residual = exp(-decay * x) * (1 + decay * x) * envelope
        let spring = exp(-springDamping * x) * sin(springFrequency * x) * envelope
        let scale = 1 + (initialZoom - 1) * residual + springZoom * spring
        let stretch = 1 + squish * spring
        return ArrivalPose(
            scaleX: Float(scale * stretch), scaleY: Float(scale / stretch), skew: Float(tan(spring * 0.55 * .pi / 180)),
            warp: Float(warp * spring), blur: Float(blur * residual),
            chromatic: Float(chromatic * sin(.pi * x) * exp(-1.2 * x) * envelope))
    }

    private static func unit(_ value: Double) -> Double { min(max(value, 0), 1) }
}

/// The arrival's transform of the picture: scale, vertical skew and wave, and the blur and RGB split in source pixels.
struct ArrivalPose: Equatable, Sendable {
    var scaleX: Float
    var scaleY: Float
    /// The tangent of the skew angle: the picture's y moves by x times this.
    var skew: Float
    var warp: Float
    var blur: Float
    var chromatic: Float

    static let identity = ArrivalPose(scaleX: 1, scaleY: 1, skew: 0, warp: 0, blur: 0, chromatic: 0)
}

/// An arrival started at [start] on the renderer's clock, lasting [duration] seconds.
struct ArrivalRun: Equatable, Sendable {
    var start: Double
    var duration: Double

    /// The exit's opening at [time]: 0 at the start, 1 at the end.
    func opening(at time: Double) -> Double {
        duration > 0 ? (time - start) / duration : 1
    }
}

/// The constants of `arrivalFragment`; the layout matches the Metal struct of the same name (48 bytes).
struct ArrivalUniforms: Equatable {
    /// Scale x, scale y, skew, warp.
    var pose: SIMD4<Float>
    /// Blur, chromatic split (source pixels).
    var effects: SIMD2<Float>
    var sourceSize: SIMD2<Float>
    var presentationSize: SIMD2<Float>

    /// The source is drawn into a texture of its own size, so the blur's mip level counts source pixels.
    init(pose: ArrivalPose, width: Int, height: Int) {
        self.pose = SIMD4(pose.scaleX, pose.scaleY, pose.skew, pose.warp)
        effects = SIMD2(pose.blur, pose.chromatic)
        sourceSize = SIMD2(Float(width), Float(height))
        presentationSize = sourceSize
    }
}
