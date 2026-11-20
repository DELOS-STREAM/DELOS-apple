import DelosInput
import SwiftUI

/// A key of a hardware keyboard, drawn with the shared font's Mac key caps: the key of each button of the shell
/// (``MenuInput/keyCommand(_:typing:modified:)``, docs/ARCHITECTURE.md, "Input kind and the hints").
enum KeyCap: Hashable, Sendable {
    case returnKey, space, escape, tab, letterF, letterO, leftBracket, rightBracket, arrows

    /// The key that does what the controller's [button] does; nil for one no key has (the guide, the sticks).
    static func of(_ button: HintButton) -> KeyCap? {
        switch button {
        case .pad(.south): .returnKey
        case .pad(.east): .escape
        case .pad(.west), .pad(.menuRight): .letterO
        case .pad(.north): .letterF
        case .pad(.menuLeft): .tab
        case .pad(.leftShoulder): .leftBracket
        case .pad(.rightShoulder): .rightBracket
        case .adjust: .arrows
        case .key(let cap): cap
        case .pad, .tap, .click, .secondaryClick: nil
        }
    }

    /// The caps drawn for it, side by side (the adjust cue is two arrows).
    var symbols: [String] {
        switch self {
        case .returnKey: [Symbols.macReturn]
        case .space: [Symbols.macSpace]
        case .escape: [Symbols.macEscape]
        case .tab: [Symbols.macTab]
        case .letterF: [Symbols.macLetterF]
        case .letterO: [Symbols.macLetterO]
        case .leftBracket: [Symbols.macLeftBracket]
        case .rightBracket: [Symbols.macRightBracket]
        case .arrows: [Symbols.macArrowLeft, Symbols.macArrowRight]
        }
    }
}

/// The button a hint names: a place on the connected controller (drawn with its glyph family), the adjust cue, which is
/// no button (`Glyph.ADJUST` of Android: two arrows), or what the other kinds of input do instead (``InputKind``): a tap
/// of the finger, a click or a secondary (right, two-finger) click of the pointer, a key of the keyboard.
enum HintButton: Hashable, Sendable {
    case pad(GlyphRole)
    case adjust
    case tap
    case click
    case secondaryClick
    case key(KeyCap)
}

/// A hint of the hint bar (`Hint` of DELOS for Android's `shell/ui/Bars.kt`). `shortLabel` is the label a cramped (compact)
/// bar uses before it drops the label altogether.
struct Hint: Hashable, Sendable {
    var button: HintButton
    var label: String
    var shortLabel: String?
    /// A touch, a pointer or a keyboard can press it in the bar (Filter): it is then a glass pill with [icon] before its label;
    /// a controller has the button itself, and the hint stays a hint.
    var tappable = false
    /// The symbol of the pill a tappable hint becomes (the filter's funnel), so it reads as a button.
    var icon: String? = nil
    /// The key that does it on a keyboard when that is not the button's own (``KeyCap/of(_:)``): in the library filter Space
    /// toggles a chip and Return applies the choices.
    var key: KeyCap? = nil
}

/// Sizes for complete controller caps and the unchanged non-controller hints.
enum GlyphLook {
    static let size = 38.0, letter = 21.0, icon = 24.0, letterInset = 8.0
    /// Approved controller artwork occupies 192 of its 256 font units.
    static let controllerInkFraction = 0.75
    static let adjustScale = 1.075, tapScale = 1.0

    static func controllerEm(for inkSize: Double) -> Double { inkSize / controllerInkFraction }
}

