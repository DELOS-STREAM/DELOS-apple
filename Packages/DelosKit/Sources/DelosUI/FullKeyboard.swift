import DelosData
import DelosInput
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(GameController)
import GameController
#endif

/*
 * The Delos full keyboard over the stream (`FullKeyboard.kt` of DELOS for Android, the approved "Flat console"
 * prototype): a solid bar docked to the bottom edge with six rows of flat keys, a hint strip under them and, for the
 * controller, one gold ring that glides between the keys. Everything moves with the shared motion language like the
 * stream menu. Touch, the pointer and the controller drive it through ``FullKeyboardState``.
 */

/// The colors of the keyboard, from the theme (`KeyboardPalette.kt`): the bar and the keys in the background's hue, a
/// focused key inverted (the text color as fill), sticky in the accent, pressed in the second accent. For the default Delos
/// palette these are the prototype's; the light theme gets a light bar.
struct KeyboardPalette: Equatable {
    let barTop: RGBA, barBottom: RGBA
    let key: RGBA, quiet: RGBA
    /// The one tinted key: it leaves the keyboard.
    let hide: RGBA, hideIcon: RGBA
    let text: RGBA, text2: RGBA, text3: RGBA
    /// What the text is written on when ``text`` is the fill (hint glyphs).
    let onText: RGBA
    let focus: RGBA, onFocus: RGBA
    /// The small character of a stacked key on the focused (white) key.
    let focusTop: RGBA
    let latched: RGBA, onLatched: RGBA, latchedBarFocused: RGBA
    let pressed: RGBA, onPressed: RGBA
    let popup: RGBA, onPopup: RGBA

    init(_ c: DelosColors) {
        let base = c.baseHue
        text = c.text
        text2 = c.text2
        text3 = c.text3
        onText = c.bg
        focus = c.text
        onFocus = c.bg
        hideIcon = c.accent2
        latched = c.accent
        onLatched = c.onAccent
        pressed = c.accent2
        popup = c.text
        onPopup = c.bg
        if c.dark {
            barTop = hsl(base, 44, 13)
            barBottom = hsl(base, 47, 9.5)
            key = hsl(base, 39, 20)
            quiet = hsl(base, 42, 14.5)
            hide = hsl(c.accent3Hue + 30, 28, 18)
            focusTop = hsl(base, 17, 42)
            latchedBarFocused = hsl(c.accentHue, 100, 43)
            onPressed = hsl(c.accent2Hue, 85, 9)
        } else {
            barTop = hsl(base, 30, 92)
            barBottom = hsl(base, 34, 88)
            key = hsl(base, 40, 99)
            quiet = hsl(base, 30, 94)
            hide = hsl(c.accent3Hue + 30, 40, 92)
            focusTop = hsl(base, 15, 70)
            latchedBarFocused = hsl(c.accentHue, 100, 38)
            onPressed = RGBA(red: 1, green: 1, blue: 1)
        }
    }
}

/// The prototype's `#shade`: black fading in from half the screen's height to .38 at the bottom edge, only where the
/// keyboard is (its popup room and its bar).
enum KeyboardShade {
    static let maxAlpha = 0.38
    static let color = RGBA(red: 4 / 255, green: 6 / 255, blue: 14 / 255)

    /// The gradient's stops (location 0…1 down the keyboard [height], alpha) for a keyboard whose bar starts [barTop] below
    /// its top, on a screen [screenHeight] high; all in stage pixels.
    static func stops(height: Double, barTop: Double, screenHeight: Double) -> [(location: Double, alpha: Double)] {
        let top = screenHeight - height
        let half = screenHeight / 2
        func alphaAt(_ y: Double) -> Double { maxAlpha * min(max((y + top - half) / half, 0), 1) }
        var stops: [(Double, Double)] = [(0, 0), (barTop / height, alphaAt(barTop))]
        if half - top > barTop, half - top < height { stops.append(((half - top) / height, 0)) }
        stops.append((1, maxAlpha))
        return stops
    }
}

