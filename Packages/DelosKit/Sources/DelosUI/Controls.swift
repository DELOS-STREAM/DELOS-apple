import DelosInput
import SwiftUI

/// `.btn` and `.btn.primary` of the prototype (`PillButton` in DELOS for Android): a 76 px pill with an icon and a label.
/// The focused button grows by 8 %, gets a 4 px ring 4 px outside it and a glow; a [primary] one also gets a sweep of
/// light across it. [glyph]: the controller button that runs it, before the icon (the problem card's A and B).
struct PillButton: View {
    let label: String
    var icon: String?
    var primary = false
    let focused: Bool
    var glyph: GlyphRole? = nil
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion

    var body: some View {
        let content = primary ? colors.onAccent : colors.text
        HStack(spacing: stage.px(14)) {
            if let glyph { GlyphButton(glyph, size: 34, disc: content, ink: primary ? colors.accent : colors.bg) }
            if let icon { SymbolView(symbol: icon, size: 32, color: content, filled: focused) }
            Text(label)
                .font(DelosFonts.figtree(stage.tpx(26), .semibold))
                .foregroundStyle(content.color)
                .lineLimit(1)
        }
        .padding(.horizontal, stage.px(glyph == nil ? 40 : 28))
        .frame(height: stage.px(76))
        .background {
            if primary {
                Capsule().fill(colors.accent.color)
            } else {
                GlassShape(Capsule(), tint: colors.surface)
                    .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
            }
        }
        .focusLook(focused, scale: FocusSpacing.pillScale, ring: FocusSpacing.pillRing, glowBlur: 50, glowY: 18, sweep: primary)
    }
}

/// `.sweep`: a band of white light (115°, 28 % at its middle) that crosses a button or a cover once when it gains the
/// focus (1250 ms after 80 ms, the prototype's `--ease-out`), clipped to [shape]. One view for every element that has it,
/// so the pill and the cover share the geometry and the timeline.
struct SweepLight<S: Shape>: View {
    let shape: S
    let focused: Bool
    @Environment(\.reducedMotion) private var reduceMotion
    @State private var progress = 0.0

    var body: some View {
        light
            .clipShape(shape)
            .allowsHitTesting(false)
            .opacity(reduceMotion || !focused ? 0 : 1)
            .onChange(of: focused, initial: true) { _, now in
                guard now else { return }
                progress = 0
                withAnimation(Motion.out(1250).delay(0.08)) { progress = 1 }
            }
    }

        private var light: some View {
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
            .offset(x: (w - band) * (1.3 - 1.7 * progress))
        }
    }
}

/// The text field of a form (the prototype's `.field`, with the label of `ValuePill` in DELOS for Android): an 84 px
/// pill, [width] stage pixels wide, with an icon, a small label in capitals (a dialog's field has none) and the value as
/// a system text field (touch or a hardware keyboard). [focused] is the focus of the controller, [editing] whether the
/// field is being typed in (on tvOS: whether the system focus is on it; selecting it opens the system keyboard).
struct TextPill: View {
    let label: String?
    let icon: String
    let placeholder: String
    @Binding var text: String
    var editing: FocusState<Bool>.Binding
    let focused: Bool
    /// The field takes an address: no capitals, the URL keyboard.
    var address = false
    /// The field takes a secret (an API key): the value is hidden, nothing is corrected or capitalized.
    var secret = false
    var width = 520.0
    var onSubmit: () -> Void = {}
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(16)) {
            SymbolView(symbol: icon, size: 34, color: colors.text3)
            VStack(alignment: .leading, spacing: 0) {
                if let label {
                    Text(label.uppercased(with: .current))
                        .font(DelosFonts.figtree(stage.tpx(17), .semibold))
                        .tracking(stage.tpx(17) * 0.08)
                        .foregroundStyle(colors.text3.color)
                        .lineLimit(1)
                }
                #if os(tvOS)
                // tvOS draws its own plate around a text field: the value is drawn here, and the field lies over the
                // whole pill, almost transparent, only to take the focus and open the keyboard
                Text(text.isEmpty ? placeholder : secret ? String(repeating: "•", count: text.count) : text)
                    .font(DelosFonts.figtree(stage.tpx(30), .semibold))
                    .foregroundStyle((text.isEmpty ? colors.text3 : colors.text).color)
                    .lineLimit(1)
                #else
                field
                #endif
            }
        }
        .padding(.horizontal, stage.px(28))
        .frame(width: stage.px(width), height: stage.px(84), alignment: .leading)
        .background {
            GlassShape(Capsule(), tint: colors.surface2)
                .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
        #if os(tvOS)
        .overlay { field.opacity(0.02) }
        #endif
        .focusLook(focused || editing.wrappedValue, scale: 1.05, ring: 4, glowBlur: 0, glowY: 0)
    }

    @ViewBuilder private var field: some View {
        if secret {
            style(SecureField(text: $text, prompt: Text(placeholder).foregroundStyle(colors.text3.color)) { Text(label ?? placeholder) })
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
        } else {
            style(TextField(text: $text, prompt: Text(placeholder).foregroundStyle(colors.text3.color)) { Text(label ?? placeholder) })
                #if !os(macOS)
                .textInputAutocapitalization(address ? .never : .words)
                .keyboardType(address ? .URL : .default)
                #endif
        }
    }

    private func style(_ field: some View) -> some View {
        field
            .textFieldStyle(.plain)
            .font(DelosFonts.figtree(stage.tpx(30), .semibold))
            .foregroundStyle(colors.text.color)
            .tint(colors.accent.color)
            .focused(editing)
            .submitLabel(.done)
            .autocorrectionDisabled()
            .onSubmit(onSubmit)
            #if os(macOS)
            // The pill has its own focus ring; AppKit would draw its blue one around the field as well
            .focusEffectDisabled()
            #endif
    }
}

