import QuartzCore
import Testing
@testable import DelosMedia

/// Android's StreamDisplayPlannerTest, with its panel and vectors, plus the Apple displays the plan is made for.
@Suite struct DisplayRefreshPlannerTests {
    // A 1080p panel with 60, 90, 120 and 144 Hz modes
    let hz60 = DisplayMode(id: 1, width: 1920, height: 1080, refreshRate: 60)
    let hz90 = DisplayMode(id: 2, width: 1920, height: 1080, refreshRate: 90)
    let hz120 = DisplayMode(id: 3, width: 1920, height: 1080, refreshRate: 120)
    let hz144 = DisplayMode(id: 4, width: 1920, height: 1080, refreshRate: 144)
    var panel: [DisplayMode] { [hz60, hz90, hz120, hz144] }

    /// A 1080p stream (a preset, not native) on the panel, Balanced pacing.
    private func plan(
        _ current: DisplayMode, _ fps: Double, pacing: FramePacing = .balanced, reduce: Bool = false, enforce: Bool = false,
        modes: [DisplayMode]? = nil, currentRate: Double? = nil, ceiling: Double = .infinity, television: Bool = false,
        external: Bool = false, stream: (Int, Int) = (1920, 1080), vrr: Bool = false
    ) -> DisplayRefreshPlanner.Plan {
        DisplayRefreshPlanner.plan(DisplayRefreshPlanner.Input(
            display: VideoDisplay(
                currentMode: current, supportedModes: modes ?? panel, currentRefreshRate: currentRate ?? current.refreshRate,
                television: television, externalDisplay: external),
            streamWidth: stream.0, streamHeight: stream.1, fps: fps, pacing: pacing, reduceRefreshRate: reduce,
            enforceDisplayMode: enforce, refreshRateCeiling: ceiling, vrr: vrr))
    }

    @Test func theMatchRules() {
        #expect(DisplayRefreshPlanner.isRefreshRateEqualMatch(63, fps: 60))
        #expect(!DisplayRefreshPlanner.isRefreshRateEqualMatch(63.5, fps: 60))
        #expect(DisplayRefreshPlanner.isRefreshRateEqualMatch(59.94, fps: 60))
        #expect(!DisplayRefreshPlanner.isRefreshRateEqualMatch(59, fps: 60))
        #expect(DisplayRefreshPlanner.isRefreshRateGoodMatch(120, fps: 60))
        #expect(DisplayRefreshPlanner.isRefreshRateGoodMatch(144, fps: 72))
        #expect(DisplayRefreshPlanner.isRefreshRateGoodMatch(59.94, fps: 30))
        #expect(!DisplayRefreshPlanner.isRefreshRateGoodMatch(90, fps: 60))
        #expect(!DisplayRefreshPlanner.isRefreshRateGoodMatch(144, fps: 120))
        #expect(DisplayRefreshPlanner.reachesFPS(23.976, fps: 24))
        #expect(!DisplayRefreshPlanner.reachesFPS(119, fps: 120))
        #expect(DisplayRefreshPlanner.mayReduceRefreshRate(.capFPS, reduceRefreshRate: false))
        #expect(DisplayRefreshPlanner.mayReduceRefreshRate(.balanced, reduceRefreshRate: true))
        #expect(!DisplayRefreshPlanner.mayReduceRefreshRate(.latency, reduceRefreshRate: true))
        #expect(!DisplayRefreshPlanner.isNativeResolution(width: 1920, height: 1080))
        #expect(DisplayRefreshPlanner.isNativeResolution(width: 2400, height: 1080))
    }

    @Test func sixtyFPSPicksTheHighestMultipleUnlessTheRateMayBeReduced() {
        let plan = plan(hz60, 60)
        #expect(plan.bestMode == hz120 && plan.modeSwitch == .setFrameRate)
        #expect(plan.desiredRefreshRate == 120 && plan.displayRefreshRate == 120 && plan.streamFrameRate == 60)
        #expect(plan.surfaceFrameRate == 120)
        #expect(self.plan(hz120, 60).modeSwitch == .none)
        let reduced = self.plan(hz120, 60, reduce: true)
        #expect(reduced.bestMode == hz60 && reduced.displayRefreshRate == 60 && reduced.surfaceFrameRate == 60)
        #expect(self.plan(hz144, 60, pacing: .smoothness).bestMode == hz60)
        #expect(self.plan(hz60, 60, pacing: .latency, reduce: true).bestMode == hz120)
        #expect(self.plan(hz60, 30).bestMode == hz120)
        #expect(self.plan(hz144, 30, reduce: true).bestMode == hz60)
        #expect(self.plan(hz60, 90).bestMode == hz90)
        #expect(self.plan(hz144, 240).bestMode == hz144)
        #expect(self.plan(hz120, 50).bestMode == hz144)
    }

    @Test func aSixtyFPSStreamStaysOnA5994HzModeWhenReducing() {
        let ntsc = DisplayMode(id: 1, width: 1920, height: 1080, refreshRate: 59.94)
        let hz50 = DisplayMode(id: 2, width: 1920, height: 1080, refreshRate: 50)
        let modes = [hz50, ntsc, hz120]
        #expect(plan(ntsc, 60, reduce: true, modes: modes).bestMode == ntsc)
        #expect(plan(hz50, 60, reduce: true, modes: modes).bestMode == ntsc)
    }

