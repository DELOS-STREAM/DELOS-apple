import Foundation
import QuartzCore

/// A display mode: size in pixels and refresh rate.
public struct DisplayMode: Sendable, Equatable {
    /// The platform's identity of the mode (the index among the display's modes).
    public var id: Int
    public var width: Int
    public var height: Int
    public var refreshRate: Double

    public init(id: Int, width: Int, height: Int, refreshRate: Double) {
        self.id = id
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
    }
}

/// The display a stream is shown on, as the view finds it.
public struct VideoDisplay: Sendable, Equatable {
    /// The mode the display runs.
    public var currentMode: DisplayMode
    /// The modes the display can run, in the system's order. A built-in iPhone or iPad panel has one size and the
    /// refresh rates its display link can ask for (``VideoDisplay/builtIn(width:height:maxFramesPerSecond:)``).
    public var supportedModes: [DisplayMode]
    /// The refresh rate the display runs right now (Low Power Mode can hold it below the mode's).
    public var currentRefreshRate: Double
    /// Apple TV: the TV switches modes itself when its owner allows matching (`AVDisplayManager`).
    public var television: Bool
    /// An external display (a Mac's second screen, an iPad's external display).
    public var externalDisplay: Bool
    /// The display reports adaptive sync (variable refresh rate): a Mac display whose minimum refresh interval is shorter
    /// than its maximum. ProMotion panels of iPhone and iPad report none: iOS offers no Adaptive-Sync presentation.
    public var reportsVariableRefreshRate: Bool
    /// The highest refresh rate the system grants the app now (Android `refreshRateCeiling`): Low Power Mode and a hot
    /// device hold the panel at its current rate; infinity when nothing is known to limit it.
    public var refreshRateCeiling: Double

    public init(
        currentMode: DisplayMode, supportedModes: [DisplayMode], currentRefreshRate: Double, television: Bool = false,
        externalDisplay: Bool = false, reportsVariableRefreshRate: Bool = false, refreshRateCeiling: Double = .infinity
    ) {
        self.currentMode = currentMode
        self.supportedModes = supportedModes
        self.currentRefreshRate = currentRefreshRate
        self.television = television
        self.externalDisplay = externalDisplay
        self.reportsVariableRefreshRate = reportsVariableRefreshRate
        self.refreshRateCeiling = refreshRateCeiling
    }

    /// A panel of one size whose display link can run its highest rate and the whole fractions of it down to 24 Hz
    /// (120, 60, 40, 30, 24 on ProMotion; 60, 30 on a 60 Hz panel): the "modes" `preferredFrameRateRange` chooses among.
    /// `limited` is Low Power Mode or a serious thermal state: ProMotion then runs at most 60 Hz, which becomes the current
    /// rate and the ceiling (Android: battery saver and thermal throttling hold the current rate).
    public static func builtIn(
        width: Int, height: Int, maxFramesPerSecond: Int, television: Bool = false, externalDisplay: Bool = false,
        limited: Bool = false
    ) -> VideoDisplay {
        let fastest = max(1, maxFramesPerSecond)
        var modes: [DisplayMode] = []
        var divisor = 1
        while modes.isEmpty || Double(fastest) / Double(divisor) >= 24 {
            modes.append(DisplayMode(id: divisor - 1, width: width, height: height, refreshRate: Double(fastest) / Double(divisor)))
            divisor += 1
        }
        let current = limited ? Double(min(fastest, 60)) : Double(fastest)
        return VideoDisplay(
            currentMode: modes[0], supportedModes: modes, currentRefreshRate: current, television: television,
            externalDisplay: externalDisplay, refreshRateCeiling: limited ? current : .infinity)
    }
}

/// Chooses the display mode, refresh rate and frame rate of a stream (Android `StreamDisplayPlanner.java`, line by line).
/// Pure; the renderer applies the ``Plan``: the refresh rate its display link asks for, the mode switch where the platform
/// has one (the Mac's display modes, Apple TV's display criteria), and the refresh rate the host is told.
public enum DisplayRefreshPlanner {
    /// Slack for comparing refresh rates reported as floats (60.000004 Hz is 60 Hz).
    static let rateTolerance = 0.1

