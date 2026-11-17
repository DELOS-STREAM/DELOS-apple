import DelosData
import SwiftUI
#if os(iOS)
import CoreHaptics
import UIKit
#endif

/// The look of the on-screen controls in the DELOS style (`OscStyle` of DELOS for Android): thin light outlines over a faint
/// dark glass, labels in Figtree capitals, and the profile's main colour filling whatever is pressed (with its contrasting
/// colour for the label). Everything is drawn in pixels of the panel; [stroke] is one point (Android's one dp) in pixels.
struct OscStyle {
    /// The profile's main colour and the colour on it, of the dark theme (`delosColors(appearance.copy(dark = true))`).
    let accent: RGBA
    let onAccent: RGBA
    let stroke: CGFloat

    init(palette: Palette, stroke: CGFloat) {
        let colors = DelosColors(palette: palette, dark: true)
        accent = colors.accent
        onAccent = colors.onAccent
        self.stroke = stroke
    }

    static let glass = RGBA(red: 0x0B / 255, green: 0x12 / 255, blue: 0x20 / 255)
    static let glassAlpha = 0.34
    static let lineAlpha = 0.72
    static let white = RGBA(red: 1, green: 1, blue: 1)

    /// Whatever is pressed shows clearly, however transparent the controls are set.
    static func pressedAlpha(_ opacity: Double) -> Double { max(opacity, 0.92) }

    private static func c(_ rgba: RGBA, _ alpha: Double) -> Color { rgba.opacity(min(max(alpha, 0), 1)).color }

