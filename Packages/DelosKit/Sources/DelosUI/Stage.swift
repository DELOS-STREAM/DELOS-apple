import SwiftUI

/// How the window's shape relates to the 16:9 the specification is drawn for (`StageShape` in DELOS for Android).
public enum StageShape: Sendable {
    /// Wider than 16:9 (iPhone in landscape).
    case wide
    /// 16:9 within ``Stage/standardTolerance``.
    case standard
    /// Narrower than 16:9, down to 4:3 (iPad).
    case tall
    /// Too few stage pixels across for the standard layout, or squarish.
    case compact
}

/// The design canvas. Every size of the specification (DELOS for Android) is given in pixels of a 1920 × 1080 stage;
/// ``px(_:)`` turns such a size into points. The port of `StagePlanner` in DELOS for Android:
///
/// - The stage grows with the window: `scale = min(w / 1920, h / 1080)` fits 1920 × 1080 inside it, and the other axis
///   holds more stage pixels (4:3 is 1920 × 1440).
/// - **Legibility floor**: one stage pixel is never smaller than ``minPointsPerPixel`` (0.43). The reference is the AYN Odin
///   2 Portal, where DELOS was designed: one stage pixel is 0.4336 dp there. On a window small in points (an iPhone in
///   landscape, 932 × 430) the scale stays at the floor and the stage gets fewer pixels (2167 × 1000) instead of smaller
///   text. Points and Android's dp are both about 1/160 inch, so the floor carries over unchanged.
public struct Stage: Equatable, Sendable {
    public static let designWidth = 1920.0
    public static let designHeight = 1080.0
    public static let minPointsPerPixel = 0.43
    /// A stage narrower than this (stage pixels) is ``StageShape/compact``.
    public static let compactWidth = 1500.0
    /// Relative tolerance around 16:9 that still counts as standard.
    public static let standardTolerance = 0.03
    /// The narrow end of ``StageShape/tall``: 4:3.
    public static let tallLimit = 4.0 / 3.0

    /// Points per stage pixel.
    public let scale: Double
    /// The stage's size in stage pixels.
    public let width: Double
    public let height: Double
    public let shape: StageShape
    /// The safe area (notch, Dynamic Island, home indicator, TV overscan) in stage pixels on each edge.
    public let safe: EdgeInsets
    /// The interface scale (Settings → Appearance, 1.0 to 1.3) that text and icons are drawn at (``tpx(_:)``): Android's
    /// `StageMetrics.textScale`. Inside a ``ZoomedBar`` it is 1, because the whole bar is zoomed instead.
    public let textScale: Double
    /// The smallest text or icon size in points ``tpx(_:)`` gives (0: none). On Apple TV text under 24 points is hard to
    /// read from the sofa (Apple's tvOS guidelines name 23 as the smallest size), so the caption sizes of the 1920 × 1080
    /// design, which was made for a handheld, are raised to it.
    public let minimumText: Double

    /// The smallest text size on this platform: ``tvMinimumText`` on tvOS, none elsewhere.
    public static let platformMinimumText: Double = {
        #if os(tvOS)
        tvMinimumText
        #else
        0
        #endif
    }()
    public static let tvMinimumText = 24.0

    /// The title-safe area of Apple TV in points (60 above and below, 90 at the sides), which content keeps within: the
    /// system's safe area there is 60 and 80 and falls short of it.
    public static let tvTitleSafeArea = EdgeInsets(top: 60, leading: 90, bottom: 60, trailing: 90)
    public static let platformMinimumSafeArea: EdgeInsets = {
        #if os(tvOS)
        tvTitleSafeArea
        #else
        EdgeInsets()
        #endif
    }()

    /// The system's safe area, at least [minimum] on each edge.
    public static func safeArea(system: EdgeInsets, minimum: EdgeInsets) -> EdgeInsets {
        EdgeInsets(top: max(system.top, minimum.top), leading: max(system.leading, minimum.leading),
                   bottom: max(system.bottom, minimum.bottom), trailing: max(system.trailing, minimum.trailing))
    }

    /// - Parameters:
    ///   - textScale: the interface scale, `Appearance.uiScale / 100`.
    ///   - minimumText: the smallest text size in points, see ``minimumText``.
    public init(size: CGSize, safeArea: EdgeInsets = EdgeInsets(), textScale: Double = 1, minimumText: Double = Stage.platformMinimumText) {
        guard size.width > 0, size.height > 0 else {
            self.init(scale: 1, width: Self.designWidth, height: Self.designHeight, safe: EdgeInsets(), textScale: textScale, minimumText: minimumText)
            return
        }
        let unit = max(min(size.width / Self.designWidth, size.height / Self.designHeight), Self.minPointsPerPixel)
        self.init(
            scale: unit,
            width: Self.snap(size.width / unit, Self.designWidth),
            height: Self.snap(size.height / unit, Self.designHeight),
            safe: EdgeInsets(top: safeArea.top / unit, leading: safeArea.leading / unit,
                             bottom: safeArea.bottom / unit, trailing: safeArea.trailing / unit),
            textScale: textScale, minimumText: minimumText
        )
    }

