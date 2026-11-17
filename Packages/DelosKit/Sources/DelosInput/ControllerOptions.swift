/// The settings of the stream's controller, keyboard and mouse input (Settings → Controls), with DELOS for Android's
/// keys and defaults (`PreferenceConfiguration`). ``GameInput`` reads them once when the stream starts, except the gyro
/// smoothing, which the stream menu changes live (``GameInput/gyroSmoothing``).
public struct ControllerOptions: Sendable, Equatable {
    /// Which stick scrolls while the mouse emulation runs (`analog_scrolling`: "right", "left", "none").
    public enum ScrollStick: String, Sendable, CaseIterable {
        /// The right stick scrolls, the left one moves the pointer.
        case right
        /// The left stick scrolls, the right one moves the pointer.
        case left
        /// Both sticks move the pointer.
        case none
    }

    /// The sticks' dead zone in percent of their travel, −20…20 (`seekbar_deadzone`, 5). A negative value shrinks the
    /// travel a stick needs instead (``GamepadMapping/applyDeadzone(x:y:radius:)``).
    public var deadzonePercent = 5
    /// Every controller is its own player (`checkbox_multi_controller`, on); off, all of them are player 1.
    public var multiController = true
    /// Holding Start (Menu, Options) for ¾ s turns the sticks into the mouse (`checkbox_mouse_emulation`, on).
    public var mouseEmulation = true
    /// `analog_scrolling`, "right".
    public var scrollStick = ScrollStick.right
    /// A and B, X and Y swap places (`checkbox_flip_face_buttons`, off).
    public var flipFaceButtons = false
    /// A PlayStation controller's touchpad moves the PC's mouse instead of being the touchpad of the PC's controller
    /// (`checkbox_gamepad_touchpad_as_mouse`, off).
    public var touchpadAsMouse = false
    /// The controllers' own motion sensors reach the PC (`checkbox_gamepad_motion_sensors`, on).
    public var motionSensors = true
    /// Player 1 uses this device's motion sensors when its controller has none (`checkbox_gamepad_motion_fallback`, off).
    public var motionFallbackToDevice = false
    /// With the fallback on, player 1 uses this device's sensors even when its controller has its own
    /// (`checkbox_force_device_motion`, off).
    public var forceDeviceMotion = false
    /// Gyro smoothing, 0 (off) … 100 (`seekbar_gyro_smoothing`, 0; ``GyroSmoother``).
    public var gyroSmoothing = GyroSmoother.off
    /// The controllers' battery reaches the PC (`checkbox_gamepad_enable_battery_report`, on).
    public var batteryReport = true
    /// The right Option (Alt) key is the PC's Windows key (`checkbox_right_alt_as_meta`, off).
    public var rightAltAsMeta = false
    /// A mouse's back and forward buttons are the PC's X1 and X2 (`checkbox_mouse_nav_buttons`, off); off, they send
    /// nothing.
    public var mouseNavButtons = false

    public init() {}
}