    /// A button: a circle when it is about square (face buttons, L3 / R3), else a pill (bumpers, triggers, Back / Start, the
    /// trackpad). Pressed: filled with the main colour, with a soft halo.
    func button(_ g: inout GraphicsContext, width: CGFloat, height: CGFloat, label: String?, pressed: Bool, opacity: Double) {
        let s = stroke
        let rect = CGRect(x: s, y: s, width: width - 2 * s, height: height - 2 * s)
        let round = abs(width - height) < max(width, height) * 0.15
        let radius = round ? min(rect.width, rect.height) / 2 : rect.height / 2
        let shape = Path(roundedRect: rect, cornerRadius: max(0, radius))
        if pressed { g.stroke(shape, with: .color(Self.c(accent, 0.28 * opacity)), lineWidth: s * 3) }
        g.fill(shape, with: .color(pressed ? Self.c(accent, Self.pressedAlpha(opacity)) : Self.c(Self.glass, Self.glassAlpha * opacity)))
        g.stroke(shape, with: .color(pressed ? Self.c(accent, Self.pressedAlpha(opacity)) : Self.c(Self.white, Self.lineAlpha * opacity)), lineWidth: s)
        guard let label, !label.isEmpty else { return }
        // Letters about a third of a circle; longer labels smaller, fitted to the pill's width
        var size = round || label.count <= 2 ? min(rect.width, rect.height) * 0.32 : rect.height * 0.26
        let color = pressed ? Self.c(onAccent, Self.pressedAlpha(opacity)) : Self.c(Self.white, 0.92 * opacity)
        func text(_ size: CGFloat) -> GraphicsContext.ResolvedText {
            g.resolve(Text(label).font(DelosFonts.figtree(max(size, 1), .semibold)).foregroundStyle(color))
        }
        let measured = text(size).measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width
        let fit = rect.width * 0.64
        if measured > fit { size *= fit / measured }
        g.draw(text(size), at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }

    /// The D-pad: a cross of four arms, the pressed ones (one or two) filled with the main colour, a chevron in each arm.
    func dpad(_ g: inout GraphicsContext, width: CGFloat, height: CGFloat, directions: OscDirections, opacity: Double) {
        let s = stroke
        let size = min(width, height) - s * 2
        let cx = width / 2, cy = height / 2
        let arm = size * 0.34, half = size / 2, r = arm * 0.28
        func bar(_ l: CGFloat, _ t: CGFloat, _ rr: CGFloat, _ b: CGFloat) -> Path {
            Path(roundedRect: CGRect(x: l, y: t, width: rr - l, height: b - t), cornerRadius: max(0, r))
        }
        // The cross outline: the union of two rounded bars, so no lines cross the middle
        let cross = bar(cx - arm / 2, cy - half, cx + arm / 2, cy + half).union(bar(cx - half, cy - arm / 2, cx + half, cy + arm / 2))
        g.fill(cross, with: .color(Self.c(Self.glass, Self.glassAlpha * opacity)))
        // Pressed arms, as one shape (a diagonal presses two)
        var pressed = Path()
        if directions.contains(.up) { pressed = pressed.union(bar(cx - arm / 2, cy - half, cx + arm / 2, cy - arm / 2 + r)) }
        if directions.contains(.down) { pressed = pressed.union(bar(cx - arm / 2, cy + arm / 2 - r, cx + arm / 2, cy + half)) }
        if directions.contains(.left) { pressed = pressed.union(bar(cx - half, cy - arm / 2, cx - arm / 2 + r, cy + arm / 2)) }
        if directions.contains(.right) { pressed = pressed.union(bar(cx + arm / 2 - r, cy - arm / 2, cx + half, cy + arm / 2)) }
        g.fill(pressed, with: .color(Self.c(accent, Self.pressedAlpha(opacity))))
        g.stroke(cross, with: .color(Self.c(Self.white, Self.lineAlpha * opacity)), lineWidth: s)
        let c = arm * 0.2, d = half - arm * 0.42
        let line = StrokeStyle(lineWidth: s * 1.1, lineCap: .round, lineJoin: .round)
        func chevron(_ x: CGFloat, _ y: CGFloat, _ dx: CGFloat, _ dy: CGFloat, _ on: Bool) {
            var path = Path()
            path.move(to: CGPoint(x: x - dy * c - dx * c * 0.6, y: y - dx * c - dy * c * 0.6))
            path.addLine(to: CGPoint(x: x + dx * c * 0.4, y: y + dy * c * 0.4))
            path.addLine(to: CGPoint(x: x + dy * c - dx * c * 0.6, y: y + dx * c - dy * c * 0.6))
            g.stroke(path, with: .color(on ? Self.c(onAccent, Self.pressedAlpha(opacity)) : Self.c(Self.white, 0.8 * opacity)), style: line)
        }
        chevron(cx, cy - d, 0, -1, directions.contains(.up))
        chevron(cx, cy + d, 0, 1, directions.contains(.down))
        chevron(cx - d, cy, -1, 0, directions.contains(.left))
        chevron(cx + d, cy, 1, 0, directions.contains(.right))
    }

    /// An analog stick: a thin ring for its reach, a faint ring for the dead zone and the knob; the knob takes the main colour
    /// while the stick is moved ([active]), the ring while it is clicked ([clicked], L3 / R3).
    func stick(
        _ g: inout GraphicsContext, center: CGPoint, outer: CGFloat, deadZone: CGFloat, knob: CGPoint, knobRadius: CGFloat,
        active: Bool, clicked: Bool, opacity: Double
    ) {
        let s = stroke
        func circle(_ p: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
        let ring = circle(center, max(0, outer - s))
        g.fill(ring, with: .color(Self.c(Self.glass, Self.glassAlpha * 0.8 * opacity)))
        g.stroke(ring, with: .color(clicked ? Self.c(accent, Self.pressedAlpha(opacity)) : Self.c(Self.white, Self.lineAlpha * opacity)), lineWidth: s)
        if deadZone > s * 2 { g.stroke(circle(center, deadZone), with: .color(Self.c(Self.white, 0.22 * opacity)), lineWidth: s) }
        let k = circle(knob, max(0, knobRadius))
        if active { g.stroke(k, with: .color(Self.c(accent, 0.28 * opacity)), lineWidth: s * 3) }
        g.fill(k, with: .color(active ? Self.c(accent, Self.pressedAlpha(opacity)) : Self.c(Self.glass, 0.5 * opacity)))
        g.stroke(k, with: .color(active ? Self.c(accent, Self.pressedAlpha(opacity)) : Self.c(Self.white, 0.85 * opacity)), lineWidth: s)
    }

    /// The editor's frame colours (`VirtualControllerElement`): moving red, resizing magenta, turning on or off green for a
    /// control that is on and grey for one that is off; green also frames the control being dragged.
    static func frameColor(_ mode: OscMode, enabled: Bool) -> Color {
        let alpha = 0xF0 / 255.0
        switch mode {
        case .move: return Color(.sRGB, red: 1, green: 0, blue: 0, opacity: alpha)
        case .resize: return Color(.sRGB, red: 1, green: 0, blue: 1, opacity: alpha)
        case .disableEnable:
            return enabled ? selected : Color(.sRGB, red: 0xAA / 255, green: 0xAA / 255, blue: 0xAA / 255, opacity: alpha)
        case .active: return .clear
        }
    }

    static let selected = Color(.sRGB, red: 0, green: 1, blue: 0, opacity: 0xF0 / 255.0)

    /// Android's `ic_settings` (the Material gear), on its 24-unit grid.
    static let gear: Path = {
        var p = Path()
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        p.move(to: P(19.14, 12.94))
        p.addCurve(to: P(19.2, 12), control1: P(19.18, 12.64), control2: P(19.2, 12.33))
        p.addCurve(to: P(19.13, 11.06), control1: P(19.2, 11.68), control2: P(19.18, 11.36))
        p.addLine(to: P(21.16, 9.48))
        p.addCurve(to: P(21.28, 8.87), control1: P(21.34, 9.34), control2: P(21.39, 9.07))
        p.addLine(to: P(19.36, 5.55))
        p.addCurve(to: P(18.77, 5.33), control1: P(19.24, 5.33), control2: P(18.99, 5.26))
        p.addLine(to: P(16.38, 6.29))
        p.addCurve(to: P(14.76, 5.35), control1: P(15.88, 5.91), control2: P(15.35, 5.59))
        p.addLine(to: P(14.4, 2.81))
        p.addCurve(to: P(13.92, 2.4), control1: P(14.36, 2.57), control2: P(14.16, 2.4))
        p.addLine(to: P(10.08, 2.4))
        p.addCurve(to: P(9.61, 2.81), control1: P(9.84, 2.4), control2: P(9.65, 2.57))
        p.addLine(to: P(9.25, 5.35))
        p.addCurve(to: P(7.63, 6.29), control1: P(8.66, 5.59), control2: P(8.12, 5.92))
        p.addLine(to: P(5.24, 5.33))
        p.addCurve(to: P(4.65, 5.55), control1: P(5.02, 5.25), control2: P(4.77, 5.33))
        p.addLine(to: P(2.74, 8.87))
        p.addCurve(to: P(2.86, 9.48), control1: P(2.62, 9.08), control2: P(2.66, 9.34))
        p.addLine(to: P(4.89, 11.06))
        p.addCurve(to: P(4.8, 12), control1: P(4.84, 11.36), control2: P(4.8, 11.69))
        p.addCurve(to: P(4.87, 12.94), control1: P(4.8, 12.31), control2: P(4.82, 12.64))
        p.addLine(to: P(2.84, 14.52))
        p.addCurve(to: P(2.72, 15.13), control1: P(2.66, 14.66), control2: P(2.61, 14.93))
        p.addLine(to: P(4.64, 18.45))
        p.addCurve(to: P(5.23, 18.67), control1: P(4.76, 18.67), control2: P(5.01, 18.74))
        p.addLine(to: P(7.62, 17.71))
        p.addCurve(to: P(9.24, 18.65), control1: P(8.12, 18.09), control2: P(8.65, 18.41))
        p.addLine(to: P(9.6, 21.19))
        p.addCurve(to: P(10.08, 21.6), control1: P(9.65, 21.43), control2: P(9.84, 21.6))
        p.addLine(to: P(13.92, 21.6))
        p.addCurve(to: P(14.39, 21.19), control1: P(14.16, 21.6), control2: P(14.36, 21.43))
        p.addLine(to: P(14.75, 18.65))
        p.addCurve(to: P(16.37, 17.71), control1: P(15.34, 18.41), control2: P(15.88, 18.09))
        p.addLine(to: P(18.76, 18.67))
        p.addCurve(to: P(19.35, 18.45), control1: P(18.98, 18.75), control2: P(19.23, 18.67))
        p.addLine(to: P(21.27, 15.13))
        p.addCurve(to: P(21.15, 14.52), control1: P(21.39, 14.91), control2: P(21.34, 14.66))
        p.addLine(to: P(19.14, 12.94))
        p.closeSubpath()
        p.move(to: P(12, 15.6))
        p.addCurve(to: P(8.4, 12), control1: P(10.02, 15.6), control2: P(8.4, 13.98))
        p.addCurve(to: P(12, 8.4), control1: P(8.4, 10.02), control2: P(10.02, 8.4))
        p.addCurve(to: P(15.6, 12), control1: P(13.98, 8.4), control2: P(15.6, 10.02))
        p.addCurve(to: P(12, 15.6), control1: P(15.6, 13.98), control2: P(13.98, 15.6))
        p.closeSubpath()
        return p
    }()
}

/// The on-screen controls on the panel they are laid out on (the view's whole area, in pixels): each control in its own
/// rectangle (Android draws each in its view, clipped to it), the gear at a quarter opacity. Draws only; the touches reach
/// ``OnScreenControls`` from the stream's video surface or ``OscTouchSurface``.
struct OnScreenControlsCanvas: View {
    let controls: OnScreenControls
    let palette: Palette
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            Canvas { g, _ in
                g.scaleBy(x: 1 / scale, y: 1 / scale)
                draw(&g)
            }
            .onAppear { layOut(geometry.size) }
            .onChange(of: geometry.size) { _, size in layOut(size) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func layOut(_ size: CGSize) {
        controls.layOut(width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()))
    }

    private func draw(_ g: inout GraphicsContext) {
        guard controls.visible else { return }
        let style = OscStyle(palette: palette, stroke: scale)
        let gear = controls.gearSlot
        g.drawLayer { layer in
            layer.opacity = 0.25
            layer.translateBy(x: CGFloat(gear.left), y: CGFloat(gear.top))
            layer.scaleBy(x: CGFloat(gear.width) / 24, y: CGFloat(gear.height) / 24)
            layer.fill(OscStyle.gear, with: .color(.white), style: FillStyle(eoFill: true))
        }
        for element in controls.elements where controls.shows(element) {
            let slot = element.slot
            g.drawLayer { layer in
                layer.translateBy(x: CGFloat(slot.left), y: CGFloat(slot.top))
                layer.clip(to: Path(CGRect(x: 0, y: 0, width: slot.width, height: slot.height)))
                draw(element, style: style, in: &layer)
                frames(element, in: &layer)
            }
        }
    }

    private func draw(_ e: OscElement, style: OscStyle, in g: inout GraphicsContext) {
        let w = CGFloat(e.slot.width), h = CGFloat(e.slot.height)
        let opacity = controls.elementOpacity
        switch e.kind {
        case .button, .trigger:
            style.button(&g, width: w, height: h, label: e.label, pressed: e.pressed, opacity: opacity)
        case .dpad:
            style.dpad(&g, width: w, height: h, directions: e.directions, opacity: opacity)
        case .stick(let right, false):
            _ = right
            let r = controls.radii(e)
            let moved = e.stick.motion != .none
            let center = CGPoint(x: w / 2, y: h / 2)
            style.stick(
                &g, center: center, outer: CGFloat(r.complete), deadZone: CGFloat(r.deadZone),
                knob: moved ? CGPoint(x: CGFloat(e.stick.knobX), y: CGFloat(e.stick.knobY)) : center, knobRadius: CGFloat(r.knob),
                active: moved, clicked: e.pressed && e.stick.doubleClick, opacity: opacity)
        case .stick(let right, true):
            if controls.mode.configuring {
                // While the layout is edited a free stick is its whole area in the mode's colour, with its side's letter
                g.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(OscStyle.frameColor(controls.mode, enabled: e.enabled)))
                g.draw(
                    Text(right ? "R" : "L").font(.system(size: max(1, min(w, h) / 2))).foregroundStyle(.white),
                    at: CGPoint(x: w / 2, y: h / 2), anchor: .bottomLeading)
            }
            if e.stick.fingerDown, e.stick.motion != .none {
                let r = controls.radii(e)
                style.stick(
                    &g, center: CGPoint(x: CGFloat(e.stick.startX), y: CGFloat(e.stick.startY)), outer: CGFloat(r.complete),
                    deadZone: CGFloat(r.deadZone), knob: CGPoint(x: CGFloat(e.stick.knobX), y: CGFloat(e.stick.knobY)),
                    knobRadius: CGFloat(r.knob), active: true, clicked: false, opacity: max(opacity, controls.freeStickOpacity))
            }
        }
    }

    /// The editor's frame in its mode's colour, and green over the control being dragged.
    private func frames(_ e: OscElement, in g: inout GraphicsContext) {
        let sw = CGFloat(controls.configStroke)
        let rect = Path(CGRect(x: sw, y: sw, width: CGFloat(e.slot.width) - 2 * sw, height: CGFloat(e.slot.height) - 2 * sw))
        if controls.mode.configuring, case .stick(_, true) = e.kind {} else if controls.mode.configuring {
            g.stroke(rect, with: .color(OscStyle.frameColor(controls.mode, enabled: e.enabled)), lineWidth: sw)
        }
        if e.drag != nil { g.stroke(rect, with: .color(OscStyle.selected), lineWidth: sw) }
    }
}

#if os(iOS)
/// The touches of the on-screen controls where nothing else takes them (the preview): every finger reaches
/// ``OnScreenControls`` with its own id, in pixels of the panel.
struct OscTouchSurface: UIViewRepresentable {
    let controls: OnScreenControls

