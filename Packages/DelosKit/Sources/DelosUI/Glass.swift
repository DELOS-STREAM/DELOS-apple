import SwiftUI

/// What a glass surface is for. Each role has one look, so the same kind of element looks the same everywhere
/// (the conventions are in docs/ARCHITECTURE.md, "Glass").
enum GlassRole {
    /// Something to press or to focus: circles, chips, secondary pills, the back button, text fields. Regular glass
    /// that reacts to touch (`interactive`), tinted with the surface token.
    case control
    /// The app's own bars: the top navigation. Regular glass with almost no tint: see-through with a strong refraction,
    /// and it adapts to the background behind it (clear glass would not, and its icons vanished over a bright hero).
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
    /// The surfaces here lie over a backdrop that is blurred already (the game overview's page): the tint alone, no Liquid
    /// Glass. One glass pass per pill, chip and card over a playing game background cost the page its smoothness, and over
    /// a blurred backdrop the glass shows nothing the tint does not.
    @Entry var glassFlat = false
}

/// A surface of Liquid Glass where DELOS for Android blurs the background (`Modifier.glass`); iOS, iPadOS and tvOS 26
/// and later. Before 26 the tint token is a plain fill, as Android's look without blur.
///
/// Not glass: primary buttons (solid main color, as on Android), focus rings, progress bars, cover art.
struct GlassShape<S: Shape>: View {
    let shape: S
    let tint: RGBA
    let role: GlassRole
    /// The share of the tint token's alpha the glass gets; nil: the role's. 1 keeps Android's fill color (the token's own
    /// alpha) on the glass, for the surfaces whose color the Android screenshots fix (the circles, the profile chip).
    let share: Double?
    @Environment(\.glassOverMedia) private var overMedia
    @Environment(\.glassFlat) private var flat
    @Environment(\.delosColors) private var colors

    init(_ shape: S, tint: RGBA, role: GlassRole = .control, share: Double? = nil) {
        self.shape = shape
        self.share = share
        self.tint = tint
        self.role = role
    }

    var body: some View {
        ZStack {
            if #available(iOS 26, tvOS 26, macOS 26, *), !flat {
                Color.clear.glassEffect(glass, in: shape)
            } else {
                shape.fill(tint.color)
            }
        }
    }

    @available(iOS 26, tvOS 26, macOS 26, *)
    private var glass: Glass {
        // The token's alpha is meant for a flat fill; glass has its own body, so it gets a lighter share of it
        var share: Double
        let base: Glass
        if overMedia {
            base = .clear
            share = 0.85
        } else if role == .chrome {
            // Regular glass adapts its shade to what is behind it (clear glass does not), so the icons stay legible
            // over a bright game background; the tint is almost nothing, so it stays see-through
            base = .regular
            share = 0.1
        } else {
            base = .regular
            share = role == .panel ? 0.6 : 0.45
        }
        if let override = self.share, !overMedia { share = override }
        let tinted = base.tint((overMedia ? colors.scrim : tint).opacity(tint.alpha * share).color)
        #if os(iOS)
        return role == .panel ? tinted : tinted.interactive()
        #else
        return tinted
        #endif
    }
}

extension RGBA {
    /// The dark navy of the glass pills and bands over cover art and over the hero (Android's `Color(0x..050A14)`), at [alpha].
    static func overArt(_ alpha: Double) -> RGBA { RGBA(red: 5 / 255, green: 10 / 255, blue: 20 / 255, alpha: alpha) }
}

/// Many glass surfaces side by side (a grid of keys, a row of chips): one `GlassEffectContainer`, so they share one pass that
/// samples the background instead of one each. Before 26 the content as it is.
struct GlassGroup<Content: View>: View {
    var spacing: Double = 0
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26, tvOS 26, macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// The panel glass of a card with a caret (``CaretCard``): Liquid Glass in the card's rounded body only, the caret drawn over the
/// glass's edge in its blur and tint (over the stream's video: a thin blur in the scrim, as the clear glass there). Glass in any
/// other outline (the body with its caret) has the system work out that outline first, which held the first opening of a context
/// menu 300-480 ms without a frame on a fresh iPad simulator. Before 26 the tint fills the whole outline, as ``GlassShape`` does.
struct CaretCardGlass<S: CaretCard>: View {
    let shape: S
    let tint: RGBA
    @Environment(\.glassOverMedia) private var overMedia
    @Environment(\.delosColors) private var colors

    var body: some View {
        if #available(iOS 26, tvOS 26, macOS 26, *) {
            let caret = shape.only(.caret)
            ZStack {
                GlassShape(shape.only(.body), tint: tint, role: .panel)
                if overMedia {
                    caret.fill(.ultraThinMaterial)
                    caret.fill(colors.scrim.opacity(tint.alpha * 0.85).color)
                } else {
                    caret.fill(.regularMaterial)
                    caret.fill(tint.opacity(tint.alpha * 0.9).color)
                }
            }
        } else {
            GlassShape(shape, tint: tint, role: .panel)
        }
    }
}
