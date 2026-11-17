import DelosCore
import Foundation

/// Adaptive low-pass ("One Euro" filter) of a gyroscope's angular velocity (`GyroSmoother` of DELOS for Android): one per
/// controller and report rate, each of the three axes filtered on its own; the accelerometer is never filtered.
///
/// The cut-off of an axis is `minCutoff + beta * |d|`, `d` being the low-pass filtered rate of change of the signal: at
/// rest and for slow movement the cut-off stays near `minCutoff` (jitter is removed), during a fast flick it opens and the
/// filter lags very little. The derivative is filtered at ``derivativeCutoffHz``. The filter runs on what the host gets,
/// deg/s, timed by the samples' own timestamps; a repeated timestamp repeats the last output, a gap above
/// ``maxGapNanoseconds`` or a timestamp that goes backwards restarts it from the new sample.
///
/// Slider (0 off, then `t = slider / 100`), exponential so every step feels alike:
/// `minCutoff = 8 Hz · 0.025^t` (8 Hz … 0.2 Hz), `beta = 0.02 · 0.25^t` (0.02 … 0.005).
///
/// The strength changes live (the stream menu): crossing 0 either way forgets the state, between positive strengths the
/// state is kept so the output does not jump.
public struct GyroSmoother: Sendable {
    public static let off = 0
    public static let maxSlider = 100
    public static let derivativeCutoffHz = 1.0
    /// After a silence this long (ns) the old state is meaningless and the filter restarts.
    public static let maxGapNanoseconds: Int64 = 250_000_000

    private static let minCutoffLooseHz = 8.0, minCutoffStrongHz = 0.2
    private static let betaLoose = 0.02, betaStrong = 0.005

    /// The strength in use, 0…100.
    public private(set) var strength = -1
    private var minCutoff = 0.0
    private var beta = 0.0
    private var value = (0.0, 0.0, 0.0)
    private var rate = (0.0, 0.0, 0.0)
    private var lastTimestamp: Int64 = 0
    private var primed = false

    public init(strength: Int) {
        setStrength(strength)
    }

    /// Changes the strength (clamped to 0…100).
    public mutating func setStrength(_ slider: Int) {
        let clamped = min(Self.maxSlider, max(Self.off, slider))
        guard clamped != strength else { return }
        if clamped == Self.off || strength == Self.off { primed = false }
        strength = clamped
        minCutoff = Self.minCutoffHz(clamped)
        beta = Self.beta(clamped)
    }

    private static func fraction(_ slider: Int) -> Double {
        Double(min(maxSlider, max(off, slider))) / Double(maxSlider)
    }

    /// Cut-off at rest; falls from 8 Hz (slider 0) to 0.2 Hz (slider 100).
    public static func minCutoffHz(_ slider: Int) -> Double {
        minCutoffLooseHz * pow(minCutoffStrongHz / minCutoffLooseHz, fraction(slider))
    }

    /// Speed coefficient; falls from 0.02 (slider 0) to 0.005 (slider 100).
    public static func beta(_ slider: Int) -> Double {
        betaLoose * pow(betaStrong / betaLoose, fraction(slider))
    }

    /// Forgets everything; the next sample passes through unchanged.
    public mutating func reset() { primed = false }

    /// Filters one sample (deg/s) taken at `timestamp` nanoseconds; nil when the strength is 0 (use the sample untouched).
    public mutating func filter(nanoseconds timestamp: Int64, _ x: Float, _ y: Float, _ z: Float) -> (Float, Float, Float)? {
        guard strength != Self.off else { return nil }
        let gap = timestamp - lastTimestamp
        if !primed || gap > Self.maxGapNanoseconds || gap < 0 {
            value = (Double(x), Double(y), Double(z))
            rate = (0, 0, 0)
            lastTimestamp = timestamp
            primed = true
        } else if gap > 0 {
            let dt = Double(gap) * 1e-9
            lastTimestamp = timestamp
            let derivativeAlpha = Self.alpha(Self.derivativeCutoffHz, dt)
            step(&value.0, &rate.0, Double(x), dt, derivativeAlpha)
            step(&value.1, &rate.1, Double(y), dt, derivativeAlpha)
            step(&value.2, &rate.2, Double(z), dt, derivativeAlpha)
        }
        return (Float(value.0), Float(value.1), Float(value.2))
    }

