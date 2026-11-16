import SwiftUI

/// Procedural art for a game without artwork (`PlaceholderArt` of DELOS for Android, the prototype's `.art`): a dark
/// diagonal gradient of its two hues with two glows, its icon large and faint at the top right, and optionally its
/// title at the bottom left. Used as a cover and as the game background.
struct PlaceholderArt: View {
    let hue: Double
    let hue2: Double
    let icon: String
    /// The icon's size, its distance from the right edge (negative: overflowing) in stage pixels, and its top as a
    /// fraction of the height.
    var glyphSize = 320.0
    var glyphRight = -36.0
    var glyphTop = 0.24
    var glyphAlpha = 0.16
    var title: String?
    var titleSize = 34.0
    var titleInset = 26.0
    var titleBottom = 26.0
    @Environment(\.stage) private var stage

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                // linear-gradient(165deg, hsl(hue 58% 24%), hsl(hue2 50% 10%))
                Rectangle().fill(Self.cssLinear(165, size: size, [hsl(hue, 58, 24).color, hsl(hue2, 50, 10).color]))
                Rectangle().fill(Self.cssRadial(UnitPoint(x: 0.18, y: 0.92), size: size,
                                                [.init(color: hsl(hue, 85, 48, 0.9).color, location: 0), .init(color: hsl(hue, 85, 48, 0).color, location: 0.58)]))
                Rectangle().fill(Self.cssRadial(UnitPoint(x: 0.74, y: 0.22), size: size,
                                                [.init(color: hsl(hue2, 90, 66, 0.95).color, location: 0), .init(color: hsl(hue2, 90, 66, 0).color, location: 0.42)]))
                SymbolView(symbol: icon, size: glyphSize, color: RGBA(red: 1, green: 1, blue: 1, alpha: glyphAlpha), filled: true)
                    .fixedSize()
                    .frame(width: size.width, alignment: .trailing)
                    .offset(x: -stage.px(glyphRight), y: size.height * glyphTop)
                if let title {
                    Text(title)
                        .font(DelosFonts.unbounded(stage.tpx(titleSize)))
                        .foregroundStyle(.white)
                        .lineSpacing(0)
                        .shadow(color: .black.opacity(0.45), radius: stage.px(12), y: stage.px(4))
                        .padding(.horizontal, stage.px(titleInset))
                        .padding(.bottom, stage.px(titleBottom))
                        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
                }
            }
        }
        .clipped()
    }

    /// CSS linear-gradient(angle, …) over a box of [size].
    static func cssLinear(_ degrees: Double, size: CGSize, _ colors: [Color]) -> LinearGradient {
        let a = degrees * .pi / 180
        let dx = sin(a), dy = -cos(a)
        let half = (abs(size.width * dx) + abs(size.height * dy)) / 2
        func unit(_ sign: Double) -> UnitPoint {
            UnitPoint(x: size.width > 0 ? (size.width / 2 + sign * dx * half) / size.width : 0.5,
                      y: size.height > 0 ? (size.height / 2 + sign * dy * half) / size.height : 0.5)
        }
        return LinearGradient(colors: colors, startPoint: unit(-1), endPoint: unit(1))
    }

    /// CSS radial-gradient(circle at x y, …): the ray reaches the farthest corner.
    static func cssRadial(_ center: UnitPoint, size: CGSize, _ stops: [Gradient.Stop]) -> RadialGradient {
        let cx = center.x * size.width, cy = center.y * size.height
        let r = max(hypot(cx, cy), hypot(size.width - cx, cy), hypot(cx, size.height - cy), hypot(size.width - cx, size.height - cy))
        return RadialGradient(stops: stops, center: center, startRadius: 0, endRadius: max(r, 1))
    }
}
