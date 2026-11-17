import Foundation

/// Stable preset identities shared by settings and the live stream menu.
public enum RumblePreset: String, Codable, CaseIterable, Sendable {
    case original = "ORIGINAL", soft = "GENTLE", kickStart = "KICK_ONLY", pulsing = "PULSE_25"

    public var labelKey: String {
        switch self {
        case .original: "rumble_preset_original"
        case .soft: "rumble_preset_soft"
        case .kickStart: "rumble_preset_kick_start"
        case .pulsing: "rumble_preset_pulsing"
        }
    }

    public var profile: RumbleProfile {
        switch self {
        case .original: RumbleProfile()
        case .soft: RumbleProfile(gain: 0.7, curve: 1.3)
        case .kickStart: RumbleProfile(kickMilliseconds: 100)
        case .pulsing: RumbleProfile(curve: 0.8, minimumAmplitude: 50, lowWeight: 1, highWeight: 0.35, pulseMilliseconds: 20)
        }
    }
}

public struct RumbleConfiguration: Codable, Equatable, Sendable {
    public var enabled = true
    public var profile = RumblePreset.original
    /// Percent, including amplification up to 200%; the output is saturated, never wrapped.
    public var deviceStrength = 100 { didSet { deviceStrength = min(200, max(1, deviceStrength)) } }
    public var deviceFallback = false
    public var deviceEnabled = false
    public var adaptiveTriggers = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: key)) ?? fallback }
        enabled = value(.enabled, true)
        profile = value(.profile, .original)
        deviceStrength = min(200, max(1, value(.deviceStrength, 100)))
        deviceFallback = value(.deviceFallback, false)
        deviceEnabled = value(.deviceEnabled, false)
        adaptiveTriggers = value(.adaptiveTriggers, true)
    }

    public func usesDevice(controllerCanRumble: Bool, controllerNumber: UInt16) -> Bool {
        enabled && controllerNumber == 0 && (deviceEnabled || (deviceFallback && !controllerCanRumble))
    }
}

/// Eight-bit shaping follows the host rumble translator; raw zero always cancels immediately.
public struct RumbleProfile: Equatable, Sendable {
    public var gain: Double = 1
    public var curve: Double = 1
    public var minimumAmplitude: Int = 0
    public var kickMilliseconds: Double = 0
    public var lowWeight: Double = 0.8
    public var highWeight: Double = 0.33
    public var smoothing: Double = 0
    /// A looping on/off pattern of equal durations; zero means continuous amplitude.
    public var pulseMilliseconds: Double = 0

    public init(gain: Double = 1, curve: Double = 1, minimumAmplitude: Int = 0,
                kickMilliseconds: Double = 0, lowWeight: Double = 0.8, highWeight: Double = 0.33,
                smoothing: Double = 0, pulseMilliseconds: Double = 0) {
        self.gain = gain
        self.curve = curve
        self.minimumAmplitude = minimumAmplitude
        self.kickMilliseconds = kickMilliseconds
        self.lowWeight = lowWeight
        self.highWeight = highWeight
        self.smoothing = smoothing
        self.pulseMilliseconds = pulseMilliseconds
    }

    func shape(_ amplitude: Double, nonzero: Bool) -> Int {
        guard nonzero else { return 0 }
        let shaped = curve == 1 ? amplitude * gain : pow(amplitude / 255, curve) * gain * 255
        return min(255, max(minimumAmplitude, Int(shaped)))
    }
}

public struct RumbleChannel: Sendable {
    private var active = false
    private var lastMilliseconds: Double = 0
    private var kickUntil: Double = 0
    private var amplitude: Double = 0
    private var target = 0

    public init() {}

    public mutating func reset() { self = RumbleChannel() }

    public mutating func motor(_ raw: UInt16, profile: RumbleProfile, nowMilliseconds: Double) -> Int {
        translate(profile.shape(Double(raw >> 8), nonzero: raw != 0), nonzero: raw != 0,
                  profile: profile, now: nowMilliseconds)
    }

    public mutating func single(low: UInt16, high: UInt16, profile: RumbleProfile, nowMilliseconds: Double) -> Int {
        let nonzero = low != 0 || high != 0
        let mixed = Double(low >> 8) * profile.lowWeight + Double(high >> 8) * profile.highWeight
        return translate(profile.shape(mixed, nonzero: nonzero), nonzero: nonzero, profile: profile, now: nowMilliseconds)
    }

    public func nextUpdateMilliseconds(now: Double) -> Double? {
        guard active else { return nil }
        if now < kickUntil { return kickUntil - now }
        return amplitude != Double(target) ? 16 : nil
    }

    private mutating func translate(_ target: Int, nonzero: Bool, profile: RumbleProfile, now: Double) -> Int {
        guard nonzero else { reset(); return 0 }
        if !active {
            active = true
            lastMilliseconds = now
            kickUntil = now + profile.kickMilliseconds
            self.target = target
            amplitude = profile.kickMilliseconds > 0 ? 255 : Double(target)
            return Int(amplitude)
        }
        let previous = lastMilliseconds
        let now = max(previous, now)
        lastMilliseconds = now
        self.target = target
        if now < kickUntil { amplitude = 255 }
        else if profile.smoothing == 0 { amplitude = Double(target) }
        else {
            let delta = (now - max(previous, kickUntil)) * 255 / (1000 * profile.smoothing)
            amplitude += min(delta, max(-delta, Double(target) - amplitude))
            if abs(Double(target) - amplitude) < 0.000001 { amplitude = Double(target) }
        }
        return min(255, max(0, Int((amplitude + 1e-9).rounded())))
    }
}

public enum RumbleProblem: Equatable, Sendable {
    case noAmplitudeControl, singleVibratorOnly, failed(String)

    public var labelKey: String {
        switch self {
        case .noAmplitudeControl: "rumble_problem_no_amplitude"
        case .singleVibratorOnly: "rumble_problem_single_vibrator"
        case .failed: "rumble_problem_failed"
        }
    }
}