extension KeyboardPrefs {
    /// The profile's size settings of the keyboard.
    init(_ settings: StreamSettings) {
        self.init(
            autoFitDisabled: settings.bool(.onscreenKeyboardAutofit), heightDp: settings.int(.onscreenKeyboardHeight),
            widthDp: settings.int(.onscreenKeyboardWidth), align: KeyboardAlign.parse(settings.text(.onscreenKeyboardAlignMode)),
            opacityPercent: min(max(settings.int(.keyboardOpacity), 0), 100))
    }
}

/// The ring around the focused key: a 4 px gold line with a 3 px gap in the background color, around a key of corner 11.
private enum KeyRing {
    static let width = 4.0
    static let gap = 3.0
    static let corner = 11.0
}

/// The keyboard over the stream: as wide as the screen, docked to the bottom, as tall as it needs with room above for the
/// popup of the top row. Lay it out over the whole screen (it ignores the safe area like the bar of Android; the keys keep
/// out of the side insets of a notch).
struct FullKeyboardLayer: View {
    let state: FullKeyboardState
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors
    @Environment(\.reducedMotion) private var reduced
    /// The keys are in (animated): the bar fades in, the rows rise one after the other.
    @State private var shown = false

    var body: some View {
        let insets = (leading: Double(stage.safe.leading), trailing: Double(stage.safe.trailing))
        let metrics = KeyboardMetrics.metrics(
            screenWidth: stage.width - insets.leading - insets.trailing, prefs: state.prefs, dpPerPx: stage.scale)
        let palette = KeyboardPalette(colors)
        let height = metrics.popupRoom + metrics.barHeight
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack(alignment: .top) {
                shade(height: height, barTop: metrics.popupRoom)
                    .opacity(shown ? 1 : 0)
                    .animation(barAnimation, value: shown)
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    Color.clear.frame(height: stage.px(metrics.popupRoom)).allowsHitTesting(false)
                    KeyboardBar(state: state, metrics: metrics, palette: palette, shown: shown, insets: insets)
                }
                KeyPopupLayer(state: state, metrics: metrics, palette: palette, insets: insets, stageWidth: stage.width)
            }
            .frame(height: stage.px(height))
        }
        .onChange(of: state.open, initial: true) { _, open in shown = open }
        // The ring appears when the keys are in, then follows them
        .task(id: state.open) {
            guard state.open else { return }
            try? await Task.sleep(for: .milliseconds(Int(Motion.ring)))
            guard !Task.isCancelled else { return }
            state.settled()
        }
    }

    private var barAnimation: Animation {
        shown ? .timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.cardFadeIn / 1000) : .timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.exit / 1000)
    }

    private func shade(height: Double, barTop: Double) -> some View {
        let stops = KeyboardShade.stops(height: height, barTop: barTop, screenHeight: stage.height).map {
            Gradient.Stop(color: KeyboardShade.color.opacity($0.alpha).color, location: $0.location)
        }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }
}

private struct KeyboardBar: View {
    let state: FullKeyboardState
    let metrics: KeyboardMetrics
    let palette: KeyboardPalette
    let shown: Bool
    let insets: (leading: Double, trailing: Double)
    @Environment(\.stage) private var stage

