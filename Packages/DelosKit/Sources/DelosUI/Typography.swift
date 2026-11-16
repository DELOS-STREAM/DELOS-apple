import CoreText
import Foundation
import SwiftUI

/// The bundled fonts: Unbounded for headings and the wordmark, Figtree for text, Phosphor (Regular and Fill) for icons.
public enum DelosFonts {
    private static let files = ["unbounded", "figtree", "phosphor_regular", "phosphor_fill"]

    /// Registers the bundled fonts for this process; call once at launch. Returns the files that failed to register.
    @discardableResult
    public static func register() -> [String] {
        files.filter { name in
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf") else { return true }
            var error: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            // Already registered (a second call) counts as registered
            if !ok, let error = error?.takeRetainedValue(),
               CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue {
                return false
            }
            return !ok
        }
    }

    static func unbounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .custom("Unbounded", fixedSize: size).weight(weight)
    }

    static func figtree(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Figtree", fixedSize: size).weight(weight)
    }

    static func symbol(_ size: CGFloat, filled: Bool) -> Font {
        .custom(filled ? "Phosphor-Fill" : "Phosphor", fixedSize: size)
    }
}

/// A Phosphor icon from ``Symbols`` at a size in stage pixels. [filled] cross-fades from Regular to Fill over
/// ``Motion/iconFill`` (the Regular and the Fill glyph are both drawn, `Symbol` of DELOS for Android); the filled check is
/// the tick in a circle.
struct SymbolView: View {
    let symbol: String
    let size: Double
    var color: RGBA
    var filled = false
    @Environment(\.stage) private var stage

    var body: some View {
        ZStack {
            Text(symbol)
                .font(DelosFonts.symbol(stage.tpx(size), filled: false))
                .opacity(filled ? 0 : 1)
            Text(symbol == Symbols.check ? Symbols.checkCircle : symbol)
                .font(DelosFonts.symbol(stage.tpx(size), filled: true))
                .opacity(filled ? 1 : 0)
                .accessibilityHidden(true)
        }
        .foregroundStyle(color.color)
        .animation(Motion.out(Motion.iconFill), value: filled)
    }
}
