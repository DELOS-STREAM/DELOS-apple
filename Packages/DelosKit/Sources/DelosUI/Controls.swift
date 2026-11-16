import SwiftUI

/// `.btn` and `.btn.primary` of the prototype (`PillButton` in DELOS for Android): a 76 px pill with an icon and a label.
/// The focused button grows by 8 %, gets a 4 px ring 4 px outside it and a glow; a [primary] one also gets a sweep of
/// light across it.
struct PillButton: View {
    let label: String
    var icon: String?
    var primary = false
    let focused: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = 0.0

    var body: some View {
        let content = primary ? colors.onAccent : colors.text
        HStack(spacing: stage.px(14)) {
            if let icon { SymbolView(symbol: icon, size: 32, color: content, filled: focused) }
            Text(label)
                .font(DelosFonts.figtree(stage.px(26), .semibold))
                .foregroundStyle(content.color)
                .lineLimit(1)
        }
        .padding(.horizontal, stage.px(40))
        .frame(height: stage.px(76))
        .background {
            if primary {
                Capsule().fill(colors.accent.color)
            } else {
                Capsule().fill(colors.surface.color)
                    .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
            }
        }
        .overlay { if primary && focused { sweepLight } }
        .focusLook(focused, scale: 1.08, ring: 4, glowBlur: 50, glowY: 18)
        .onChange(of: focused, initial: true) { _, now in
            guard primary, now else { return }
            sweep = 0
            withAnimation(.easeOut(duration: 1.25).delay(0.08)) { sweep = 1 }
        }
    }

    /// `.sweep`: a band of white light (115°, 28 % at its middle) that crosses the button once when it gains the focus.
    private var sweepLight: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            let band = w * 2.6
            // The gradient line of a CSS 115° gradient through a band × h box
            let dx = sin(115 * Double.pi / 180), dy = -cos(115 * Double.pi / 180)
            let half = (band * abs(dx) + h * abs(dy)) / 2
            LinearGradient(
                stops: [
                    // White in both themes, as on Android: light on the main color
                    .init(color: RGBA(red: 1, green: 1, blue: 1, alpha: 0).color, location: 0.3),
                    .init(color: RGBA(red: 1, green: 1, blue: 1, alpha: 0.28).color, location: 0.48),
                    .init(color: RGBA(red: 1, green: 1, blue: 1, alpha: 0).color, location: 0.66),
                ],
                startPoint: UnitPoint(x: 0.5 - dx * half / band, y: 0.5 - dy * half / h),
                endPoint: UnitPoint(x: 0.5 + dx * half / band, y: 0.5 + dy * half / h)
            )
            .frame(width: band, height: h)
            .offset(x: (w - band) * (1.3 - 1.7 * sweep))
        }
        .clipShape(Capsule())
        .allowsHitTesting(false)
        .opacity(reduceMotion ? 0 : 1)
    }
}

/// The text field of a form (the prototype's `.field`, with the label of `ValuePill` in DELOS for Android): an 84 px
/// pill, 520 px wide, with an icon, a small label in capitals and the value as a system text field (touch or a hardware
/// keyboard). [focused] is the focus of the controller, [editing] whether the field is being typed in (on tvOS: whether
/// the system focus is on it; selecting it opens the system keyboard).
struct TextPill: View {
    let label: String
    let icon: String
    let placeholder: String
    @Binding var text: String
    var editing: FocusState<Bool>.Binding
    let focused: Bool
    /// The field takes an address: no capitals, the URL keyboard.
    var address = false
    var onSubmit: () -> Void = {}
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(16)) {
            SymbolView(symbol: icon, size: 34, color: colors.text3)
            VStack(alignment: .leading, spacing: 0) {
                Text(label.uppercased(with: .current))
                    .font(DelosFonts.figtree(stage.px(17), .semibold))
                    .tracking(stage.px(17) * 0.08)
                    .foregroundStyle(colors.text3.color)
                    .lineLimit(1)
                #if os(tvOS)
                // tvOS draws its own plate around a text field: the value is drawn here, and the field lies over the
                // whole pill, almost transparent, only to take the focus and open the keyboard
                Text(text.isEmpty ? placeholder : text)
                    .font(DelosFonts.figtree(stage.px(30), .semibold))
                    .foregroundStyle((text.isEmpty ? colors.text3 : colors.text).color)
                    .lineLimit(1)
                #else
                field
                #endif
            }
        }
        .padding(.horizontal, stage.px(28))
        .frame(width: stage.px(520), height: stage.px(84), alignment: .leading)
        .background {
            Capsule().fill(colors.surface2.color)
                .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
        #if os(tvOS)
        .overlay { field.opacity(0.02) }
        #endif
        .focusLook(focused || editing.wrappedValue, scale: 1.05, ring: 4, glowBlur: 0, glowY: 0)
    }

    private var field: some View {
        TextField(text: $text, prompt: Text(placeholder).foregroundStyle(colors.text3.color)) { Text(label) }
            .textFieldStyle(.plain)
            .font(DelosFonts.figtree(stage.px(30), .semibold))
            .foregroundStyle(colors.text.color)
            .tint(colors.accent.color)
            .focused(editing)
            .submitLabel(.done)
            .autocorrectionDisabled()
            #if !os(macOS)
            .textInputAutocapitalization(address ? .never : .words)
            .keyboardType(address ? .URL : .default)
            #endif
            .onSubmit(onSubmit)
    }
}

extension View {
    /// The focus look of a pill: it grows by [scale], gets a ring of [ring] stage pixels as far outside it, and a glow of
    /// [glowBlur] (CSS box-shadow blur) moved down by [glowY]; no glow when [glowBlur] is 0. [corner] makes the ring a
    /// rounded rectangle around a shape with that corner radius (a cover) instead of a pill.
    func focusLook(_ focused: Bool, scale: Double, ring: Double, glowBlur: Double, glowY: Double, corner: Double? = nil) -> some View {
        modifier(FocusLook(focused: focused, scale: scale, ring: ring, glowBlur: glowBlur, glowY: glowY, corner: corner))
    }
}

private struct FocusLook: ViewModifier {
    let focused: Bool
    let scale: Double
    let ring: Double
    let glowBlur: Double
    let glowY: Double
    let corner: Double?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                Group {
                    if let corner {
                        RoundedRectangle(cornerRadius: stage.px(corner + 2 * ring)).strokeBorder(colors.accent.color, lineWidth: stage.px(ring))
                    } else {
                        Capsule().strokeBorder(colors.accent.color, lineWidth: stage.px(ring))
                    }
                }
                .padding(-stage.px(2 * ring))
                .opacity(focused ? 1 : 0)
            }
            .shadow(color: focused && glowBlur > 0 ? colors.glow.color : .clear, radius: stage.px(glowBlur / 2), y: stage.px(glowY))
            .scaleEffect(focused ? scale : 1)
            .zIndex(focused ? 1 : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.32, dampingFraction: 0.68), value: focused)
    }
}