    var body: some View {
        let alignment: Alignment = switch state.prefs.align {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
        ZStack(alignment: .bottom) {
            // The group the opacity setting dims: the bar, its shadow, the keys and the ring. Touches on it never reach the stream
            ZStack(alignment: .top) {
                LinearGradient(colors: [palette.barTop.color, palette.barBottom.color], startPoint: .top, endPoint: .bottom)
                    .shadow(color: .black.opacity(0.5), radius: stage.px(30), y: stage.px(-24))
                    .opacity(shown ? 1 : 0)
                    .animation(
                        .timingCurve(0.25, 0.1, 0.25, 1, duration: (shown ? Motion.cardFadeIn : Motion.exit) / 1000), value: shown)
                KeyRows(state: state, metrics: metrics, palette: palette, shown: shown)
                    .frame(width: stage.px(metrics.bodyWidth))
                    .frame(maxWidth: .infinity, alignment: alignment)
                    .padding(.leading, stage.px(KeyboardMetrics.side + insets.leading))
                    .padding(.trailing, stage.px(KeyboardMetrics.side + insets.trailing))
                    .padding(.top, stage.px(KeyboardMetrics.topPad))
            }
            .opacity(Double(state.prefs.opacityPercent) / 100)
            .contentShape(Rectangle())
            #if !os(tvOS)
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in })
            #endif
            // The hints are not dimmed with the keys: they say what the buttons do
            HintStrip(state: state, palette: palette, bodyWidth: metrics.bodyWidth)
                .frame(width: stage.px(metrics.bodyWidth))
                .frame(maxWidth: .infinity, alignment: alignment)
                .padding(.leading, stage.px(KeyboardMetrics.side + insets.leading))
                .padding(.trailing, stage.px(KeyboardMetrics.side + insets.trailing))
                .padding(.bottom, stage.px(HintStrip.bottom))
                .allowsHitTesting(false)
        }
        .frame(height: stage.px(metrics.barHeight))
    }
}

/// Where the keys are, in stage pixels of the rows' box: the spans of ``KeyGrid/layoutSpans(_:width:gap:sep:)`` at the
/// body's width, one key height and gap per row.
struct KeyLayout {
    let spans: [[KeySpan]]
    let keyHeight: Double

    init(metrics: KeyboardMetrics) {
        spans = KeyGrid.standard.rows.map { KeyGrid.layoutSpans($0, width: metrics.bodyWidth) }
        keyHeight = metrics.keyHeight
    }

    func rowTop(_ row: Int) -> Double { Double(row) * (keyHeight + KeyboardMetrics.gap) }

    func frame(_ pos: KeyPos) -> CGRect {
        let span = spans[pos.row][pos.col]
        return CGRect(x: span.start, y: rowTop(pos.row), width: span.end - span.start, height: keyHeight)
    }
}

private struct KeyRows: View {
    let state: FullKeyboardState
    let metrics: KeyboardMetrics
    let palette: KeyboardPalette
    let shown: Bool
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced
    @Environment(\.delosColors) private var colors
    /// The ring bumps against the edge of the keyboard and returns (the chevron nudge of the choices).
    @State private var nudge = 0.0