extension View {
    /// The focus look of a pill: it grows by [scale], gets a ring of [ring] stage pixels as far outside it, and a glow of
    /// [glowBlur] (CSS box-shadow blur) moved down by [glowY]; no glow when [glowBlur] is 0. [corner] makes the ring a
    /// rounded rectangle around a shape with that corner radius (a cover) instead of a pill. [gap] (stage pixels) is the
    /// band between the element and its ring, filled with the background color as `drawFocusRing` of DELOS for Android does
    /// (nil: transparent, as many pills have it); [glowSpread] is the box-shadow's spread (negative: smaller than the element).
    func focusLook(_ focused: Bool, scale: Double, ring: Double, glowBlur: Double, glowY: Double, corner: Double? = nil, anchor: UnitPoint = .center, sweep: Bool = false,
        glowSpread: Double = 0, gap: Double? = nil) -> some View {
        modifier(FocusLook(focused: focused, scale: scale, ring: ring, glowBlur: glowBlur, glowY: glowY, corner: corner, anchor: anchor, sweep: sweep,
                           glowSpread: glowSpread, gap: gap))
    }
}

/// The scale of a focusable element (`animateFocusScale`): the focus lifts it to [focus], 1 otherwise; a press drops the lift
/// while ``FocusItem``'s shared ``View/pressLook(_:)`` squeezes the item to ``Motion/pressScale``, so every pressed element
/// stands at 0.96 of its size at rest, below every focus scale.
func focusScale(focused: Bool, pressed: Bool, focus: Double) -> Double {
    focused && !pressed ? focus : 1
}

/// The glow blur of a focusable element (CSS blur, stage pixels): a press pulses it to ``Motion/pressGlow`` times [blur],
/// and it comes back with the squeeze.
func focusGlow(_ blur: Double, pressed: Bool) -> Double {
    pressed ? blur * Motion.pressGlow : blur
}

extension Animation {
    /// How the scale of a focusable element moves: the press in 120 ms, the focus 420 ms, both on the prototype's spring;
    /// nil (a jump) with reduced motion.
    static func focusScale(pressed: Bool, reduced: Bool) -> Animation? {
        reduced ? nil : Motion.spring(pressed ? Motion.press : Motion.focus)
    }

    /// The focus ring's and the glow's alpha: 140 ms in, 110 ms out.
    static func focusRing(focused: Bool) -> Animation {
        Motion.out(focused ? Motion.ringIn : Motion.ringOut)
    }
}

