import Testing
@testable import DelosMedia

/// Android's SgsrDimensionsTest, OverloadDetectorTest, FlowGovernorTest and GpuInFlight rules, with the same vectors.
@Suite struct UpscalerLoadTests {
    // MARK: Sizes (SgsrDimensionsTest)

    @Test func native1080pSupersamplesTo1440pAtLevelOneAnd4KAtLevelTwo() {
        let one = UpscalerDimensions.plan(source: (1920, 1080), presentation: (1920, 1080), maxTextureSize: 8192, supersamplingLevel: 1)
        #expect(one.isSupersampling && one.internalWidth == 2560 && one.internalHeight == 1440)
        let two = UpscalerDimensions.plan(source: (1920, 1080), presentation: (1920, 1080), maxTextureSize: 8192, supersamplingLevel: 2)
        #expect(two.isSupersampling && two.internalWidth == 3840 && two.internalHeight == 2160)
    }

    @Test func aOnePixelAspectFitDifferenceStillSupersamples() {
        let plan = UpscalerDimensions.plan(source: (1920, 1080), presentation: (1920, 1079), maxTextureSize: 8192, supersamplingLevel: 2)
        #expect(plan.isSupersampling && plan.internalWidth == 3840 && plan.internalHeight == 2156)
    }

    @Test func aSmallerStreamIsUpscaledToTheView() {
        let plan = UpscalerDimensions.plan(source: (1280, 720), presentation: (1920, 1080), maxTextureSize: 8192, supersamplingLevel: 2)
        #expect(!plan.isSupersampling && plan.internalWidth == 1920 && plan.internalHeight == 1080)
    }

    @Test func the4KAndTextureLimitsAndLargerStreamsNeverSupersample() {
        #expect(!UpscalerDimensions.plan(source: (3840, 2160), presentation: (3840, 2160), maxTextureSize: 16384, supersamplingLevel: 2).isSupersampling)
        #expect(!UpscalerDimensions.plan(source: (1920, 1080), presentation: (1920, 1080), maxTextureSize: 2048, supersamplingLevel: 2).isSupersampling)
        let larger = UpscalerDimensions.plan(source: (2560, 1440), presentation: (1920, 1080), maxTextureSize: 8192, supersamplingLevel: 1)
        #expect(!larger.isSupersampling && larger.internalWidth == 1920 && larger.internalHeight == 1080)
    }

    @Test func theNativeToleranceIsInclusive() {
        #expect(UpscalerDimensions.isNativeInput(source: (1920, 1080), presentation: (1922, 1080)))
        #expect(!UpscalerDimensions.isNativeInput(source: (1920, 1080), presentation: (1923, 1080)))
    }

    // MARK: Overload (OverloadDetectorTest)

    private func window(arrived: Int, draws: Int, busy: Int, gpu: Double) -> UpscalerWindow {
        UpscalerWindow(draws: draws, busySkipped: busy, gpuAverageMilliseconds: gpu, gpuMaximumMilliseconds: gpu, arrived: arrived, seconds: 1)
    }

    @Test func aGPUTimeAboveNinetyPercentOfTheFramePeriodIsOverloaded() {
        #expect(OverloadDetector.isOverloaded(window(arrived: 120, draws: 100, busy: 0, gpu: 10)))
        #expect(!OverloadDetector.isOverloaded(window(arrived: 120, draws: 120, busy: 0, gpu: 7.4)))
        #expect(!OverloadDetector.isOverloaded(window(arrived: 60, draws: 60, busy: 0, gpu: 10)))
    }

    @Test func manyFramesDroppedForABusyGPUAreOverloadWithoutAGPUTime() {
        #expect(OverloadDetector.isOverloaded(window(arrived: 120, draws: 80, busy: 30, gpu: -1)))
        #expect(!OverloadDetector.isOverloaded(window(arrived: 120, draws: 110, busy: 10, gpu: -1)))
    }

    @Test func twoOverloadedWindowsInARowReportOnceAndAHealthyOneBreaksTheStreak() {
        var detector = OverloadDetector()
        let heavy = window(arrived: 120, draws: 90, busy: 30, gpu: 10)
        let healthy = window(arrived: 120, draws: 120, busy: 0, gpu: 5)
        // A window with few frames neither counts nor breaks the streak
        let few = window(arrived: 5, draws: 5, busy: 0, gpu: 1)
        let reports = [heavy, heavy, heavy, heavy, heavy, healthy, heavy, few, heavy].map { detector.onWindow($0) }
        #expect(reports == [false, true, false, true, false, false, false, false, true])
        _ = detector.onWindow(heavy)
        detector.reset()
        let afterReset = detector.onWindow(heavy)
        #expect(!afterReset)
    }

