import Foundation
#if os(iOS)
import AVKit
import CoreHaptics
import CoreMotion
#endif

/// What this device's hardware has, for the settings rows that need it (`SettingsCapabilities.read` of DELOS for
/// Android: touchscreen, motion sensors, a vibration motor, Picture in Picture).
@MainActor
enum DeviceHardware {
    /// A touchscreen (iPhone and iPad).
    static var touchscreen: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// The device's own gyroscope (iPhone and iPad).
    static var motion: Bool {
        #if os(iOS)
        CMMotionManager().isGyroAvailable
        #else
        false
        #endif
    }

    /// A vibration motor the app can play (iPhone; iPad has none).
    static var haptics: Bool {
        #if os(iOS)
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
        #else
        false
        #endif
    }

    /// Picture in Picture for the stream (``PictureInPictureVideo``): iPhone and iPad, where AVKit starts it on its own when
    /// the app leaves during a stream (`canStartPictureInPictureAutomaticallyFromInline`, Android's auto-enter). The Mac
    /// keeps streaming in a window behind the others and has no automatic start, nor has Apple TV, so neither shows the row.
    static var pictureInPicture: Bool {
        #if os(iOS)
        AVPictureInPictureController.isPictureInPictureSupported()
        #else
        false
        #endif
    }
}