private struct FocusLook: ViewModifier {
    let focused: Bool
    let scale: Double
    let ring: Double
    let glowBlur: Double
    let glowY: Double
    let corner: Double?
    /// The point that stays put while the item grows (the wide first cover grows to the left only).
    let anchor: UnitPoint
    let sweep: Bool
    var glowSpread = 0.0
    var gap: Double?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion
    @Environment(\.pressed) private var pressed

    func body(content: Content) -> some View {
        content
            .background {
                // The glow with its spread: the element's shape grown by the spread, blurred (CSS blur 2 sigma) and moved down; not
                // under the element itself, whose glass would show it through
                if glowSpread != 0, glowBlur > 0 {
                    ZStack {
                        if let corner {
                            RoundedRectangle(cornerRadius: max(stage.px(corner + glowSpread), 0), style: .continuous).fill(colors.glow.color)
                        } else {
                            Capsule().fill(colors.glow.color)
                        }
                    }
                    .padding(-stage.px(glowSpread))
                    .blur(radius: stage.px(focusGlow(glowBlur, pressed: pressed) / 2))
                    .offset(y: stage.px(glowY))
                    .opacity(focused ? 1 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .mask {
                        ZStack {
                            Rectangle().fill(.white).padding(-stage.px(400))
                            if let corner {
                                RoundedRectangle(cornerRadius: stage.px(corner), style: .continuous).fill(.black).blendMode(.destinationOut)
                            } else {
                                Capsule().fill(.black).blendMode(.destinationOut)
                            }
                        }
                        .compositingGroup()
                    }
                }
            }
            .background {
                let gap = gap ?? ring
                ZStack {
                    // `box-shadow: 0 0 0 gap bg, 0 0 0 gap+width accent`: the band between element and ring is the background's
                    if self.gap != nil {
                        if let corner {
                            RoundedRectangle(cornerRadius: stage.px(corner + gap)).strokeBorder(colors.bg.color, lineWidth: stage.px(gap))
                                .padding(-stage.px(gap))
                        } else {
                            Capsule().strokeBorder(colors.bg.color, lineWidth: stage.px(gap)).padding(-stage.px(gap))
                        }
                    }
                    Group {
                        if let corner {
                            RoundedRectangle(cornerRadius: stage.px(corner + gap + ring)).strokeBorder(colors.accent.color, lineWidth: stage.px(ring))
                        } else {
                            Capsule().strokeBorder(colors.accent.color, lineWidth: stage.px(ring))
                        }
                    }
                    .padding(-stage.px(gap + ring))
                }
                .opacity(focused ? 1 : 0)
            }
            .overlay {
                if sweep {
                    if let corner { SweepLight(shape: RoundedRectangle(cornerRadius: stage.px(corner)), focused: focused) } else { SweepLight(shape: Capsule(), focused: focused) }
                }
            }
            .shadow(color: focused && glowBlur > 0 && glowSpread == 0 ? colors.glow.color : .clear,
                    radius: stage.px(focusGlow(glowBlur, pressed: pressed) / 2), y: stage.px(glowY))
            .animation(.focusRing(focused: focused), value: focused)
            .scaleEffect(focusScale(focused: focused, pressed: pressed, focus: scale), anchor: anchor)
            .zIndex(focused ? 1 : 0)
            .animation(.focusScale(pressed: pressed, reduced: reduceMotion), value: ScaleState(focused: focused, pressed: pressed))
    }
}

private struct ScaleState: Equatable {
    let focused: Bool
    let pressed: Bool
}

/// A small spinning ring (`Spinner(size, color)` of DELOS for Android): something is being downloaded or prepared. A
/// track of the color at 25 %, a round-capped arc of 100° on it, a turn every 0.9 s; the stroke is 12 % of [size]
/// (stage pixels). ``Spinner`` is the other one, the pairing screens' `.spinner`.
struct RingSpinner: View {
    let size: Double
    var color: RGBA?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        let ink = (color ?? colors.accent).color
        let stroke = stage.px(size * 0.12)
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
            ZStack {
                Circle().inset(by: stroke / 2).stroke(ink.opacity(0.25), lineWidth: stroke)
                Circle().inset(by: stroke / 2).trim(from: 0, to: 100.0 / 360)
                    .stroke(ink, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(turn))
            }
        }
        .frame(width: stage.px(size), height: stage.px(size))
    }
}