    var body: some View {
        let layout = KeyLayout(metrics: metrics)
        let grid = KeyGrid.standard
        ZStack(alignment: .topLeading) {
            ForEach(grid.rows.indices, id: \.self) { r in
                ZStack(alignment: .topLeading) {
                    ForEach(grid.rows[r].indices, id: \.self) { c in
                        let pos = KeyPos(row: r, col: c)
                        let frame = layout.frame(pos)
                        FullKeyCap(key: grid.key(pos), pos: pos, width: frame.width, state: state, metrics: metrics, palette: palette)
                            .frame(width: stage.px(frame.width), height: stage.px(frame.height))
                            .offset(x: stage.px(frame.minX), y: stage.px(frame.minY))
                    }
                }
                .opacity(shown ? 1 : 0)
                .offset(y: shown || reduced ? 0 : stage.px(Motion.rise))
                .animation(rowAnimation(r), value: shown)
            }
            ring(layout)
        }
        .frame(height: stage.px(layout.rowTop(grid.rows.count) - KeyboardMetrics.gap), alignment: .topLeading)
        .onChange(of: state.nudgeCount) { _, count in
            guard count > 0, !reduced else { return }
            withAnimation(Motion.spring(Motion.chevronBump * 0.4)) { nudge = 1 }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(Motion.chevronBump * 0.4)))
                withAnimation(Motion.spring(Motion.chevronBump * 0.6)) { nudge = 0 }
            }
        }
    }

    private func rowAnimation(_ row: Int) -> Animation {
        shown
            ? Motion.out(Motion.rowIn).delay((Motion.rowDelay + Double(row) * Motion.staggerRow) / 1000)
            : .timingCurve(0.5, 0, 0.75, 0, duration: Motion.exit / 1000)
    }

    @ViewBuilder
    private func ring(_ layout: KeyLayout) -> some View {
        if let focus = state.focus {
            let frame = layout.frame(focus)
            let focusedPressed = state.focusVisible && state.pressed.contains(KeyGrid.standard.key(focus).code)
            let (dx, dy): (Double, Double) = switch state.nudgeDirection {
            case .left: (-1, 0)
            case .right: (1, 0)
            case .up: (0, -1)
            case .down: (0, 1)
            }
            let g = KeyRing.gap, w = KeyRing.width
            ZStack {
                RoundedRectangle(cornerRadius: stage.px(KeyRing.corner + g))
                    .strokeBorder(colors.bg.color, lineWidth: stage.px(g))
                    .frame(width: stage.px(frame.width + 2 * g), height: stage.px(frame.height + 2 * g))
                RoundedRectangle(cornerRadius: stage.px(KeyRing.corner + g + w))
                    .strokeBorder(colors.accent.color, lineWidth: stage.px(w))
                    .frame(width: stage.px(frame.width + 2 * (g + w)), height: stage.px(frame.height + 2 * (g + w)))
            }
            .frame(width: stage.px(frame.width), height: stage.px(frame.height))
            // The ring squeezes with the key under it
            .scaleEffect(focusedPressed ? Motion.pressScale : 1)
            .animation(reduced ? nil : Motion.spring(focusedPressed ? Motion.press : Motion.focus), value: focusedPressed)
            .offset(x: stage.px(frame.minX + dx * Motion.chevronBumpDistance * nudge), y: stage.px(frame.minY + dy * Motion.chevronBumpDistance * nudge))
            .animation(reduced ? nil : .timingCurve(0.3, 1.22, 0.42, 1, duration: Motion.ring / 1000), value: focus)
            .opacity(state.focusVisible ? 1 : 0)
            .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: (state.focusVisible ? Motion.ringIn : Motion.ringOut) / 1000), value: state.focusVisible)
            .allowsHitTesting(false)
        }
    }
}

// MARK: A key

private struct FullKeyCap: View {
    let key: KeyDef
    let pos: KeyPos
    /// The key's width in stage pixels.
    let width: Double
    let state: FullKeyboardState
    let metrics: KeyboardMetrics
    let palette: KeyboardPalette
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced
    #if !os(tvOS)
    @GestureState private var touching = false
    /// The touch that is down was taken (the keyboard was not leaving), so its release is reported.
    @State private var accepted = false
    #endif