    // MARK: Flow (FlowGovernorTest)

    @Test func aboveSeventyPercentEverySecondFrameReusesTheFlowUntilBelowFortyFive() {
        var governor = FlowGovernor()
        let light = governor.onWindow(window(arrived: 120, draws: 120, busy: 0, gpu: 5))
        let unchanged = (0..<4).map { _ in governor.reuseFlowThisFrame() }
        let entered = governor.onWindow(window(arrived: 120, draws: 120, busy: 0, gpu: 6.5))
        let reduced = (0..<6).map { _ in governor.reuseFlowThisFrame() }
        let stays = governor.onWindow(window(arrived: 120, draws: 120, busy: 0, gpu: 5))
        let left = governor.onWindow(window(arrived: 120, draws: 120, busy: 0, gpu: 3.5))
        #expect(!light && unchanged == [false, false, false, false])
        #expect(entered && reduced == [false, true, false, true, false, true])
        #expect(!stays && left && !governor.reduced)
    }

    @Test func windowsWithoutAGPUTimeOrWithFewFramesAreIgnored() {
        var governor = FlowGovernor()
        let changes = [
            window(arrived: 120, draws: 120, busy: 0, gpu: -1), window(arrived: 5, draws: 5, busy: 0, gpu: 9),
            window(arrived: 60, draws: 60, busy: 0, gpu: 9),
        ].map { governor.onWindow($0) }
        #expect(changes == [false, false, false])
        _ = governor.onWindow(window(arrived: 120, draws: 120, busy: 0, gpu: 8))
        governor.reset()
        let reuse = governor.reuseFlowThisFrame()
        #expect(!governor.reduced && !reuse)
    }

    // MARK: GPU frames in flight (GpuInFlight)

    @Test func twoFramesInFlightHoldTheNextDrawUntilOneFinishesOrIsStuck() {
        var inFlight = GPUInFlight()
        var skips: [Bool] = []
        skips.append(inFlight.shouldSkip(now: 0))
        inFlight.submitted()
        inFlight.submitted()
        skips.append(inFlight.shouldSkip(now: 1))
        skips.append(inFlight.shouldSkip(now: 1.2))
        inFlight.finished()
        skips.append(inFlight.shouldSkip(now: 1.21))
        inFlight.submitted()
        skips.append(inFlight.shouldSkip(now: 2))
        // A frame that never finishes does not freeze the picture
        skips.append(inFlight.shouldSkip(now: 2.26))
        #expect(skips == [false, true, true, false, true, false])
        #expect(inFlight.count == 0)
    }

    @Test func theWindowMeterClosesASecondOfFrames() {
        var meter = UpscalerWindowMeter()
        for i in 0..<60 { meter.arrived(at: Double(i) / 60) }
        var closed: UpscalerWindow?
        for i in 0..<61 {
            if i % 10 == 0 { meter.gpuWork(seconds: 0.004) }
            if let window = meter.drew(at: Double(i) / 60) { closed = window }
        }
        let window = closed
        #expect(window?.draws == 61)
        #expect(window?.arrived == 60)
        #expect(window.map { abs($0.gpuAverageMilliseconds - 4) < 1e-9 } == true)
    }

    @Test func theSettingsClampAsAndroidDoes() {
        var settings = UpscalerSettings(sharpness: 140, supersamplingLevel: 7)
        #expect(settings.sharpness == 100 && settings.supersamplingLevel == 2)
        settings.sharpness = -3
        settings.supersamplingLevel = 0
        #expect(settings.sharpness == 0 && settings.supersamplingLevel == 1)
        #expect(UpscalerMode(value: "temporal-quality") == .temporalQuality)
        #expect(UpscalerMode(value: "newer") == .standard)
        #expect(UpscalerMode(index: 9) == .sharpen && UpscalerMode.sharpen.index == 4)
        #expect(!UpscalerMode.sharpen.scales && UpscalerMode.temporal.isTemporal)
        #expect(VideoScaleMode(value: "stretch") == .stretch && VideoScaleMode(value: "?") == .fit)
        #expect(UpscalerStatus.starting.isChanging && !UpscalerStatus.on(.high).isChanging)
    }
}
