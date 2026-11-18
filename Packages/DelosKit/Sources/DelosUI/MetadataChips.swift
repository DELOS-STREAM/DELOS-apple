import DelosData
import SwiftUI

/// The shape and size of every info pill (`Pill` of DELOS for Android): the [entries] (icon and label each) in one
/// capsule, set apart by a thin bar in the text color; [fill] lies over the glass, [border] is its 1 px outline.
struct InfoPill: View {
    struct Entry {
        let icon: String
        let label: String
    }

    let entries: [Entry]
    let text: RGBA
    let icon: RGBA
    var fill: RGBA?
    let border: RGBA
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                if index > 0 {
                    Capsule().fill(text.opacity(0.55).color)
                        .frame(width: stage.px(1.5), height: stage.px(18))
                        .padding(.horizontal, stage.px(12))
                }
                HStack(spacing: stage.px(8)) {
                    SymbolView(symbol: entry.icon, size: 22, color: icon)
                    Text(entry.label)
                        .font(DelosFonts.figtree(stage.tpx(19)))
                        .foregroundStyle(text.color)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, stage.px(16))
        .padding(.vertical, stage.px(6))
        .background {
            GlassShape(Capsule(), tint: colors.surface)
                .overlay { if let fill { Capsule().fill(fill.color) } }
                .overlay(Capsule().strokeBorder(border.color, lineWidth: stage.px(1)))
        }
    }
}

/// The colors of a genre or theme pill: a soft tint of one hue, its text and icon a light shade of it.
struct TagTint: Equatable {
    let fill: RGBA
    let border: RGBA
    let content: RGBA

    /// The genre pill's recipe: the row's accent.
    static func genre(hue: Double, saturation: Double, dark: Bool) -> TagTint {
        let s = min(max(saturation, 20), 95)
        return dark
            ? TagTint(fill: hsl(hue, s, 34, 0.35), border: hsl(hue, s, 55, 0.55), content: hsl(hue, s, 85))
            : TagTint(fill: hsl(hue, s, 50, 0.2), border: hsl(hue, s, 40, 0.5), content: hsl(hue, s, 24))
    }

    /// The theme pill's recipe: the same in the game's second color, but fainter, so the genre stays the accent.
    static func theme(hue: Double, saturation: Double, dark: Bool) -> TagTint {
        let s = min(max(saturation, 20), 95)
        return dark
            ? TagTint(fill: hsl(hue, s, 30, 0.16), border: hsl(hue, s, 55, 0.45), content: hsl(hue, s, 80, 0.9))
            : TagTint(fill: hsl(hue, s, 50, 0.14), border: hsl(hue, s, 40, 0.45), content: hsl(hue, s, 26, 0.92))
    }

    /// How far the theme's hue lies from the genre's when the game has no second color.
    static let themeHueShift = 40.0
}

/// The game's genres (one or two, in one pill), filled with a tint of the game's main color (the accent's while the
/// game's colors are off or unknown), so it is the row's accent.
struct GenrePill: View {
    let genres: [GameGenre]
    let gameColors: GameColors?
    @Environment(\.delosColors) private var colors

    var body: some View {
        let hue = gameColors?.hues.first ?? colors.accentHue
        // How vivid the game's color is (1 = as the palette's) sets the pill's saturation; the accent's is 1
        let vividness = gameColors?.saturations.first ?? 1
        let tint = TagTint.genre(hue: hue, saturation: vividness * 80, dark: colors.dark)
        InfoPill(entries: genres.map { .init(icon: TagLook.genreIcon($0.id), label: TagLook.genreName($0)) },
                 text: tint.content, icon: tint.content, fill: tint.fill, border: tint.border)
    }
}

/// The game's themes (one or two, in one pill), tinted with the game's second cover color (its main color shifted along
/// the hue wheel when it has only one, the palette's accent color while the colors are off or unknown).
struct ThemePill: View {
    let themes: [GameGenre]
    let gameColors: GameColors?
    @Environment(\.delosColors) private var colors