    var body: some View {
        let focused = state.focusVisible && state.focus == pos
        let latched = state.latched.contains(key.code)
        let pressed = state.pressed.contains(key.code)
        let label = FullKeyboardKeys.label(key, shift: state.shifted, caps: state.capsOn)
        let lit = latched && !focused
        // The look, by priority: pressed (second accent), sticky (accent), focused (inverted), the Hide key's tint, quiet and plain keys
        let fill: RGBA =
            pressed ? palette.pressed : lit ? palette.latched : focused ? palette.focus
            : key.kind == .hide ? palette.hide : key.quiet ? palette.quiet : palette.key
        let content: RGBA = pressed ? palette.onPressed : lit ? palette.onLatched : focused ? palette.onFocus : palette.text
        let fontSize = metrics.fontSize
        let fade = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000)
        let cap = ZStack {
            RoundedRectangle(cornerRadius: stage.px(KeyRing.corner)).fill(fill.color)
            legend(label: label, fontSize: fontSize, content: content, focused: focused, pressed: pressed)
            // A latched modifier carries a bar under its legend: the state never relies on color alone
            if latched {
                VStack {
                    Spacer(minLength: 0)
                    Capsule()
                        .fill((focused ? palette.latchedBarFocused : palette.onLatched.opacity(0.85)).color)
                        .frame(width: stage.px(width * 0.3), height: stage.px(4))
                        .padding(.bottom, stage.px(8))
                }
            }
        }
        .animation(fade, value: fill)
        .animation(fade, value: content)
        .scaleEffect(pressed ? Motion.pressScale : 1)
        .animation(reduced ? nil : Motion.spring(pressed ? Motion.press : Motion.focus), value: pressed)
        .contentShape(Rectangle())
        #if os(tvOS)
        cap
        #else
        cap
            // Each key reads its own finger (so several keys can be held): down presses, up or cancel releases
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).updating($touching) { _, down, _ in down = true })
            .onChange(of: touching) { _, down in
                if down {
                    accepted = state.touchDown(key.code)
                } else if accepted {
                    accepted = false
                    state.touchUp(key.code)
                }
            }
        #endif
    }

    @ViewBuilder
    private func legend(label: KeyLabel, fontSize: Double, content: RGBA, focused: Bool, pressed: Bool) -> some View {
        switch key.glyph {
        case .text:
            FadingLegend(text: label.primary, size: key.small ? fontSize * 0.8 : fontSize, color: content)
        case .stacked:
            // The other character small above, the one the key types now below: Shift swaps them with a crossfade
            let hint = pressed ? palette.onPressed : focused ? palette.focusTop : palette.text2
            VStack(spacing: stage.px(fontSize * 0.08)) {
                FadingLegend(text: label.secondary ?? "", size: fontSize * 0.7, color: hint)
                FadingLegend(text: label.primary, size: fontSize, color: content)
            }
            .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000), value: hint)
        case .arrow:
            if let arrow = KeyCode.arrow(key.code) {
                ArrowGlyph(arrow: arrow, color: content).frame(width: stage.px(fontSize * 1.1), height: stage.px(fontSize * 1.1))
            }
        case .space:
            Capsule()
                .fill(content.opacity(content.alpha * 0.55).color)
                .frame(width: stage.px(min(width * 0.38, 120)), height: stage.px(3))
        case .hide:
            VStack(spacing: stage.px(fontSize * 0.1)) {
                SymbolView(symbol: Symbols.close, size: fontSize * 1.05, color: pressed ? content : palette.hideIcon, filled: focused)
                Text(verbatim: "HIDE") // l10n-ignore: a key legend, like Android's
                    .font(DelosFonts.figtree(stage.tpx(fontSize * 0.52), .bold))
                    .tracking(stage.tpx(fontSize * 0.52) * 0.1)
                    .foregroundStyle(content.color)
            }
        }
    }
}

/// A legend that crossfades when its text changes (Shift, Caps Lock); the key does not jump.
private struct FadingLegend: View {
    let text: String
    let size: Double
    let color: RGBA
    @Environment(\.stage) private var stage

    var body: some View {
        Text(verbatim: text)
            .font(DelosFonts.figtree(stage.tpx(size), .semibold))
            .tracking(stage.tpx(size) * 0.01)
            .foregroundStyle(color.color)
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.opacity)
            .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000), value: text)
    }
}

