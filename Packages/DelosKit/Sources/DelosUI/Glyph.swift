import DelosInput
import SwiftUI

/// The button a hint names: a place on the connected controller (drawn with its glyph family) or the adjust cue, which is
/// no button (`Glyph.ADJUST` of Android: two arrows).
enum HintButton: Hashable, Sendable {
    case pad(GlyphRole)
    case adjust
}

/// A hint of the hint bar (`Hint` of DELOS for Android's `shell/ui/Bars.kt`). `shortLabel` is the label a cramped (compact)
/// bar uses before it drops the label altogether.
struct Hint: Hashable, Sendable {
    var button: HintButton
    var label: String
    var shortLabel: String?
}

/// What a glyph is drawn with: the disc (the text color) and the mark on it (the background color).
enum GlyphLook {
    /// `GlyphButton`'s base size in stage px, and the letter's size at it (Android: 38, 21 ExtraBold).
    static let size = 38.0, letter = 21.0, icon = 24.0, letterInset = 8.0
    /// Material icon sizes were tuned to the Android glyphs: `Glyph.MENU_LEFT` (filter_none 1.2) and `MENU_RIGHT` (menu .885).
    static let viewScale = 1.2, menuScale = 0.885, adjustScale = 1.075
    /// The PlayStation shapes: the share of the disc they cover and their line.
    static let shape = 0.46, shapeLine = 0.085
}

/// A button hint's glyph, `size` stage pixels (`GlyphButton` of Android): a filled disc in the text color with the mark
/// in the background color. Icons and shapes sit in a circle, letters (L1, ZR, ...) may widen it into a pill. The mark
/// comes from ``ControllerGlyphs``: the connected controller's layout.
struct GlyphButton: View {
    let button: HintButton
    var size = GlyphLook.size
    /// The disc and the mark's colors; nil: the text and background colors of the theme (the toast has its own).
    var disc: RGBA?
    var ink: RGBA?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    init(_ role: GlyphRole, size: Double = GlyphLook.size, disc: RGBA? = nil, ink: RGBA? = nil) {
        self.init(button: .pad(role), size: size, disc: disc, ink: ink)
    }

    init(button: HintButton, size: Double = GlyphLook.size, disc: RGBA? = nil, ink: RGBA? = nil) {
        self.button = button
        self.size = size
        self.disc = disc
        self.ink = ink
    }

    var body: some View {
        let k = size / GlyphLook.size
        let ink = ink ?? colors.bg
        let side = stage.px(size)
        let mark: GlyphMark? = if case .pad(let role) = button { ControllerGlyphs.shared.mark(role) } else { nil }
        Group {
            switch mark {
            case .letter(let text)?:
                Text(text)
                    .font(DelosFonts.figtree(stage.tpx(GlyphLook.letter * k), .heavy))
                    .foregroundStyle(ink.color)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, stage.px(GlyphLook.letterInset))
                    .frame(minWidth: side, minHeight: side)
                    .background(Capsule().fill((disc ?? colors.text).color))
            default:
                markView(mark, k: k, ink: ink, side: side)
                    .frame(width: side, height: side)
                    .background(Circle().fill((disc ?? colors.text).color))
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func markView(_ mark: GlyphMark?, k: Double, ink rgba: RGBA, side: CGFloat) -> some View {
        let ink = rgba.color
        let inner = side * GlyphLook.shape
        let line = side * GlyphLook.shapeLine
        switch mark {
        case .cross?: CrossShape().stroke(ink, style: StrokeStyle(lineWidth: line, lineCap: .round)).frame(width: inner, height: inner)
        case .circle?: Circle().strokeBorder(ink, lineWidth: line).frame(width: inner * 1.15, height: inner * 1.15)
        case .square?: RoundedRectangle(cornerRadius: line).strokeBorder(ink, lineWidth: line).frame(width: inner, height: inner)
        case .triangle?:
            TriangleShape().stroke(ink, style: StrokeStyle(lineWidth: line, lineJoin: .round)).frame(width: inner * 1.1, height: inner)
        case .touchpad?:
            RoundedRectangle(cornerRadius: line * 1.4).strokeBorder(ink, lineWidth: line)
                .frame(width: inner * 1.35, height: inner * 0.95)
        case .view?: SymbolView(symbol: Symbols.filterNone, size: GlyphLook.icon * GlyphLook.viewScale * k, color: rgba, filled: true)
        case .menu?: SymbolView(symbol: Symbols.menu, size: GlyphLook.icon * GlyphLook.menuScale * k, color: rgba, filled: true)
        case nil: SymbolView(symbol: Symbols.swapHoriz, size: GlyphLook.icon * GlyphLook.adjustScale * k, color: rgba, filled: true)
        case .letter?: EmptyView()
        }
    }
}

private struct CrossShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}

private struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
