import DelosData
import DelosMedia
import Foundation
import Testing
@testable import DelosUI

@MainActor
@Suite struct StreamMenuPagesTests {
    @Test func theMenuWritesItsChangesOnceTheySettleOrWhenFlushed() {
        var now = 0.0
        var written: [[SettingKey: StoredSetting]] = []
        let save = MenuAutoSave(clock: { now }, values: { setting in
            setting == .gyroSmoothing ? [.gyroSmoothing: .int(30)] : [.upscalerSharpness: .int(40)]
        }, write: { written.append($0) })
        #expect(save.nextDelay() == nil)
        save.changed(.gyroSmoothing)
        now = 0.3
        save.changed(.gyroSmoothing)
        save.tick()
        #expect(written.isEmpty)
        now = 0.8
        save.tick()
        #expect(written == [[.gyroSmoothing: .int(30)]])
        save.changed(.upscaler)
        save.flush()
        #expect(written.last == [.upscalerSharpness: .int(40)])
        #expect(save.nextDelay() == nil)
    }

    @Test func aTapFocusesAChoiceFirstThenOpensItsListAndADisabledRowRefuses() {
        let choice = StreamMenuRow(
            id: "mode", icon: "", label: "Mode", value: .choice(label: "A", options: ["A", "B"], selected: 0), help: "", activate: {},
            set: { _ in })
        #expect(choice.tap(wasFocused: false) == .focus)
        #expect(choice.tap(wasFocused: true) == .popup)
        let off = StreamMenuRow(id: "x", icon: "", label: "", value: .action, enabled: false, help: "", activate: {})
        #expect(off.tap(wasFocused: true) == .refuse)
        let action = StreamMenuRow(id: "y", icon: "", label: "", value: .text(""), help: "", activate: {})
        #expect(action.tap(wasFocused: false) == .activate)
    }

    @Test func aSliderReadsItsMinTextAndItsDivisor() {
        let gyro = StreamMenuRow(
            id: "g", icon: "", label: "", value: .slider(value: 0, range: 0...100, step: 5, unit: " %", minText: "0 % (off)"), help: "",
            activate: {}, set: { _ in })
        #expect(gyro.sliderSpec?.label(0) == "0 % (off)")
        let bitrate = StreamMenuRow(
            id: "b", icon: "", label: "", value: .slider(value: 20_000, range: 1000...1_000_000, step: 1000, unit: " Mbps", divisor: 1000),
            help: "", activate: {}, set: { _ in })
        #expect(bitrate.sliderSpec?.label(20_000) == "20 Mbps")
        #expect(bitrate.stepped(1, steps: 5) == 25_000)
    }

    @Test func anOutsideTapDoesNothingWhileTheMenuCloses() {
        #expect(StreamMenuNavigation.afterOutsideTap(.main, closing: true) == .none)
        #expect(StreamMenuNavigation.afterOutsideTap(.main) == .closeMenu)
        #expect(StreamMenuNavigation.afterBack(.rumble) == PageExit(page: .more, focusTile: nil, focusRow: .rumble))
        #expect(StreamMenuNavigation.afterBack(.upscaler) == PageExit(page: .main, focusTile: .upscaler, focusRow: nil))
    }

    @Test func theDisplayLayersUpscalerKeepsTheChoicesAndSaysUnavailable() {
        var settings = StreamSettings()
        settings.set(.upscaler, .bool(true))
        settings.set(.upscalerMode, .text("sharpen"))
        var options = VideoRenderOptions()
        options.upscaler = settings.upscalerSettings
        let upscaler = RendererUpscaler(renderer: RendererChoice.layer.makeRenderer(pacing: .phaseLock, fps: 60, options: options))
        #expect(!upscaler.available && upscaler.status == .unavailable && upscaler.mode == .sharpen)
        #expect(upscaler.status.pill == L("stream_menu_upscaler_unavailable"))
        upscaler.setSharpness(30)
        #expect(upscaler.sharpness == 30)
        #expect(UpscalerMode.sharpen.next(1) == .spatial && UpscalerMode.spatial.next(-1) == .sharpen)
        #expect(UpscalerSave.values(upscaler)[.upscalerMode] == .text("sharpen"))
        #expect(UpscalerMode.sharpen.label == L("sgsr_quality_sharpen"))
    }

    @Test func helpParagraphsFlowIntoOneLine() {
        #expect(StreamMenuText.helpLine("Off\n\nTurns it on.") == "Off \u{00B7} Turns it on.")
        #expect(StreamMenuText.helpLine("One.\nTwo") == "One. Two")
    }
}