/// The arrows are strokes: 24-unit paths drawn with a 2.4 unit round line.
private struct ArrowGlyph: View {
    let arrow: KeyArrow
    let color: RGBA

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 24
            var path = Path()
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
            switch arrow {
            case .up:
                path.move(to: p(12, 19)); path.addLine(to: p(12, 5))
                path.move(to: p(5.5, 11.5)); path.addLine(to: p(12, 5)); path.addLine(to: p(18.5, 11.5))
            case .down:
                path.move(to: p(12, 5)); path.addLine(to: p(12, 19))
                path.move(to: p(5.5, 12.5)); path.addLine(to: p(12, 19)); path.addLine(to: p(18.5, 12.5))
            case .left:
                path.move(to: p(19, 12)); path.addLine(to: p(5, 12))
                path.move(to: p(11.5, 5.5)); path.addLine(to: p(5, 12)); path.addLine(to: p(11.5, 18.5))
            case .right:
                path.move(to: p(5, 12)); path.addLine(to: p(19, 12))
                path.move(to: p(12.5, 5.5)); path.addLine(to: p(19, 12)); path.addLine(to: p(12.5, 18.5))
            }
            context.stroke(path, with: .color(color.color), style: StrokeStyle(lineWidth: 2.4 * unit, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: Popup

/// The bubble above the pressed key: where the finger is, so it is not hidden under it. Not dimmed with the keys.
private struct KeyPopupLayer: View {
    let state: FullKeyboardState
    let metrics: KeyboardMetrics
    let palette: KeyboardPalette
    let insets: (leading: Double, trailing: Double)
    let stageWidth: Double
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced

    /// The popup stands this far above the key and is 1.1 keys wide and 1.15 keys tall at least.
    static let lift = 10.0
    static let minWidth = 1.1
    static let height = 1.15
    /// The opacity's transition: the popup lives only 75 ms past the release.
    static let fadeMs = 75.0

    var body: some View {
        if let popup = state.popup, let pos = KeyGrid.standard.find(popup.code) {
            let on = state.popupOn
            let key = KeyLayout(metrics: metrics).frame(pos)
            // The rows' box: inside the side padding, aligned in the room the setting gives it
            let room = stageWidth - insets.leading - insets.trailing - 2 * KeyboardMetrics.side
            let alignOffset: Double = switch state.prefs.align {
            case .left: 0
            case .center: (room - metrics.bodyWidth) / 2
            case .right: room - metrics.bodyWidth
            }
            let centerX = insets.leading + KeyboardMetrics.side + alignOffset + key.midX
            let keyTop = metrics.popupRoom + KeyboardMetrics.topPad + key.minY
            // A point above the key's center; the bubble stands on it
            Color.clear
                .frame(width: 0, height: 0)
                .overlay(alignment: .bottom) {
                    Text(verbatim: popup.text)
                        .font(DelosFonts.figtree(stage.tpx(40), .bold))
                        .foregroundStyle(palette.onPopup.color)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, stage.px(24))
                        .frame(minWidth: stage.px(metrics.keyHeight * Self.minWidth), minHeight: stage.px(metrics.keyHeight * Self.height))
                        .background(RoundedRectangle(cornerRadius: stage.px(14)).fill(palette.popup.color))
                        .shadow(color: .black.opacity(0.7), radius: stage.px(17), y: stage.px(16))
                        .fixedSize()
                        // From 88 % of its height below its place and 0.9 big to its place at full size, centered over the key
                        .scaleEffect(on || reduced ? 1 : 0.9, anchor: .bottom)
                        .offset(y: on || reduced ? 0 : stage.px(metrics.keyHeight * Self.height * 0.12))
                        .animation(reduced ? nil : Motion.spring(Motion.press), value: on)
                        .opacity(on ? 1 : 0)
                        .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Self.fadeMs / 1000), value: on)
                }
                .position(x: stage.px(centerX), y: stage.px(keyTop - Self.lift))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
    }
}

// MARK: Hints

/// `A Press`, `B Close`, `L3 Shift`, `X Delete`, `Y Space` and the strip's title: only while a controller drives the keyboard.
private struct HintStrip: View {
    let state: FullKeyboardState
    let palette: KeyboardPalette
    let bodyWidth: Double
    @Environment(\.stage) private var stage

    static let bottom = 14.0
    static let height = 48.0
    static let glyphSize = 36.0
    /// The five hints take about 720 px: on a narrower keyboard the title goes, so the strip stays one line.
    static let titleMinWidth = 1100.0

