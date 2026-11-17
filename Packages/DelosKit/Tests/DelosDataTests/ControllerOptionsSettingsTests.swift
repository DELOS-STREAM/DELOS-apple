import DelosInput
import Testing
@testable import DelosData

@Suite struct ControllerOptionsSettingsTests {
    @Test func theDefaultsAreAndroidsAndEveryKeyIsRead() {
        #expect(ControllerOptions(settings: StreamSettings()) == ControllerOptions())
        var settings = StreamSettings()
        settings.set(.deadzone, .int(-7))
        settings.set(.multiController, .bool(false))
        settings.set(.analogScrolling, .text("left"))
        settings.set(.gyroSmoothing, .int(40))
        settings.set(.rightAltAsMeta, .bool(true))
        settings.set(.mouseNavButtons, .bool(true))
        settings.set(.gamepadMotionFallback, .bool(true))
        let options = ControllerOptions(settings: settings)
        #expect(options.deadzonePercent == -7 && !options.multiController && options.scrollStick == .left)
        #expect(options.gyroSmoothing == 40 && options.rightAltAsMeta && options.mouseNavButtons)
        #expect(options.motionFallbackToDevice && options.mouseEmulation && options.batteryReport)
    }
}