/// Resolves physical button positions to the shared font's complete controller caps.
/// Kept in DelosUI so DelosInput has no dependency on the font or its generated symbols.
enum ControllerFontGlyph {
    static func symbol(_ role: GlyphRole, family: PadFamily) -> String {
        switch family {
        case .generic:
            switch role {
            case .leftShoulder: Symbols.padDualsenseL1
            case .rightShoulder: Symbols.padDualsenseR1
            case .leftTrigger: Symbols.padDualsenseL2
            case .rightTrigger: Symbols.padDualsenseR2
            default: symbol(role, family: .xbox)
            }
        case .xbox:
            switch role {
            case .south: Symbols.padXboxA
            case .east: Symbols.padXboxB
            case .west: Symbols.padXboxX
            case .north: Symbols.padXboxY
            case .leftShoulder: Symbols.padXboxLb
            case .rightShoulder: Symbols.padXboxRb
            case .leftTrigger: Symbols.padXboxLt
            case .rightTrigger: Symbols.padXboxRt
            case .leftStick: Symbols.padXboxStickLClick
            case .rightStick: Symbols.padXboxStickRClick
            case .menuLeft: Symbols.padXboxView
            case .menuRight: Symbols.padXboxMenu
            case .touchpad: Symbols.padDualsenseTouchpad
            case .dpad: Symbols.padXboxDpadNeutral
            case .guide: Symbols.padXboxGuide
            }
        case .dualSense:
            switch role {
            case .south: Symbols.padDualsenseCross
            case .east: Symbols.padDualsenseCircle
            case .west: Symbols.padDualsenseSquare
            case .north: Symbols.padDualsenseTriangle
            case .leftShoulder: Symbols.padDualsenseL1
            case .rightShoulder: Symbols.padDualsenseR1
            case .leftTrigger: Symbols.padDualsenseL2
            case .rightTrigger: Symbols.padDualsenseR2
            case .leftStick: Symbols.padDualsenseStickLClick
            case .rightStick: Symbols.padDualsenseStickRClick
            case .menuLeft: Symbols.padDualsenseCreate
            case .menuRight: Symbols.padDualsenseOptions
            case .touchpad: Symbols.padDualsenseTouchpad
            case .dpad: Symbols.padDualsenseDpadNeutral
            case .guide: Symbols.padDualsensePs
            }
        case .dualShock:
            switch role {
            case .south: Symbols.padDualshock4Cross
            case .east: Symbols.padDualshock4Circle
            case .west: Symbols.padDualshock4Square
            case .north: Symbols.padDualshock4Triangle
            case .leftShoulder: Symbols.padDualshock4L1
            case .rightShoulder: Symbols.padDualshock4R1
            case .leftTrigger: Symbols.padDualshock4L2
            case .rightTrigger: Symbols.padDualshock4R2
            case .leftStick: Symbols.padDualshock4StickLClick
            case .rightStick: Symbols.padDualshock4StickRClick
            case .menuLeft: Symbols.padDualshock4Share
            case .menuRight: Symbols.padDualshock4Options
            case .touchpad: Symbols.padDualshock4Touchpad
            case .dpad: Symbols.padDualshock4DpadNeutral
            case .guide: Symbols.padDualshock4Ps
            }
        case .nintendo:
            switch role {
            case .south: Symbols.padJoyconB
            case .east: Symbols.padJoyconA
            case .west: Symbols.padJoyconY
            case .north: Symbols.padJoyconX
            case .leftShoulder: Symbols.padJoyconL
            case .rightShoulder: Symbols.padJoyconR
            case .leftTrigger: Symbols.padJoyconZl
            case .rightTrigger: Symbols.padJoyconZr
            case .leftStick: Symbols.padJoyconStickLClick
            case .rightStick: Symbols.padJoyconStickRClick
            case .menuLeft: Symbols.padJoyconMinus
            case .menuRight: Symbols.padJoyconPlus
            case .touchpad: Symbols.padDualsenseTouchpad
            case .dpad: Symbols.padJoyconDpadNeutral
            case .guide: Symbols.padJoyconHome
            }
        }
    }
}

/// A button hint at `size` stage pixels of ink. Controller glyphs already contain their caps;
/// only non-controller hints add a background shape.
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
        // While the keyboard is the input a button is drawn as its key, also beside a control (the Artwork screen's pills)
        let shown = ControllerGlyphs.shared.kind == .keyboard ? KeyCap.of(button).map(HintButton.key) ?? button : button
        Group {
            switch shown {
            case .pad(let role):
                fontCap(ControllerFontGlyph.symbol(role, family: ControllerGlyphs.shared.family), side: side)
                    .frame(width: side, height: side)
            case .key(let cap):
                HStack(spacing: stage.px(4 * k)) {
                    ForEach(cap.symbols, id: \.self) { fontCap($0, side: side) }
                }
            case .click:
                fontCap(Self.click, side: side)
            case .secondaryClick:
                fontCap(Self.secondaryClick, side: side)
            default:
                nonPadMark(k: k, ink: ink)
                    .frame(width: side, height: side)
                    .background(Circle().fill((disc ?? colors.text).color))
            }
        }
        .accessibilityHidden(true)
    }

    /// The pointer's click and secondary click: the trackpad's on the iPad (the Magic Keyboard), the mouse's on the Mac.
    #if os(macOS)
    static let click = Symbols.macMouseClickLeft, secondaryClick = Symbols.macMouseClickRight
    #else
    static let click = Symbols.macTrackpadClick, secondaryClick = Symbols.macTrackpadSecondaryClick
    #endif

    /// A complete cap of the shared font (a controller's button, a key, the trackpad), the ink of a disc's height; a key
    /// cap wider than tall (Return, Tab) keeps its width.
    private func fontCap(_ symbol: String, side: CGFloat) -> some View {
        Text(symbol)
            .font(DelosFonts.symbol(stage.px(GlyphLook.controllerEm(for: size)), filled: true))
            .foregroundStyle((disc ?? colors.text).color)
            .fixedSize()
            .frame(minWidth: side, minHeight: side)
    }

    @ViewBuilder private func nonPadMark(k: Double, ink: RGBA) -> some View {
        switch button {
        case .tap: SymbolView(symbol: Symbols.touchApp, size: GlyphLook.icon * GlyphLook.tapScale * k, color: ink, filled: true)
        case .adjust: SymbolView(symbol: Symbols.swapHoriz, size: GlyphLook.icon * GlyphLook.adjustScale * k, color: ink, filled: true)
        case .pad, .key, .click, .secondaryClick: EmptyView()
        }
    }
}
