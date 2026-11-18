import Foundation

/// Which ``VideoRenderer`` a stream uses. The display layer is the default; the Metal renderer is chosen by the debug
/// switch, a launch argument (or a `defaults` value) `DelosRenderer`:
///
///     xcrun devicectl device process launch --device <id> --console io.github.meitoncz.delos.debug -DelosRenderer metal
///
/// `-DelosRenderer layer` names the default. Release builds ignore the switch. There is no setting for it: Android's
/// "Fast V-Sync" row says it works with MediaCodec only, and the choice stays a debug one until a stream on the iPad
/// shows the Metal renderer is steadier (issues #9 and #12).
public enum RendererChoice: String, Sendable, CaseIterable {
    case layer
    case metal

    /// The user defaults key of the debug switch (`-DelosRenderer` on the command line).
    public static let defaultsKey = "DelosRenderer"

    /// The choice named by a debug switch value; nil for no or an unknown value.
    public init?(switchValue: String?) {
        guard let switchValue, let choice = Self(rawValue: switchValue.lowercased()) else { return nil }
        self = choice
    }

    /// The renderer of this run: the debug switch in debug builds, else Metal (owner's decision, 2026-11-17: effects on the
    /// live picture, frame pacing with the display link, the way to PyroWave); ``makeRenderer`` falls back to the display layer.
    public static var current: RendererChoice {
        #if DEBUG
        RendererChoice(switchValue: UserDefaults.standard.string(forKey: defaultsKey)) ?? .metal
        #else
        .metal
        #endif
    }

    /// A renderer of this choice. The Metal renderer falls back to the display layer where Metal is not available.
    @MainActor
    public func makeRenderer(pacing: FramePacing, fps: Int, options: VideoRenderOptions = VideoRenderOptions()) -> any VideoRenderer {
        if self == .metal, let metal = MetalRenderer(pacing: pacing, fps: fps, options: options) { return metal }
        return DisplayLayerRenderer(pacing: pacing, fps: fps, options: options)
    }
}