    private func step(_ value: inout Double, _ rate: inout Double, _ sample: Double, _ dt: Double, _ derivativeAlpha: Double) {
        let previous = value
        rate += derivativeAlpha * ((sample - previous) / dt - rate)
        let cutoff = minCutoff + beta * abs(rate)
        value = previous + Self.alpha(cutoff, dt) * (sample - previous)
    }

    private static func alpha(_ cutoffHz: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoffHz)
        return dt / (dt + tau)
    }
}

/// The readings of a motion sensor on the host's axes and in its units (``MotionSensor``: SDL's axes, m/s², deg/s).
public enum MotionAxes {
    /// Standard gravity, m/s² per G.
    public static let gravity: Float = 9.80665
    /// Degrees per radian.
    public static let degreesPerRadian: Float = 57.2957795

    /// A controller's reading from GameController (`GCMotion`): x to the right, y towards the controller's top edge, z up
    /// out of its face; acceleration in G pointing like gravity (at rest face up: z = −1), rotation in rad/s. SDL's y is
    /// GameController's z and SDL's z is −y; the accelerometer's sign turns from gravity's to the reaction the host
    /// expects (+9.81 on y at rest).
    public static func controller(_ sensor: MotionSensor, x: Double, y: Double, z: Double) -> (Float, Float, Float) {
        switch sensor {
        case .accelerometer:
            (Float(-x) * gravity, Float(-z) * gravity, Float(y) * gravity)
        case .gyroscope:
            (Float(x) * degreesPerRadian, Float(z) * degreesPerRadian, Float(-y) * degreesPerRadian)
        }
    }

    /// How the interface is turned from the device's natural (portrait) orientation (Android's `Surface.ROTATION_*`):
    /// ``quarter`` is the device turned a quarter counter-clockwise (UIKit's `landscapeRight`), ``threeQuarters`` a quarter
    /// clockwise (`landscapeLeft`).
    public enum Rotation: Sendable, CaseIterable {
        case none, quarter, half, threeQuarters
    }

    /// This device's reading from Core Motion (x right, y up the screen, z out of it; acceleration in G pointing like
    /// gravity, rotation in rad/s) as the controller of a player who holds the device like a gamepad, screen up
    /// (`createSensorListener` of DELOS for Android with its display-rotation correction). Android's accelerometer reads
    /// the reaction (+9.81 on z lying flat), Core Motion gravity (−1 G), hence the sign.
    public static func device(_ sensor: MotionSensor, x: Double, y: Double, z: Double, rotation: Rotation) -> (Float, Float, Float) {
        let v: (Float, Float, Float) = switch sensor {
        case .accelerometer: (Float(-x) * gravity, Float(-y) * gravity, Float(-z) * gravity)
        case .gyroscope: (Float(x) * degreesPerRadian, Float(y) * degreesPerRadian, Float(z) * degreesPerRadian)
        }
        return remap(v, rotation)
    }

    /// Android's axis choice and factors per display rotation (values on the sensor's axes 0, 1, 2).
    static func remap(_ v: (Float, Float, Float), _ rotation: Rotation) -> (Float, Float, Float) {
        switch rotation {
        case .none: (v.0, v.2, -v.1)
        case .quarter: (-v.1, v.2, -v.0)
        case .half: (-v.0, v.2, v.1)
        case .threeQuarters: (v.1, v.2, v.0)
        }
    }
}

