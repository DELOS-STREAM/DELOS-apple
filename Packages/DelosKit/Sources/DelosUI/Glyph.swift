import DelosInput
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A key of a hardware keyboard, drawn as a key cap.
enum KeyCap: Hashable, Sendable {
    case returnKey, escape, arrows

    var legend: String {
        switch self {
        case .returnKey: "return"
        case .escape: "esc"
        case .arrows: "\u{2190} \u{2192}"
        }
    }
}

/// The button a hint names: a place on the connected controller (drawn with its glyph family), the adjust cue, which is
/// no button (`Glyph.ADJUST` of Android: two arrows), or what the other kinds of input do instead (``InputKind``): a tap
/// of the finger, a click of the pointer, a key of the keyboard.
enum HintButton: Hashable, Sendable {
    case pad(GlyphRole)
    case adjust
    case tap
    case click
    case key(KeyCap)
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
    /// Interim icons until the PlayStation Create and Options icons are in the symbol font (.agent/tasks/codex-icons.md):
    /// the share arrow and the bars.
    static let createSymbol = Symbols.shareLog, optionsSymbol = Symbols.menu
    static let createScale = 0.9, optionsScale = 0.885, tapScale = 1.0
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
            if case .key(let cap) = button {
                keyCap(cap, k: k, ink: ink, side: side)
            } else if case .pad(let role) = button, let system = SystemSymbol.resolve(ControllerGlyphs.shared.systemSymbol(role)) {
                Image(systemName: system)
                    .font(.system(size: stage.tpx(GlyphLook.icon * k), weight: .semibold))
                    .foregroundStyle(ink.color)
                    .frame(width: side, height: side)
                    .background(Circle().fill((disc ?? colors.text).color))
            } else {
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
        }
        .accessibilityHidden(true)
    }

    /// A key of the keyboard: its legend on a rounded cap with a thin edge, the height of a disc.
    private func keyCap(_ cap: KeyCap, k: Double, ink: RGBA, side: CGFloat) -> some View {
        Text(cap.legend)
            .font(DelosFonts.figtree(stage.tpx(GlyphLook.letter * 0.8 * k), .heavy))
            .foregroundStyle(ink.color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, stage.px(GlyphLook.letterInset))
            .frame(minWidth: side, minHeight: side)
            .background(RoundedRectangle(cornerRadius: side * 0.28).fill((disc ?? colors.text).color))
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
        case .create?: SymbolView(symbol: GlyphLook.createSymbol, size: GlyphLook.icon * GlyphLook.createScale * k, color: rgba, filled: true)
        case .options?: SymbolView(symbol: GlyphLook.optionsSymbol, size: GlyphLook.icon * GlyphLook.optionsScale * k, color: rgba, filled: true)
        case nil:
            switch button {
            case .tap: SymbolView(symbol: Symbols.touchApp, size: GlyphLook.icon * GlyphLook.tapScale * k, color: rgba, filled: true)
            case .click: SymbolView(symbol: Symbols.mouse, size: GlyphLook.icon * GlyphLook.tapScale * k, color: rgba, filled: true)
            default: SymbolView(symbol: Symbols.swapHoriz, size: GlyphLook.icon * GlyphLook.adjustScale * k, color: rgba, filled: true)
            }
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

/// The system's own symbols for a controller's buttons (`GCControllerElement.sfSymbolsName`).
enum SystemSymbol {
    /// The symbol to draw for [name]: the name without its enclosing circle (the glyph sits on a disc of its own) when
    /// that exists, else [name] itself, else nil (not a symbol on this system: the font's icon is drawn).
    static func resolve(_ name: String?) -> String? {
        guard let name else { return nil }
        let bare = name.replacingOccurrences(of: ".circle.fill", with: "").replacingOccurrences(of: ".circle", with: "")
        return [bare, name].first(where: exists)
    }

    private static func exists(_ name: String) -> Bool {
        #if canImport(UIKit)
        UIImage(systemName: name) != nil
        #else
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #endif
    }
}