    /// How the chosen mode is applied.
    public enum ModeSwitch: Sendable, Equatable {
        /// The current mode is already the best one.
        case none
        /// Switch the display's mode (the Mac's `CGDisplayMode`, Apple TV's display criteria).
        case preferredMode
        /// Only the refresh rate differs: the display link's frame rate asks for it.
        case setFrameRate
    }

    /// What Cap FPS did with the stream frame rate.
    public enum PacingChange: Sendable, Equatable {
        case none
        /// The stream FPS is more than 3 above the refresh rate: Balanced (frame drops) instead.
        case dropFramesAboveRefreshRate
        /// The refresh rate is 49 Hz or lower, likely bogus: Balanced instead.
        case bogusRefreshRate
        /// The stream frame rate is capped 1 FPS below the refresh rate.
        case cappedBelowRefreshRate
    }

    public struct Input: Sendable, Equatable {
        public var display: VideoDisplay
        /// The stream's resolution and frame rate from the settings (before the warp factor and the cap).
        public var streamWidth: Int
        public var streamHeight: Int
        public var fps: Double
        public var pacing: FramePacing
        public var reduceRefreshRate: Bool
        public var enforceDisplayMode: Bool
        /// The highest refresh rate the system grants the app now (Low Power Mode holds the panel); infinity when unknown.
        public var refreshRateCeiling: Double
        /// Variable refresh rate is active (``VariableRefreshRate/resolve(reported:)``).
        public var vrr: Bool

        public init(
            display: VideoDisplay, streamWidth: Int, streamHeight: Int, fps: Double, pacing: FramePacing, reduceRefreshRate: Bool,
            enforceDisplayMode: Bool, refreshRateCeiling: Double = .infinity, vrr: Bool
        ) {
            self.display = display
            self.streamWidth = streamWidth
            self.streamHeight = streamHeight
            self.fps = fps
            self.pacing = pacing
            self.reduceRefreshRate = reduceRefreshRate
            self.enforceDisplayMode = enforceDisplayMode
            self.refreshRateCeiling = refreshRateCeiling
            self.vrr = vrr
        }
    }

    public struct Plan: Sendable, Equatable {
        public var currentMode: DisplayMode
        public var bestMode: DisplayMode
        public var modeSwitch: ModeSwitch
        /// The best mode's refresh rate.
        public var desiredRefreshRate: Double
        /// The refresh rate the display is expected to run: reported to the host and used by Cap FPS.
        public var displayRefreshRate: Double
        /// The pacing after the Cap FPS adjustment.
        public var pacing: FramePacing
        public var pacingChange: PacingChange
        public var roundedRefreshRate: Int
        /// The stream frame rate after the Cap FPS adjustment, before the warp factor.
        public var pacedFrameRate: Double
        /// The frame rate the host is asked to render (``pacedFrameRate`` times the warp factor).
        public var streamFrameRate: Double
        public var vrr: Bool
        /// The frame rate the display link asks for (Android's `Surface.setFrameRate`): normally ``surfaceFrameRate(desiredRefreshRate:fps:pacing:reduceRefreshRate:)``,
        /// the true stream frame rate with VRR.
        public var surfaceFrameRate: Double
        /// The stream asks for HDR: Apple TV's display criteria ask for its dynamic range with the frame rate. Not a planner
        /// decision; the renderer fills it from its options.
        public var hdr = false

        /// The display link's request: exactly ``surfaceFrameRate``.
        public var frameRateRange: CAFrameRateRange {
            let rate = Float(surfaceFrameRate)
            return CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        }
    }

    public static func warpFactor(_ pacing: FramePacing) -> Int {
        switch pacing {
        case .warp: 2
        case .warp2: 4
        default: 0
        }
    }

