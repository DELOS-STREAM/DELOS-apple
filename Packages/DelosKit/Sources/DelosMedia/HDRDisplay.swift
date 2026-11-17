import AVFoundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Whether the display this device streams to shows HDR (`Display.getHdrCapabilities` of DELOS for Android).
public enum HDRDisplay {
    /// A display whose brightness can go above the standard white shows HDR: its potential extended-range headroom is
    /// above 1. `hdrModes`: the system lists an HDR mode (HDR10, HLG, Dolby Vision) for the display (the Apple TV's
    /// HDMI link, or an iPhone or iPad whose screen is HDR).
    public static func supports(potentialHeadroom: Double?, hdrModes: Bool) -> Bool {
        hdrModes || (potentialHeadroom ?? 1) > 1
    }

    /// The main display.
    @MainActor public static var isSupported: Bool {
        #if os(iOS)
        return supports(
            potentialHeadroom: Double(UIScreen.main.potentialEDRHeadroom), hdrModes: !AVPlayer.availableHDRModes.isEmpty)
        #elseif os(macOS)
        return supports(
            potentialHeadroom: NSScreen.main.map { Double($0.maximumPotentialExtendedDynamicRangeColorComponentValue) },
            hdrModes: false)
        #else
        return supports(potentialHeadroom: nil, hdrModes: !AVPlayer.availableHDRModes.isEmpty)
        #endif
    }
}