    @Test func aRefreshOnlySwitchIsAModeSwitchWhenEnforcedAndAResolutionSwitchAlways() {
        #expect(plan(hz60, 60, enforce: true).modeSwitch == .preferredMode)
        let uhd60 = DisplayMode(id: 1, width: 3840, height: 2160, refreshRate: 60)
        let fhd120 = DisplayMode(id: 2, width: 1920, height: 1080, refreshRate: 120)
        let drop = plan(uhd60, 120, modes: [uhd60, fhd120])
        #expect(drop.bestMode == fhd120 && drop.modeSwitch == .preferredMode)
        // The stream would not fit the smaller mode
        #expect(plan(uhd60, 120, modes: [uhd60, fhd120], stream: (2560, 1440)).bestMode == uhd60)
        // A preset stream up to 60 FPS keeps the resolution; modes wider than 4K are skipped
        let fhd60 = DisplayMode(id: 1, width: 1920, height: 1080, refreshRate: 60)
        let uhd120 = DisplayMode(id: 2, width: 3840, height: 2160, refreshRate: 120)
        #expect(plan(fhd60, 60, modes: [fhd60, uhd120]).bestMode == fhd60)
        #expect(plan(fhd60, 120, modes: [fhd60, uhd120]).bestMode == uhd120)
        #expect(plan(fhd60, 120, modes: [fhd60, DisplayMode(id: 2, width: 5120, height: 2880, refreshRate: 120)]).bestMode == fhd60)
        // A native stream may change the resolution at 60 FPS
        let small = DisplayMode(id: 1, width: 1600, height: 720, refreshRate: 60)
        let native = DisplayMode(id: 2, width: 2400, height: 1080, refreshRate: 60)
        #expect(plan(small, 60, modes: [small, native], stream: (2400, 1080)).bestMode == native)
    }

    @Test func theExpectedRefreshRateRespectsTheCeilingExceptOnTVsAndExternalDisplays() {
        let capped = plan(hz60, 60, ceiling: 60)
        #expect(capped.bestMode == hz120 && capped.desiredRefreshRate == 120 && capped.displayRefreshRate == 60)
        #expect(plan(hz60, 120, ceiling: 90).displayRefreshRate == 60)
        #expect(plan(hz60, 90, ceiling: 90).displayRefreshRate == 90)
        #expect(plan(hz60, 60, ceiling: 60, television: true).displayRefreshRate == 120)
        #expect(plan(hz60, 60, ceiling: 60, external: true).displayRefreshRate == 120)
        // A display running below its mode's rate is not expected to rise
        #expect(plan(hz120, 60, currentRate: 60).displayRefreshRate == 60)
    }

    @Test func capFPSCapsOneBelowTheRefreshRateOrFallsBackToBalanced() {
        let capped = plan(hz60, 60, pacing: .capFPS, modes: [hz60])
        #expect(capped.pacingChange == .cappedBelowRefreshRate && capped.pacedFrameRate == 59 && capped.pacing == .capFPS)
        let above = plan(hz60, 90, pacing: .capFPS, modes: [hz60])
        #expect(above.pacingChange == .dropFramesAboveRefreshRate && above.pacing == .balanced)
        let low = DisplayMode(id: 9, width: 1920, height: 1080, refreshRate: 48)
        #expect(plan(low, 48, pacing: .capFPS, modes: [low]).pacingChange == .bogusRefreshRate)
        // Warp asks the host for twice and four times the frame rate
        #expect(plan(hz60, 60, pacing: .warp).streamFrameRate == 120)
        #expect(plan(hz60, 60, pacing: .warp2).streamFrameRate == 240)
    }

    @Test func vrrPlansThePeakAndAsksForTheStreamsOwnRate() {
        let plan = plan(hz60, 60, vrr: true)
        #expect(plan.vrr && plan.displayRefreshRate == 144 && plan.surfaceFrameRate == 60)
        #expect(plan.frameRateRange.minimum == 60 && plan.frameRateRange.maximum == 60 && plan.frameRateRange.preferred == 60)
        #expect(VariableRefreshRate(value: "on").resolve(reported: false))
        #expect(!VariableRefreshRate(value: "off").resolve(reported: true))
        #expect(VariableRefreshRate(value: "unknown").resolve(reported: true))
    }

    @Test func aBuiltInPanelOffersItsRateAndItsFractions() {
        let promotion = VideoDisplay.builtIn(width: 2796, height: 1290, maxFramesPerSecond: 120)
        #expect(promotion.supportedModes.map(\.refreshRate) == [120, 60, 40, 30, 24])
        #expect(VideoDisplay.builtIn(width: 1920, height: 1080, maxFramesPerSecond: 60).supportedModes.map(\.refreshRate) == [60, 30])
        // Default settings keep ProMotion at 120 Hz; reducing the refresh rate runs it at the stream's 60
        let options = VideoRenderOptions(streamWidth: 1920, streamHeight: 1080, frameRate: 60)
        #expect(options.refreshPlan(for: promotion, pacing: .balanced, fps: 60).surfaceFrameRate == 120)
        var reduce = options
        reduce.reduceRefreshRate = true
        let reduced = reduce.refreshPlan(for: promotion, pacing: .balanced, fps: 60)
        #expect(reduced.surfaceFrameRate == 60 && reduced.displayRefreshRate == 60 && reduced.modeSwitch == .setFrameRate)
        // Low Power Mode holds ProMotion at 60 Hz: the stream is told 60
        let limited = VideoDisplay.builtIn(width: 2796, height: 1290, maxFramesPerSecond: 120, limited: true)
        #expect(options.refreshPlan(for: limited, pacing: .balanced, fps: 60).displayRefreshRate == 60)
        // A 120 FPS stream on ProMotion runs at 120 Hz
        #expect(VideoRenderOptions(frameRate: 120).refreshPlan(for: promotion, pacing: .latency, fps: 120).surfaceFrameRate == 120)
    }
}
