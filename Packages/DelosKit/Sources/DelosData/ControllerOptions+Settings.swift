import DelosInput

extension ControllerOptions {
    /// The profile's Controls settings under DELOS for Android's keys (`PreferenceConfiguration`).
    public init(settings: StreamSettings) {
        self.init()
        deadzonePercent = settings.int(.deadzone)
        multiController = settings.bool(.multiController)
        mouseEmulation = settings.bool(.mouseEmulation)
        scrollStick = ScrollStick(rawValue: settings.text(.analogScrolling)) ?? .right
        flipFaceButtons = settings.bool(.flipFaceButtons)
        touchpadAsMouse = settings.bool(.gamepadTouchpadAsMouse)
        motionSensors = settings.bool(.gamepadMotionSensors)
        motionFallbackToDevice = settings.bool(.gamepadMotionFallback)
        forceDeviceMotion = settings.bool(.forceDeviceMotion)
        gyroSmoothing = settings.int(.gyroSmoothing)
        batteryReport = settings.bool(.gamepadEnableBatteryReport)
        rightAltAsMeta = settings.bool(.rightAltAsMeta)
        mouseNavButtons = settings.bool(.mouseNavButtons)
    }
}