    private init(scale: Double, width: Double, height: Double, shape: StageShape? = nil, safe: EdgeInsets, textScale: Double, minimumText: Double) {
        self.scale = scale
        self.width = width
        self.height = height
        self.shape = shape ?? Self.classify(width: width, height: height)
        self.safe = safe
        self.textScale = textScale
        self.minimumText = minimumText
    }

    /// The limiting axis is exactly 1920 or 1080, not w / (w / 1920) with its rounding error.
    private static func snap(_ value: Double, _ target: Double) -> Double { abs(value - target) < 0.01 ? target : value }

    public static func classify(width: Double, height: Double) -> StageShape {
        let aspect = width / height
        let standard = 16.0 / 9.0
        if width < compactWidth { return .compact }
        if abs(aspect - standard) <= standard * standardTolerance { return .standard }
        if aspect > standard { return .wide }
        if aspect >= tallLimit * (1 - standardTolerance) { return .tall }
        return .compact
    }

    public var compact: Bool { shape == .compact }

    /// The lowest ``compactScale`` (`Compact.MIN_SCALE` of DELOS for Android).
    public static let minCompactScale = 0.62

    /// The one scale of the non-text elements on a compact stage (covers, discs, avatars, gaps): the stage's height against
    /// the 1080 of the design, never under ``minCompactScale``; exactly 1 on every other shape. Text keeps its size.
    public var compactScale: Double {
        compact ? min(max(height / Self.designHeight, Self.minCompactScale), 1) : 1
    }

    /// A size in stage pixels, in points.
    public func px(_ value: Double) -> CGFloat { CGFloat(value * scale) }

    /// A text or icon size in stage pixels, in points, at the interface scale (Android's `tpx`).
    public func tpx(_ value: Double) -> CGFloat { CGFloat(max(value * scale * textScale, minimumText)) }

    /// The stage of a bar zoomed as a whole by [uiScale] (Android's `ZoomedBar`, the prototype's CSS zoom): a stage pixel
    /// is [uiScale] times larger, so the bar has as many stage pixels across as the zoomed bar really has room for; text
    /// inside keeps its size relative to the bar (``textScale`` 1). The layout family stays the window's.
    public func zoomed(by uiScale: Double) -> Stage {
        Stage(
            scale: scale * uiScale, width: width / uiScale, height: height / uiScale, shape: shape,
            safe: EdgeInsets(top: safe.top / uiScale, leading: safe.leading / uiScale,
                             bottom: safe.bottom / uiScale, trailing: safe.trailing / uiScale),
            textScale: 1, minimumText: minimumText)
    }
}

extension EnvironmentValues {
    @Entry public var stage = Stage(size: CGSize(width: Stage.designWidth, height: Stage.designHeight))
}

/// Measures the whole window and its safe area and provides the matching ``Stage`` to its content, which fills the
/// window (edge-anchored content keeps clear of ``Stage/safe`` itself, as on Android).
public struct StageReader<Content: View>: View {
    private let content: Content
    private let textScale: Double
    @State private var safeArea = EdgeInsets()

    /// - Parameter textScale: the interface scale, `Appearance.uiScale / 100`.
    public init(textScale: Double = 1, @ViewBuilder content: () -> Content) {
        self.textScale = textScale
        self.content = content()
    }

    /// Debug builds: `-DelosStage <width>x<height>` lays the interface out in a window of that size in points, centered in
    /// the real one, to look at a compact or tall stage on a screen that has none (without the real screen's safe area).
    private static func debugSize(in size: CGSize) -> CGSize {
        #if DEBUG
        if let text = UserDefaults.standard.string(forKey: "DelosStage") {
            let parts = text.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, parts[0] > 0, parts[1] > 0 { return CGSize(width: min(parts[0], size.width), height: min(parts[1], size.height)) }
        }
        #endif
        return size
    }

    public var body: some View {
        ZStack {
            // Measures the safe area: this layer respects it, the content below ignores it
            Color.clear
                .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { safeArea = $0 }
            GeometryReader { proxy in
                let size = Self.debugSize(in: proxy.size)
                content
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    // A debug window (`-DelosStage`) is not at the screen's edges: the real cutout is not its safe area
                    .environment(\.stage, Stage(
                        size: size, safeArea: size == proxy.size ? Stage.safeArea(system: safeArea, minimum: Stage.platformMinimumSafeArea) : EdgeInsets(),
                        textScale: textScale))
            }
            .ignoresSafeArea()
        }
    }
}

/// The status bar and the hint bars are zoomed as a whole by the interface scale (Android's `ZoomedBar`): the content
/// gets ``Stage/zoomed(by:)`` of the stage's ``Stage/textScale``. Applied twice it changes nothing more.
struct ZoomedBar: ViewModifier {
    @Environment(\.stage) private var stage

    func body(content: Content) -> some View {
        content.environment(\.stage, stage.zoomed(by: stage.textScale))
    }
}