    var body: some View {
        let on = state.open && state.input == .controller
        HStack(spacing: stage.px(30)) {
            hint("A", L("keyboard_hint_press"))
            hint("B", L("keyboard_hint_close"))
            hint("L3", L("keyboard_hint_shift"))
            hint("X", L("keyboard_hint_delete"))
            hint("Y", L("keyboard_hint_space"))
            Spacer(minLength: 0)
            if bodyWidth >= Self.titleMinWidth {
                Text(L("keyboard_title"))
                    .font(DelosFonts.figtree(stage.tpx(17), .semibold))
                    .tracking(stage.tpx(17) * 0.14)
                    .foregroundStyle(palette.text3.color)
                    .lineLimit(1)
            }
        }
        .frame(height: stage.px(Self.height))
        // They come in after the keys (the row delay), go out with everything else
        .opacity(on ? 1 : 0)
        .animation(
            on ? .timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000).delay(Motion.rowDelay / 1000)
                : .timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.exit / 1000),
            value: on)
    }

    private func hint(_ glyph: String, _ label: String) -> some View {
        HStack(spacing: stage.px(12)) {
            // The stick click is a two-letter glyph: smaller, so it stays inside the circle
            Text(verbatim: glyph)
                .font(DelosFonts.figtree(stage.tpx(Self.glyphSize * (glyph.count > 1 ? 0.42 : 0.55)), .heavy))
                .foregroundStyle(palette.onText.color)
                .frame(width: stage.px(Self.glyphSize), height: stage.px(Self.glyphSize))
                .background(Circle().fill(palette.text.color))
            Text(label)
                .font(DelosFonts.figtree(stage.tpx(22), .semibold))
                .foregroundStyle(palette.text2.color)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: Haptics

#if os(iOS)
/// The keyboard's vibrations (`haptic` of Android's `KeyBoardLayoutController`): a key down, a key up, a latch, the
/// keyboard hidden (Android's REJECT).
@MainActor
final class KeyboardHaptics {
    private let press = UIImpactFeedbackGenerator(style: .light)
    private let release = UIImpactFeedbackGenerator(style: .soft)
    private let latch = UIImpactFeedbackGenerator(style: .medium)
    private let hide = UINotificationFeedbackGenerator()

    func play(_ haptic: KeyHaptic) {
        switch haptic {
        case .press: press.impactOccurred()
        case .release: release.impactOccurred(intensity: 0.6)
        case .latch: latch.impactOccurred()
        case .hide: hide.notificationOccurred(.error)
        }
    }
}
#endif

// MARK: Siri Remote

#if os(tvOS)
/// The Siri Remote drives the open keyboard on Apple TV (it has no extended gamepad, so ``GameInput`` never sees it): its
/// touch surface is the left stick, its click is A. Its Back button closes the keyboard through the stream's exit command,
/// Play/Pause still opens the stream menu.
@MainActor
final class SiriRemoteKeyboard {
    private let onChange: @MainActor (GamepadSnapshot, GamepadSnapshot) -> Void
    private var last: [ObjectIdentifier: GamepadSnapshot] = [:]
    private var observer: NSObjectProtocol?
    private var attached: [GCController] = []

    init(onChange: @escaping @MainActor (GamepadSnapshot, GamepadSnapshot) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachAll() }
        }
        attachAll()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        for controller in attached { controller.microGamepad?.valueChangedHandler = nil }
        attached.removeAll()
        last.removeAll()
    }

    private func attachAll() {
        for controller in GCController.controllers() where controller.extendedGamepad == nil {
            guard let pad = controller.microGamepad, !attached.contains(where: { $0 === controller }) else { continue }
            attached.append(controller)
            let id = ObjectIdentifier(controller)
            pad.reportsAbsoluteDpadValues = false
            pad.valueChangedHandler = { [weak self] pad, _ in
                var snapshot = GamepadSnapshot()
                snapshot.a = pad.buttonA.isPressed
                snapshot.leftStickX = pad.dpad.xAxis.value
                snapshot.leftStickY = pad.dpad.yAxis.value
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let old = self.last[id] ?? GamepadSnapshot()
                    self.last[id] = snapshot
                    if old != snapshot { self.onChange(old, snapshot) }
                }
            }
        }
    }
}
#endif
