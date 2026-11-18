import DelosInput
import Foundation

extension TouchOptions {
    /// The profile's touch and pointer settings under DELOS for Android's keys (`PreferenceConfiguration`).
    public init(settings: StreamSettings) {
        self.init()
        mode = TouchMode(saved: settings.text(.touchMode))
        rememberMode = settings.bool(.rememberMouseMode)
        localCursor = settings.bool(.mouseLocalCursor)
        multiTouchGestures = settings.bool(.multiTouchGestures)
        absoluteMouseMode = settings.bool(.absoluteMouseMode)
        touchpadSensitivityX = settings.int(.touchpadSensitivityOpacity)
        touchpadSensitivityY = settings.int(.touchpadSensitivityYOpacity)
        trackpadSensitivityX = settings.int(.trackpadSensitivityX)
        trackpadSensitivityY = settings.int(.trackpadSensitivityY)
        trackpadSwapAxis = settings.bool(.trackpadSwapAxis)
        touchSensitivity = settings.bool(.enableTouchSensitivity)
        touchSensitivityX = settings.int(.touchSensitivityOpacityX)
        touchSensitivityY = settings.int(.touchSensitivityOpacityY)
        touchSensitivityGlobal = settings.bool(.enableGlobalTouchSensitivity)
        touchSensitivityRotationAuto = settings.bool(.enableTouchSensitivityRotationAuto)
        rememberZoomPan = settings.bool(.rememberZoomPan)
    }
}

/// The zoom and pan the last stream left, kept for the next one when the profile remembers them
/// (`number_zoom_scale`, `number_pan_offset_x`, `number_pan_offset_y`). Like DELOS for Android, which writes them to the
/// app's base preferences, they belong to the device, not to a profile.
public struct ZoomPanStore: Sendable {
    public struct Saved: Equatable, Sendable {
        public var scale: Double
        public var x: Double
        public var y: Double

        public init(scale: Double, x: Double, y: Double) {
            self.scale = scale
            self.x = x
            self.y = y
        }
    }

    static let scaleKey = "number_zoom_scale"
    static let xKey = "number_pan_offset_x"
    static let yKey = "number_pan_offset_y"

    private let suiteName: String?

    /// `suiteName` nil: the standard defaults.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    /// What the last stream left; nil when nothing was saved.
    public func load() -> Saved? {
        let defaults = defaults
        guard defaults.object(forKey: Self.scaleKey) != nil else { return nil }
        return Saved(scale: defaults.double(forKey: Self.scaleKey), x: defaults.double(forKey: Self.xKey), y: defaults.double(forKey: Self.yKey))
    }

    public func save(_ saved: Saved) {
        let defaults = defaults
        defaults.set(saved.scale, forKey: Self.scaleKey)
        defaults.set(saved.x, forKey: Self.xKey)
        defaults.set(saved.y, forKey: Self.yKey)
    }
}
