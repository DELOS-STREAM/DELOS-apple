import DelosInput
import Foundation
import Testing
@testable import DelosData

@Suite struct TouchOptionsSettingsTests {
    @Test func theDefaultsAreAndroidsAndEveryKeyIsRead() {
        #expect(TouchOptions(settings: StreamSettings()) == TouchOptions())
        var settings = StreamSettings()
        settings.set(.touchMode, .text("3"))
        settings.set(.rememberMouseMode, .bool(true))
        settings.set(.mouseLocalCursor, .bool(true))
        settings.set(.multiTouchGestures, .bool(true))
        settings.set(.absoluteMouseMode, .bool(true))
        settings.set(.touchpadSensitivityOpacity, .int(150))
        settings.set(.touchpadSensitivityYOpacity, .int(50))
        settings.set(.trackpadSensitivityX, .int(-120))
        settings.set(.trackpadSensitivityY, .int(180))
        settings.set(.trackpadSwapAxis, .bool(true))
        settings.set(.enableTouchSensitivity, .bool(true))
        settings.set(.touchSensitivityOpacityX, .int(250))
        settings.set(.touchSensitivityOpacityY, .int(20))
        settings.set(.enableGlobalTouchSensitivity, .bool(true))
        settings.set(.enableTouchSensitivityRotationAuto, .bool(false))
        settings.set(.rememberZoomPan, .bool(true))
        let options = TouchOptions(settings: settings)
        #expect(options.mode == .trackpadGaming && options.rememberMode && options.localCursor && options.multiTouchGestures)
        #expect(options.absoluteMouseMode && options.touchpadSensitivityX == 150 && options.touchpadSensitivityY == 50)
        #expect(options.trackpadSensitivityX == -120 && options.trackpadSensitivityY == 180 && options.trackpadSwapAxis)
        #expect(options.touchSensitivity && options.touchSensitivityX == 250 && options.touchSensitivityY == 20)
        #expect(options.touchSensitivityGlobal && !options.touchSensitivityRotationAuto && options.rememberZoomPan)
    }

    @Test func theZoomAndPanAreKeptOnTheDevice() throws {
        let suite = "touch-options-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = ZoomPanStore(suiteName: suite)
        #expect(store.load() == nil)
        store.save(ZoomPanStore.Saved(scale: 2.5, x: -300, y: -40))
        #expect(store.load() == ZoomPanStore.Saved(scale: 2.5, x: -300, y: -40))
    }
}