    var body: some View {
        let hues = gameColors?.hues ?? []
        let hue = hues.count > 1 ? hues[1] : hues.first.map { $0 + TagTint.themeHueShift } ?? colors.accent3Hue
        let saturations = gameColors?.saturations ?? []
        let vividness = saturations.count > 1 ? saturations[1] : saturations.first ?? 1
        let tint = TagTint.theme(hue: hue, saturation: vividness * 80 * 0.7, dark: colors.dark)
        InfoPill(entries: themes.map { .init(icon: TagLook.themeIcon($0.id), label: TagLook.themeName($0)) },
                 text: tint.content, icon: tint.content, fill: tint.fill, border: tint.border)
    }
}

/// The native HDR badge (`NativeHdrChip`): cyan to indigo to fuchsia under a light scrim, with a soft glow.
struct NativeHDRChip: View {
    @Environment(\.stage) private var stage

    var body: some View {
        let indigo = Color(.sRGB, red: 0x63 / 255, green: 0x66 / 255, blue: 0xF1 / 255)
        HStack(spacing: stage.px(8)) {
            SymbolView(symbol: Symbols.hdrOn, size: 22, color: RGBA(red: 1, green: 1, blue: 1))
            Text("HDR")
                .font(DelosFonts.figtree(stage.tpx(19)))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, stage.px(16))
        .padding(.vertical, stage.px(6))
        .background {
            Capsule()
                .fill(LinearGradient(
                    colors: [Color(.sRGB, red: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255), indigo,
                             Color(.sRGB, red: 0xD9 / 255, green: 0x46 / 255, blue: 0xEF / 255)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Capsule().fill(Color.black.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: stage.px(1)))
                .shadow(color: indigo.opacity(0.35), radius: stage.px(8))
        }
        .accessibilityElement(children: .combine)
    }
}

/// The badges of the info row in one line: the facts, a thin divider, the tag pills; 12 px apart, the divider 16 px
/// from each side. When they do not fit in the room they scroll back and forth in it, the edge with badges behind it
/// fading (the fade glides with them).
struct BadgeStrip<Facts: View, Tags: View>: View {
    let hasFacts: Bool
    let hasTags: Bool
    @ViewBuilder let facts: () -> Facts
    @ViewBuilder let tags: () -> Tags
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion
    @State private var content = 0.0
    @State private var room = 0.0
    @State private var shifted = false

    private var overflow: Double { max(content - room, 0) }

    var body: some View {
        HStack(spacing: stage.px(12)) {
            facts()
            if hasTags {
                // Clearly visible but light: a short rounded bar in the dim text color
                if hasFacts {
                    Capsule().fill(colors.text3.opacity(0.55).color)
                        .frame(width: stage.px(2), height: stage.px(28))
                        .padding(.horizontal, stage.px(4))
                }
                tags()
            }
        }
        .fixedSize()
        .onGeometryChange(for: Double.self) { $0.size.width } action: { content = $0 }
        .offset(x: shifted ? -overflow : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { room = $0 }
        .modifier(EdgeFadeMask(
            hiddenStart: shifted ? overflow : 0, hiddenEnd: shifted ? 0 : overflow, axis: .horizontal,
            start: FadeEdge(solid: stage.px(40)), end: FadeEdge(solid: stage.px(40)), bleed: stage.px(40), outset: stage.px(40)))
        .task(id: overflow > 0 && !reduceMotion) {
            shifted = false
            guard overflow > 0, !reduceMotion else { return }
            // MarqueeMotion.bounceOffset (MarqueeText.kt:53-68): still 0.7 s, linear to the end at 56 stage px/s, a 0.9 s
            // pause, back at the same speed, a 0.9 s pause, and again
            try? await Task.sleep(for: .seconds(SettingsReadingMotion.startDelay))
            while !Task.isCancelled {
                let leg = Self.bounceLeg(overflow: overflow, pxPerSecond: Double(stage.px(SettingsReadingMotion.speed)))
                withAnimation(.linear(duration: leg)) { shifted = true }
                try? await Task.sleep(for: .seconds(leg + SettingsReadingMotion.loopDelay))
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: leg)) { shifted = false }
                try? await Task.sleep(for: .seconds(leg + SettingsReadingMotion.loopDelay))
            }
        }
    }

    /// How long one way of the bounce takes: [overflow] at [pxPerSecond] (never zero).
    static func bounceLeg(overflow: Double, pxPerSecond: Double) -> Double {
        max(overflow / pxPerSecond, 0.001)
    }
}
