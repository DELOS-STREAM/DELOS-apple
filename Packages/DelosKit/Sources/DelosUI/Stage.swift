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

    public init(size: CGSize, safeArea: EdgeInsets = EdgeInsets()) {
        guard size.width > 0, size.height > 0 else {
            self.init(scale: 1, width: Self.designWidth, height: Self.designHeight, safe: EdgeInsets())
            return
        }
        let unit = max(min(size.width / Self.designWidth, size.height / Self.designHeight), Self.minPointsPerPixel)
        self.init(
            scale: unit,
            width: Self.snap(size.width / unit, Self.designWidth),
            height: Self.snap(size.height / unit, Self.designHeight),
            safe: EdgeInsets(top: safeArea.top / unit, leading: safeArea.leading / unit,
                             bottom: safeArea.bottom / unit, trailing: safeArea.trailing / unit)
        )
    }

    private init(scale: Double, width: Double, height: Double, safe: EdgeInsets) {
        self.scale = scale
        self.width = width
        self.height = height
        self.shape = Self.classify(width: width, height: height)
        self.safe = safe
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

    /// A size in stage pixels, in points.
    public func px(_ value: Double) -> CGFloat { CGFloat(value * scale) }
}

extension EnvironmentValues {
    @Entry public var stage = Stage(size: CGSize(width: Stage.designWidth, height: Stage.designHeight))
}

/// Measures the whole window and its safe area and provides the matching ``Stage`` to its content, which fills the
/// window (edge-anchored content keeps clear of ``Stage/safe`` itself, as on Android).
public struct StageReader<Content: View>: View {
    private let content: Content
    @State private var safeArea = EdgeInsets()

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ZStack {
            // Measures the safe area: this layer respects it, the content below ignores it
            Color.clear
                .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { safeArea = $0 }
            GeometryReader { proxy in
                content
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .environment(\.stage, Stage(size: proxy.size, safeArea: safeArea))
            }
            .ignoresSafeArea()
        }
    }
}
