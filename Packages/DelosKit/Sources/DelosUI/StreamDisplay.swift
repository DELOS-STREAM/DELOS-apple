import CoreMedia
import DelosMedia
import Foundation

/// The display a stream is shown on, read for the refresh rate plan (``DisplayRefreshPlanner``), and the plan's mode switch
/// where the platform has one: the Mac's display modes (Android's `preferredDisplayModeId`), and Apple TV's display criteria,
/// which let the TV switch to the stream's frame rate and dynamic range when its owner turned on matching (Android TV
/// switches modes itself). iPhone and iPad have no modes: their panel follows the display link's frame rate.
@MainActor
enum StreamDisplay {
    /// Low Power Mode or a hot device: ProMotion runs at most 60 Hz (Android: battery saver and thermal throttling).
    static var limited: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }
}

#if canImport(UIKit)
import UIKit
#if os(tvOS)
import AVKit
#endif

extension StreamDisplay {
    /// A screen in landscape: its sizes and the rates its display link can run.
    static func describe(_ screen: UIScreen, external: Bool) -> VideoDisplay {
        let size = screen.nativeBounds.size
        #if os(tvOS)
        let television = true
        #else
        let television = false
        #endif
        return .builtIn(
            width: Int(max(size.width, size.height)), height: Int(min(size.width, size.height)),
            maxFramesPerSecond: screen.maximumFramesPerSecond, television: television, externalDisplay: external, limited: limited)
    }

    #if os(tvOS)
    /// Asks the TV for the stream's frame rate and dynamic range; tvOS switches the TV's mode when "Match Content" is on.
    static func applyCriteria(_ plan: DisplayRefreshPlanner.Plan, width: Int, height: Int, to window: UIWindow) {
        var format: CMVideoFormatDescription?
        let extensions: [CFString: Any]? = plan.hdr ? [
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
        ] : nil
        CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: plan.hdr ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, width: Int32(width),
            height: Int32(height), extensions: extensions as CFDictionary?, formatDescriptionOut: &format)
        guard let format else { return }
        window.avDisplayManager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: Float(plan.pacedFrameRate), formatDescription: format)
    }

    static func resetCriteria(of window: UIWindow) {
        window.avDisplayManager.preferredDisplayCriteria = nil
    }
    #endif
}
#endif

#if os(macOS)
import AppKit

extension StreamDisplay {
    /// The modes of the screen's own pixel size at each refresh rate it offers (the panel's physical modes, not the scaled
    /// "looks like" sizes), and whether it reports adaptive sync (a refresh interval range).
    static func describe(_ screen: NSScreen) -> VideoDisplay {
        let fastest = Double(screen.maximumFramesPerSecond)
        let backing = screen.convertRectToBacking(screen.frame).size
        let fallback = DisplayMode(id: 0, width: Int(backing.width), height: Int(backing.height), refreshRate: fastest)
        let vrr = screen.maximumRefreshInterval > screen.minimumRefreshInterval + 1e-6
        let ceiling = limited ? fastest : .infinity
        guard let id = displayID(screen), let current = CGDisplayCopyDisplayMode(id) else {
            return VideoDisplay(
                currentMode: fallback, supportedModes: [fallback], currentRefreshRate: fastest, reportsVariableRefreshRate: vrr,
                refreshRateCeiling: ceiling)
        }
        func mode(_ m: CGDisplayMode) -> DisplayMode {
            DisplayMode(id: Int(m.ioDisplayModeID), width: m.pixelWidth, height: m.pixelHeight, refreshRate: m.refreshRate > 0 ? m.refreshRate : fastest)
        }
        let all = (CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode]) ?? []
        let currentMode = mode(current)
        let modes = all.map(mode).filter { $0.width == currentMode.width && $0.height == currentMode.height }
        return VideoDisplay(
            currentMode: currentMode, supportedModes: modes.isEmpty ? [currentMode] : modes,
            currentRefreshRate: min(currentMode.refreshRate, fastest), externalDisplay: CGDisplayIsBuiltin(id) == 0,
            reportsVariableRefreshRate: vrr, refreshRateCeiling: ceiling)
    }

    /// Whether this app switched a display's mode (to give it back).
    private static var switched = false

    /// Switches the screen to the plan's mode when the plan asks for a mode switch; for this app only, so the system gives
    /// the mode back when the app quits, and ``restoreMode()`` gives it back when the stream ends.
    static func applyMode(_ plan: DisplayRefreshPlanner.Plan, on screen: NSScreen) {
        guard plan.modeSwitch == .preferredMode, let id = displayID(screen),
              let target = ((CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode]) ?? []).first(where: {
                  Int($0.ioDisplayModeID) == plan.bestMode.id
              })
        else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayWithDisplayMode(config, id, target, nil)
        switched = CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }

    static func restoreMode() {
        guard switched else { return }
        switched = false
        CGRestorePermanentDisplayConfiguration()
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
#endif
