import GameController

/// DualSense wire effects that GameController can represent. Unsupported effects are explicitly rejected and released.
/// Packet fields: https://github.com/nowrep/dualsensectl/blob/main/main.c (trigger_bitpacking_array / command_trigger_weapon).
public enum AdaptiveTriggerEffect: Equatable, Sendable {
    case off
    case feedback([Float])
    case vibration([Float], frequency: Float)
    case weapon(start: Float, end: Float, strength: Float)

    public static func decode(type: UInt8, payload: [UInt8]) -> AdaptiveTriggerEffect? {
        if type == 0 || type == 0x05 { return .off }
        guard payload.count == 10 else { return nil }
        let mask = UInt16(payload[0]) | UInt16(payload[1]) << 8
        switch type {
        case 0x21, 0x26:
            let packed = UInt32(payload[2]) | UInt32(payload[3]) << 8 | UInt32(payload[4]) << 16 | UInt32(payload[5]) << 24
            let values = (0..<10).map { i -> Float in
                guard mask & (1 << i) != 0 else { return 0 }
                return Float(((packed >> (3 * i)) & 7) + 1) / 8
            }
            return type == 0x21 ? .feedback(values) : .vibration(values, frequency: Float(payload[8]))
        case 0x25:
            let positions = (0..<10).filter { mask & (1 << $0) != 0 }
            guard positions.count == 2, payload[2] < 8 else { return nil }
            return .weapon(start: Float(positions[0]) / 9, end: Float(positions[1]) / 9, strength: Float(payload[2] + 1) / 8)
        // Legacy constant resistance and weapon encodings have no positional bit fields.
        case 0x01:
            return .feedback((0..<10).map { Float($0) / 9 >= Float(payload[0]) / 255 ? Float(payload[1]) / 255 : 0 })
        case 0x02:
            guard payload[1] > payload[0] else { return nil }
            return .weapon(start: Float(payload[0]) / 255, end: Float(payload[1]) / 255, strength: Float(payload[2]) / 255)
        default: return nil
        }
    }

    @MainActor
    func apply(to trigger: GCDualSenseAdaptiveTrigger) {
        switch self {
        case .off: trigger.setModeOff()
        case .feedback(let values):
            var strengths = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths()
            withUnsafeMutableBytes(of: &strengths.values) { bytes in
                for i in 0..<10 { bytes.bindMemory(to: Float.self)[i] = values[i] }
            }
            trigger.setModeFeedback(resistiveStrengths: strengths)
        case .vibration(let values, let frequency):
            var amplitudes = GCDualSenseAdaptiveTrigger.PositionalAmplitudes()
            withUnsafeMutableBytes(of: &amplitudes.values) { bytes in
                for i in 0..<10 { bytes.bindMemory(to: Float.self)[i] = values[i] }
            }
            trigger.setModeVibration(amplitudes: amplitudes, frequency: frequency)
        case let .weapon(start, end, strength):
            trigger.setModeWeaponWithStartPosition(start, endPosition: end, resistiveStrength: strength)
        }
    }
}