/// One motion sensor of one controller as the host asked for it: the rate, the gyro filter and the last reading sent.
/// Readings come faster than the rate (GameController reports every controller packet); the ones closer than a period to
/// the last one kept are dropped, a reading equal to the last one sent is not sent again (Android does not report a
/// duplicate either), and the gyro goes through ``GyroSmoother``.
public struct MotionStream: Sendable {
    /// The highest rate taken (Android's sensors are capped at 200 Hz without a special permission).
    public static let maxRateHz = 200

    public let sensor: MotionSensor
    /// The rate in use, 1…200 Hz.
    public let rateHz: Int
    private var smoother: GyroSmoother?
    private var lastKept: TimeInterval?
    private var lastSent: (Float, Float, Float)?

    /// nil for a rate of 0 (the host stops the sensor).
    public init?(sensor: MotionSensor, requestedHz: Int, smoothing: Int) {
        guard requestedHz > 0 else { return nil }
        self.sensor = sensor
        rateHz = min(Self.maxRateHz, requestedHz)
        if sensor == .gyroscope { smoother = GyroSmoother(strength: smoothing) }
    }

    /// The reading to send for a sample on the host's axes and units taken at `timestamp` seconds, or nil.
    public mutating func process(
        _ sample: (Float, Float, Float), timestamp: TimeInterval, smoothing: Int
    ) -> (Float, Float, Float)? {
        // A little slack, so readings that come exactly at the rate are not dropped by jitter
        if let lastKept, timestamp - lastKept < 0.9 / Double(rateHz), timestamp >= lastKept { return nil }
        lastKept = timestamp
        var value = sample
        if var smoother {
            smoother.setStrength(smoothing)
            let nanoseconds = Int64((timestamp * 1e9).rounded())
            if let filtered = smoother.filter(nanoseconds: nanoseconds, sample.0, sample.1, sample.2) { value = filtered }
            self.smoother = smoother
        }
        if let lastSent, lastSent == value { return nil }
        lastSent = value
        return value
    }
}

/// Counts the motion readings of every controller and turns them into one `MotionSend` log line per second and controller
/// (`MotionSendRate` of DELOS for Android): the readings that arrived and the ones handed to the connection, accepted or
/// refused by it.
public struct MotionSendRate: Sendable {
    private struct Counts: Sendable { var callbacks = 0, accepted = 0, refused = 0 }
    private var counts: [UInt8: [MotionSensor: Counts]] = [:]

    public init() {}

    /// A reading of `sensor` arrived for controller `pad` (before the rate and duplicate checks).
    public mutating func onSensorCallback(pad: UInt8, sensor: MotionSensor) {
        counts[pad, default: [:]][sensor, default: Counts()].callbacks += 1
    }

    /// A reading was handed to the connection, which took it or not.
    public mutating func onHandedOver(pad: UInt8, sensor: MotionSensor, accepted: Bool) {
        if accepted {
            counts[pad, default: [:]][sensor, default: Counts()].accepted += 1
        } else {
            counts[pad, default: [:]][sensor, default: Counts()].refused += 1
        }
    }

    /// The lines of the window that just ended (`window` seconds long), and a reset. A controller gets a line when it
    /// counted anything or when one of its sensors is on (`listening`; a sensor gone quiet shows as 0/s).
    public mutating func drainLines(window: TimeInterval, listening: Set<UInt8>) -> [String] {
        let window = max(window, 0.001)
        func perSecond(_ count: Int) -> Int { Int((Double(count) / window).rounded()) }
        var lines: [String] = []
        for pad in Set(counts.keys).union(listening).sorted() {
            let gyro = counts[pad]?[.gyroscope] ?? Counts(), accel = counts[pad]?[.accelerometer] ?? Counts()
            lines.append(
                "MotionSend gyro \(perSecond(gyro.accepted))/s accel \(perSecond(accel.accepted))/s pad \(pad) "
                    + "(sensor callbacks gyro \(perSecond(gyro.callbacks))/s accel \(perSecond(accel.callbacks))/s, "
                    + "refused gyro \(gyro.refused) accel \(accel.refused))")
        }
        counts.removeAll()
        return lines
    }
}
