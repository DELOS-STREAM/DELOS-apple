import SwiftUI

/// The press and hover looks of every interactive element (docs/ARCHITECTURE.md, "Press and hover"): one press for all of
/// them, and two hover tiers. A ``FocusItem`` presses its content itself and takes the focus on hover (tier 1: its own
/// focus look, the gold ring where it has one); an element that is not one (a hint pill, the back arrow, a tab, a toast's
/// action, a stepper's arrow) is a button in ``PressButtonStyle``: the same press, and the light hover of tier 2.
extension View {
    /// The press of an activation (``Motion/press``): the element squeezes to ``Motion/pressScale`` on the focus spring, and
    /// springs back in ``Motion/focus`` ms when [pressed] ends. Where the element's own look reads
    /// ``EnvironmentValues/pressed`` it drops its focus lift meanwhile (``focusScale(focused:pressed:focus:)``) and its glow
    /// pulses, so a pressed element stands at 0.96 of its size at rest.
    func pressLook(_ pressed: Bool) -> some View {
        modifier(PressLook(pressed: pressed))
    }

    /// The light hover (tier 2) of an element without a focus ring: while the pointer is over it, it brightens by
    /// ``Motion/hoverTint`` and lifts to ``Motion/hoverScale``, in ``Motion/ringIn`` ms and out in ``Motion/ringOut``; the
    /// lift drops while the element is [pressed], so it presses to 0.96 of its size at rest like every element. The system
    /// pointer stays as it is. No effect on tvOS (no pointer).
    func hoverLook(pressed: Bool = false) -> some View {
        modifier(HoverLook(pressed: pressed))
    }

    /// The focus lift of an element that draws its own focus: [scale] while [focused], dropped while the item is pressed
    /// (``EnvironmentValues/pressed``, ``focusScale(focused:pressed:focus:)``), so the shared press takes it to 0.96 of its
    /// size at rest. The element animates the focus itself; the press moves on the press's spring.
    func focusLift(_ focused: Bool, scale: Double) -> some View {
        modifier(FocusLift(focused: focused, scale: scale))
    }

    /// A button of the interface that is not a ``FocusItem``: the shared press while it is held (seen for at least
    /// ``Motion/pressHold`` ms, so a quick click shows it too), the light hover, and no system hover effect (a highlight or a
    /// lift would take the pointer into it, so it disappeared over the button; the Mac has none).
    @ViewBuilder func pressButton() -> some View {
        #if os(macOS)
        buttonStyle(PressButtonStyle())
        #else
        buttonStyle(PressButtonStyle()).hoverEffectDisabled()
        #endif
    }

    /// An element that a tap or a click activates and that is no ``FocusItem`` (a stepper's arrow): a button of
    /// ``pressButton()`` around it. On tvOS, where a button would take the system focus, it stays a tap.
    @ViewBuilder func pressTap(perform action: @escaping @MainActor () -> Void) -> some View {
        #if os(tvOS)
        onTapGesture(perform: action)
        #else
        Button(action: action) { self }.pressButton()
        #endif
    }
}

private struct PressLook: ViewModifier {
    let pressed: Bool
    @Environment(\.reducedMotion) private var reduced

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? Motion.pressScale : 1)
            .animation(.focusScale(pressed: pressed, reduced: reduced), value: pressed)
    }
}

private struct FocusLift: ViewModifier {
    let focused: Bool
    let scale: Double
    @Environment(\.pressed) private var pressed
    @Environment(\.reducedMotion) private var reduced

    func body(content: Content) -> some View {
        content
            .scaleEffect(focusScale(focused: focused, pressed: pressed, focus: scale))
            .animation(.focusScale(pressed: pressed, reduced: reduced), value: pressed)
    }
}

private struct HoverLook: ViewModifier {
    let pressed: Bool
    @State private var hovered = false
    @Environment(\.reducedMotion) private var reduced

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content
            .brightness(hovered ? Motion.hoverTint : 0)
            .scaleEffect(hovered && !pressed && !reduced ? Motion.hoverScale : 1)
            .animation(Motion.out(hovered ? Motion.ringIn : Motion.ringOut), value: hovered)
            .onHover { hovered = $0 }
        #endif
    }
}

/// The style of ``View/pressButton()``.
struct PressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressButtonBody(label: configuration.label, held: configuration.isPressed)
    }
}

private struct PressButtonBody<Label: View>: View {
    let label: Label
    let held: Bool
    /// Pressed: from the touch or click going down until it is up and the press has been shown ``Motion/pressHold`` ms.
    @State private var pressed = false
    @State private var since: ContinuousClock.Instant?
    @State private var release: Task<Void, Never>?

    var body: some View {
        label
            .environment(\.pressed, pressed)
            .pressLook(pressed)
            .hoverLook(pressed: pressed)
            .onChange(of: held) { _, now in
                release?.cancel()
                if now {
                    pressed = true
                    since = .now
                    return
                }
                let shown = since.map { ContinuousClock.now - $0 } ?? .zero
                let rest = Duration.milliseconds(Int(Motion.press + Motion.pressHold)) - shown
                guard rest > .zero else {
                    pressed = false
                    return
                }
                release = Task { @MainActor in
                    try? await Task.sleep(for: rest)
                    guard !Task.isCancelled else { return }
                    pressed = false
                }
            }
    }
}
