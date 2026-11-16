import SwiftUI

/// The design canvas. Every size of the specification (docs/prototype in DELOS for Android) is given in pixels of a
/// 1920 × 1080 stage; ``px(_:)`` turns such a size into points of the real screen. The stage keeps its proportions:
/// it is scaled by the axis that has less room, and the other axis gets the extra space (a wider or taller stage).
public struct Stage: Equatable, Sendable {
    public static let designWidth = 1920.0
    public static let designHeight = 1080.0

    /// Points per stage pixel.
    public let scale: Double
    /// The stage's size in stage pixels; one side is the design size, the other one at least as large.
    public let width: Double
    public let height: Double

    public init(size: CGSize) {
        let sx = size.width / Self.designWidth
        let sy = size.height / Self.designHeight
        let unit = max(min(sx, sy), 0.0001)
        scale = unit
        width = size.width / unit
        height = size.height / unit
    }

    /// A size in stage pixels, in points.
    public func px(_ value: Double) -> CGFloat { CGFloat(value * scale) }
}

extension EnvironmentValues {
    @Entry public var stage = Stage(size: CGSize(width: Stage.designWidth, height: Stage.designHeight))
}

/// Measures the space it gets and provides the matching ``Stage`` to its content.
public struct StageReader<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        GeometryReader { proxy in
            content
                .environment(\.stage, Stage(size: proxy.size))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