    public static func plan(_ input: Input) -> Plan {
        let current = input.display.currentMode
        let bestMode = chooseMode(input)

        let modeSwitch: ModeSwitch
        if current.id != bestMode.id {
            // A mode of another size needs a real switch; one that only differs in refresh rate is left to the frame
            // rate request unless the mode is enforced
            modeSwitch = input.enforceDisplayMode || current.width != bestMode.width || current.height != bestMode.height
                ? .preferredMode : .setFrameRate
        } else {
            modeSwitch = .none
        }

        let desiredRefreshRate = bestMode.refreshRate
        let displayRefreshRate: Double
        if input.vrr {
            // The display adapts its rate to the content: plan for the best it can do at this resolution
            displayRefreshRate = peakRefreshRate(input.display.supportedModes, bestMode)
        } else if input.display.television || input.display.externalDisplay {
            // TVs take a moment to switch, and an external display's current rate cannot be compared
            displayRefreshRate = desiredRefreshRate
        } else if modeSwitch != .none, input.display.currentRefreshRate >= current.refreshRate - rateTolerance,
                  desiredRefreshRate <= input.refreshRateCeiling + rateTolerance {
            displayRefreshRate = desiredRefreshRate
        } else {
            // The lower of the current and the selected rate: the request may not be granted (Low Power Mode)
            displayRefreshRate = min(input.display.currentRefreshRate, desiredRefreshRate)
        }

        let roundedRefreshRate = Int(displayRefreshRate.rounded())
        var chosenFrameRate = input.fps
        var pacing = input.pacing
        var pacingChange = PacingChange.none
        if pacing == .capFPS, input.fps >= Double(roundedRefreshRate) {
            if input.fps > Double(roundedRefreshRate + 3) {
                pacing = .balanced
                pacingChange = .dropFramesAboveRefreshRate
            } else if roundedRefreshRate <= 49 {
                pacing = .balanced
                pacingChange = .bogusRefreshRate
            } else {
                chosenFrameRate = Double(roundedRefreshRate - 1)
                pacingChange = .cappedBelowRefreshRate
            }
        }
        let pacedFrameRate = chosenFrameRate
        let warp = warpFactor(input.pacing)
        if warp > 0 { chosenFrameRate *= Double(warp) }
        let surface = input.vrr
            ? pacedFrameRate
            : surfaceFrameRate(desiredRefreshRate: desiredRefreshRate, fps: input.fps, pacing: pacing, reduceRefreshRate: input.reduceRefreshRate)
        return Plan(
            currentMode: current, bestMode: bestMode, modeSwitch: modeSwitch, desiredRefreshRate: desiredRefreshRate,
            displayRefreshRate: displayRefreshRate, pacing: pacing, pacingChange: pacingChange, roundedRefreshRate: roundedRefreshRate,
            pacedFrameRate: pacedFrameRate, streamFrameRate: chosenFrameRate, vrr: input.vrr, surfaceFrameRate: surface)
    }