    func makeUIView(context: Context) -> OscTouchView {
        let view = OscTouchView()
        view.controls = controls
        return view
    }

    func updateUIView(_ view: OscTouchView, context: Context) {
        view.controls = controls
    }

    final class OscTouchView: UIView {
        var controls: OnScreenControls?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .began) }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .moved) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .ended) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .cancelled) }

        private func report(_ touches: Set<UITouch>, _ phase: OnScreenControls.Phase) {
            let scale = traitCollection.displayScale
            for touch in touches {
                let point = touch.location(in: self)
                controls?.touch(
                    ObjectIdentifier(touch).hashValue, phase, x: Float(point.x * scale), y: Float(point.y * scale),
                    time: touch.timestamp * 1000)
            }
        }
    }
}

/// The short vibration of a press on the device's Taptic Engine (Android's `Vibrator.vibrate(createOneShot)`); nothing on a
/// device without one (an iPad).
@MainActor
final class OscPressHaptics {
    private var engine: CHHapticEngine?

    func play(_ vibration: OscVibration) {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            if engine == nil {
                let created = try CHHapticEngine()
                created.playsHapticsOnly = true
                created.isAutoShutdownEnabled = true
                engine = created
            }
            guard let engine else { return }
            try engine.start()
            let intensity = Float(vibration.amplitude.map { min(max($0, 1), 255) } ?? 255) / 255
            let event = CHHapticEvent(
                eventType: .hapticContinuous, parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity)],
                relativeTime: 0, duration: Double(vibration.milliseconds) / 1000)
            try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: [])).start(atTime: CHHapticTimeImmediate)
        } catch {
            engine = nil
        }
    }
}
#endif
