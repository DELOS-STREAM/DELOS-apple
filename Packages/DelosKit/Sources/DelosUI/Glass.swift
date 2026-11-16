import SwiftUI

/// A surface of frosted glass: where DELOS for Android blurs the background behind a panel, a pill or a circle
/// (`Modifier.glass`), the Apple app uses Liquid Glass (iOS, iPadOS and tvOS 26 and later), tinted with the surface
/// token. Before 26 it falls back to the token as a plain fill, as before.
struct GlassShape<S: Shape>: View {
    let shape: S
    let tint: RGBA

    init(_ shape: S, tint: RGBA) {
        self.shape = shape
        self.tint = tint
    }

    var body: some View {
        if #available(iOS 26, tvOS 26, macOS 26, *) {
            // The token's alpha is for a flat fill; glass carries its own body, so the tint is lighter
            Color.clear.glassEffect(.regular.tint(tint.opacity(tint.alpha * 0.45).color), in: shape)
        } else {
            shape.fill(tint.color)
        }
    }
}