    private static func chooseMode(_ input: Input) -> DisplayMode {
        let current = input.display.currentMode
        var bestMode = current
        let fps = input.fps
        let mayReduce = mayReduceRefreshRate(input.pacing, reduceRefreshRate: input.reduceRefreshRate)
        var refreshRateIsGood = isRefreshRateGoodMatch(bestMode.refreshRate, fps: fps)
        var refreshRateIsEqual = isRefreshRateEqualMatch(bestMode.refreshRate, fps: fps)

        for candidate in input.display.supportedModes {
            let refreshRateReduced = candidate.refreshRate < bestMode.refreshRate
            let resolutionReduced = candidate.width < bestMode.width || candidate.height < bestMode.height
            let resolutionFitsStream = candidate.width >= input.streamWidth && candidate.height >= input.streamHeight
            // Avoid resolutions above 4K to be safe
            if candidate.width > 4096, input.streamWidth <= 4096 { continue }
            // Non-4K streams keep the resolution unless above 60 FPS (HDMI bandwidth) or a native-resolution stream
            if input.streamWidth < 3840, fps <= 60, !isNativeResolution(width: input.streamWidth, height: input.streamHeight),
               current.width != candidate.width || current.height != candidate.height {
                continue
            }
            // The resolution only regresses above 60 FPS, where it may be needed for the refresh rate
            if resolutionReduced, !(fps > 60 && resolutionFitsStream) { continue }
            if mayReduce, refreshRateIsEqual, !isRefreshRateEqualMatch(candidate.refreshRate, fps: fps) {
                continue
            } else if refreshRateIsGood {
                if !isRefreshRateGoodMatch(candidate.refreshRate, fps: fps) { continue }
                if mayReduce {
                    // The lowest possible refresh rate: never raise a good match
                    if candidate.refreshRate > bestMode.refreshRate { continue }
                } else if refreshRateReduced {
                    // The highest possible refresh rate: never reduce a good match
                    continue
                }
            } else if !isRefreshRateGoodMatch(candidate.refreshRate, fps: fps) {
                if refreshRateReduced { continue }
            }
            // Otherwise a good match where there was none: preferred even when it lowers the rate (60 Hz for 60 FPS on a
            // 90 Hz panel)
            bestMode = candidate
            refreshRateIsGood = isRefreshRateGoodMatch(candidate.refreshRate, fps: fps)
            refreshRateIsEqual = isRefreshRateEqualMatch(candidate.refreshRate, fps: fps)
        }
        return bestMode
    }

    /// The refresh rate is the stream FPS or up to 3 Hz above it.
    static func isRefreshRateEqualMatch(_ refreshRate: Double, fps: Double) -> Bool {
        reachesFPS(refreshRate, fps: fps) && refreshRate <= fps + 3
    }

    /// The refresh rate is at least the stream FPS and (rounded) a multiple of it, within 3 Hz (Java's float `%`).
    static func isRefreshRateGoodMatch(_ refreshRate: Double, fps: Double) -> Bool {
        reachesFPS(refreshRate, fps: fps) && Double(Int((Float(refreshRate)).rounded())).truncatingRemainder(dividingBy: fps) <= 3
    }

    /// The refresh rate is at least the stream FPS; NTSC rates (1000/1001) count as the integer FPS they stand for.
    static func reachesFPS(_ refreshRate: Double, fps: Double) -> Bool {
        refreshRate + rateTolerance >= fps * (1000.0 / 1001.0)
    }

    /// Android `PreferenceConfiguration.isNativeResolution`: any size that is not one of the six preset resolutions.
    public static func isNativeResolution(width: Int, height: Int) -> Bool {
        let presets = [(640, 360), (854, 480), (1280, 720), (1920, 1080), (2560, 1440), (3840, 2160)]
        return !presets.contains { $0 == (width, height) }
    }

    /// The pacing prefers the lowest matching refresh rate over the highest.
    public static func mayReduceRefreshRate(_ pacing: FramePacing, reduceRefreshRate: Bool) -> Bool {
        pacing == .capFPS || pacing == .smoothness || (pacing == .balanced && reduceRefreshRate)
    }

    /// The highest refresh rate among `modes` at the size of `mode` (at least the mode's own).
    public static func peakRefreshRate(_ modes: [DisplayMode], _ mode: DisplayMode) -> Double {
        modes.filter { $0.width == mode.width && $0.height == mode.height }.map(\.refreshRate).reduce(mode.refreshRate, max)
    }

    /// The frame rate the display link asks for: the true FPS when the refresh rate may be reduced or no refresh rate
    /// reaches it, else the chosen refresh rate (the highest the frame rate divides, the lowest display latency).
    public static func surfaceFrameRate(desiredRefreshRate: Double, fps: Double, pacing: FramePacing, reduceRefreshRate: Bool) -> Double {
        mayReduceRefreshRate(pacing, reduceRefreshRate: reduceRefreshRate) || !reachesFPS(desiredRefreshRate, fps: fps)
            ? fps : desiredRefreshRate
    }
}
