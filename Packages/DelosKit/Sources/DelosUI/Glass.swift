import SwiftUI

/// What a glass surface is for. Each role has one look, so the same kind of element looks the same everywhere
/// (the conventions are in docs/ARCHITECTURE.md, "Glass").
enum GlassRole {
    /// Something to press or to focus: circles, chips, secondary pills, the back button, text fields. Regular glass
    /// that reacts to touch (`interactive`), tinted with the surface token.
    case control
    /// The app's own bars: the top navigation. Clear glass, the most transparent and refractive kind, with almost no
    /// tint, so the background shows strongly through it (owner's choice: very transparent, a strong effect).
    case chrome
    /// Something to read: cards, panels, toasts, the PIN digits. Regular glass, not interactive, a little more tint
    /// so text on it keeps its contrast.
    case panel
}

extension EnvironmentValues {
    /// True over the stream's video: glass there is clear (the picture shows through) with a darker tint for contrast.
    @Entry var glassOverMedia = false
    /// Interface motion is reduced: the profile's Animations setting (Settings → Appearance) or the system's Reduce
    /// Motion (``DelosRoot`` sets it; `LocalReducedMotion` of DELOS for Android). The animated background keeps its
    /// pace, as on Android, and slows down only for the system setting.
    @Entry var reducedMotion = false
}

/// A surface of Liquid Glass where DELOS for Android blurs the background (`Modifier.glass`); iOS, iPadOS and tvOS 26
/// and later. Before 26 the tint token is a plain fill, as Android's look without blur.
///
/// Not glass: primary buttons (solid main color, as on Android), focus rings, progress bars, cover art.
struct GlassShape<S: Shape>: View {
    let shape: S
    let tint: RGBA
    let role: GlassRole
    @Environment(\.glassOverMedia) private var overMedia
    @Environment(\.delosColors) private var colors

    init(_ shape: S, tint: RGBA, role: GlassRole = .control) {
        self.shape = shape
        self.tint = tint
        self.role = role
    }

    var body: some View {
        if #available(iOS 26, tvOS 26, macOS 26, *) {
            Color.clear.glassEffect(glass, in: shape)
        } else {
            shape.fill(tint.color)
        }
    }

    @available(iOS 26, tvOS 26, macOS 26, *)
    private var glass: Glass {
        // The token's alpha is meant for a flat fill; glass has its own body, so it gets a lighter share of it
        let share: Double
        let base: Glass
        if overMedia {
            base = .clear
            share = 0.85
        } else if role == .chrome {
            base = .clear
            share = 0.12
        } else {
            base = .regular
            share = role == .panel ? 0.6 : 0.45
        }
        let tinted = base.tint((overMedia ? colors.scrim : tint).opacity(tint.alpha * share).color)
        #if os(iOS)
        return role == .panel ? tinted : tinted.interactive()
        #else
        return tinted
        #endif
    }
}
