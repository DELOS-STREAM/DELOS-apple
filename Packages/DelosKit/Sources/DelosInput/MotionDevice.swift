import DelosCore
import Foundation
#if os(iOS)
import CoreMotion
import UIKit
#endif

/// This device's own accelerometer and gyroscope (Core Motion), player 1's motion when its controller has none and the
/// motion fallback is on (`gamepadMotionSensorsFallbackToDevice` of DELOS for Android, which uses the phone's
/// `SensorManager`). iPhone and iPad have the sensors; the Mac and Apple TV have none, so the fallback is never there.
/// Readings come on the main queue as the raw values of Core Motion (G and rad/s on the device's axes), with Core Motion's
/// timestamp (seconds since boot).
@MainActor
final class DeviceMotion {
    typealias Reading = @MainActor (_ x: Double, _ y: Double, _ z: Double, _ timestamp: TimeInterval) -> Void

    #if os(iOS)
    private let manager = CMMotionManager()
    #endif

    /// Whether the device has `sensor`.
    static func has(_ sensor: MotionSensor) -> Bool {
        #if os(iOS)
        let manager = CMMotionManager()
        return switch sensor {
        case .accelerometer: manager.isAccelerometerAvailable
        case .gyroscope: manager.isGyroAvailable
        }
        #else
        return false
        #endif
    }

    /// Delivers `sensor` at `rateHz` (as close as the hardware goes) until ``stop(_:)``; a second start replaces the first.
    func start(_ sensor: MotionSensor, rateHz: Int, reading: @escaping Reading) {
        #if os(iOS)
        let interval = 1 / Double(max(rateHz, 1))
        switch sensor {
        case .accelerometer:
            manager.stopAccelerometerUpdates()
            manager.accelerometerUpdateInterval = interval
            manager.startAccelerometerUpdates(to: .main) { data, _ in
                guard let data else { return }
                MainActor.assumeIsolated {
                    reading(data.acceleration.x, data.acceleration.y, data.acceleration.z, data.timestamp)
                }
            }
        case .gyroscope:
            manager.stopGyroUpdates()
            manager.gyroUpdateInterval = interval
            manager.startGyroUpdates(to: .main) { data, _ in
                guard let data else { return }
                MainActor.assumeIsolated {
                    reading(data.rotationRate.x, data.rotationRate.y, data.rotationRate.z, data.timestamp)
                }
            }
        }
        #endif
    }

    func stop(_ sensor: MotionSensor) {
        #if os(iOS)
        switch sensor {
        case .accelerometer: manager.stopAccelerometerUpdates()
        case .gyroscope: manager.stopGyroUpdates()
        }
        #endif
    }

    /// How the interface is turned now (Android's display rotation), for the axes of a reading.
    static func rotation() -> MotionAxes.Rotation {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return switch scene?.effectiveGeometry.interfaceOrientation {
        case .landscapeRight: .quarter
        case .portraitUpsideDown: .half
        case .landscapeLeft: .threeQuarters
        default: .none
        }
        #else
        return .none
        #endif
    }
}
