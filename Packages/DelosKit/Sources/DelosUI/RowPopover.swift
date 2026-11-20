import DelosInput
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The card of a popover: Liquid Glass in the card's rounded body, its caret in the glass's blur and tint (``CaretCardGlass``; the
/// stream menu's material: the glass panel role), a pale sheen from the top, a 1 px rim and the soft shadow (`0 40px 90px -20px`).
/// The stream menu's popover and the popovers of the settings rows share it. [blurred]: a card over the rows of a list also blurs
/// what is behind it where the glass does not (before iOS 26, a material), and dims it a little so its values keep their contrast.
struct PopoverGlass<S: CaretCard>: View {
    let shape: S
    var blurred = false
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        ZStack {
            if blurred {
                if #available(iOS 26, tvOS 26, macOS 26, *) {
                    shape.fill(colors.bg2.opacity(0.35).color)
                } else {
                    shape.fill(.regularMaterial)
                    shape.fill(colors.bg2.opacity(0.35).color)
                }
            }
            CaretCardGlass(shape: shape, tint: colors.surface3)
        }
        .overlay {
            LinearGradient(stops: [
                .init(color: colors.accent2.opacity(0.14).color, location: 0),
                .init(color: .white.opacity(0), location: 0.52),
            ], startPoint: .top, endPoint: .bottom)
            .clipShape(shape)
            .allowsHitTesting(false)
        }
        .overlay { shape.stroke(.white.opacity(0.11), lineWidth: stage.px(1)) }
        .background { shape.fill(.black.opacity(0.62)).blur(radius: stage.px(45)).offset(y: stage.px(40)).padding(stage.px(20)) }
    }
}

/// The card of a settings row's popover and its caret as ONE outline: the shared ``CardCaret`` on the card's left edge, pointing left
/// at [caretY] (from the top), or, [flipped], on the right edge pointing right; or only its rounded body or its caret ([part]). The
/// shape's rect holds the caret in its first (flipped: last) ``CardCaret/depth`` stage pixels.
struct RowCardShape: CaretCard {
    var caretY: CGFloat
    var flipped = false
    /// Points per stage pixel.
    let unit: CGFloat
    var part = CardPart.whole

    var animatableData: CGFloat {
        get { caretY }
        set { caretY = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let d = CardCaret.depth * unit
        let card = CGRect(x: flipped ? 0 : d, y: 0, width: max(rect.width - d, 0), height: rect.height)
        return CardCaret.path(
            part, card: card, radius: StreamMenuLayout.popoverRadius * unit, side: flipped ? .right : .left, center: caretY, unit: unit)
    }
}

/// The step of the slider popover and what it applies: the value lives here while the popover is open so that a held ◀ ▶
/// reads the value it has just set (the row is rebuilt a moment later).
@MainActor
@Observable
final class SliderPopupModel {
    private(set) var value: Int
    let spec: SliderSpec
    @ObservationIgnored private let onSet: (Int) -> Void

    init(spec: SliderSpec, onSet: @escaping (Int) -> Void) {
        self.spec = spec
        value = spec.value
        self.onSet = onSet
    }

    /// The row's value changed from outside (a key or the controller): follow it.
    func follow(_ external: Int) {
        if external != value { value = external }
    }

    /// Sets [raw] snapped to the grid and clamped; false when nothing changed.
    @discardableResult
    func apply(_ raw: Int) -> Bool {
        let next = spec.snap(raw)
        guard next != value else { return false }
        value = next
        onSet(next)
        return true
    }

    @discardableResult
    func step(_ steps: Int) -> Bool { apply(spec.stepped(from: value, by: steps)) }
}

/// The popover of a settings row on its second touch (issue #92): the stream menu's card with its caret, vertically centered on
/// the tapped row and kept inside the stage, its caret pointing into that row as if the card grew out of it (``RowPopoverLayout``).
/// An options list for a choice (the current value checked), or the slider popover: ◀ ▶ (hold to repeat), the slider and the
/// value to tap and type. A tap beside the card closes it; the controller's B does too (the screen's capture).
struct RowPopover: View {
    let row: SettingRow
    let kind: RowPopupKind
    /// The options list's focus (up and down, A picks).
    let focus: FocusModel
    /// The row's frame in this layer's space, points.
    let anchor: CGRect
    let slider: SliderPopupModel?
    let onPick: (Int) -> Void
    /// "Reset to profile value" as the options list's last item (a custom app setting); nil: none.
    var onReset: (() -> Void)?
    let onClose: () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion
    @State private var appeared = false
    /// The keyboard's top edge in screen points while it is up, and this layer's frame there: the card stays above it.
    @State private var keyboardTop: CGFloat?
    @State private var layerFrame = CGRect.zero

    static func optionID(_ index: Int) -> String { "option-\(index)" }
    static let resetID = "option-reset"

    var body: some View {
        GeometryReader { proxy in
            let unit = stage.scale
            let usable = keyboardTop.map { min(proxy.size.height, max($0 - layerFrame.minY, 0)) } ?? proxy.size.height
            let size = CGSize(width: proxy.size.width / unit, height: usable / unit)
            let rowRect = CGRect(x: anchor.minX / unit, y: anchor.minY / unit, width: anchor.width / unit, height: anchor.height / unit)
            let top = RowPopoverLayout.topMargin + stage.safe.top
            let bottom = RowPopoverLayout.bottomMargin + stage.safe.bottom
            let side = RowPopoverLayout.sideMargin + max(stage.safe.leading, stage.safe.trailing)
            let layout = layout(row: rowRect, size: size, top: top, bottom: bottom, side: side)
            let place = layout.placement
            let caret = stage.px(RowPopoverLayout.caretHeight)
            let shape = RowCardShape(caretY: stage.px(place.caretY), flipped: place.flipped, unit: stage.px(1))
            let tip = UnitPoint(x: place.flipped ? 1 : 0, y: place.caretY / place.card.height)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                ZStack(alignment: .topLeading) {
                    PopoverGlass(shape: shape, blurred: true)
                    content(listHeight: layout.list, width: place.card.width, height: place.card.height)
                        .padding(place.flipped ? .trailing : .leading, caret)
                }
                .frame(width: stage.px(place.card.width) + caret, height: stage.px(place.card.height), alignment: .topLeading)
                .contentShape(shape)
                // A tap on the card (between its parts) stays on it; a tap beside it reaches the scrim and closes it
                .onTapGesture {}
                .scaleEffect(appeared || reducedMotion ? 1 : 0.86, anchor: tip)
                .opacity(appeared ? 1 : 0)
                .animation(Motion.spring(Motion.popIn), value: appeared)
                .offset(x: stage.px(place.card.minX) - (place.flipped ? 0 : caret), y: stage.px(place.card.minY))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(.easeOut(duration: 0.25), value: keyboardTop)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { layerFrame = $0 }
        .onAppear { appeared = true }
        .onChange(of: row.value) { _, now in if let spec = SliderSpec(now) { slider?.follow(spec.value) } }
        .transition(.opacity)
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardTop = frame.minY < UIScreen.main.bounds.height ? frame.minY : nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardTop = nil }
        #endif
    }

    private func layout(row rowRect: CGRect, size: CGSize, top: Double, bottom: Double, side: Double) -> (placement: RowPopoverPlacement, list: Double) {
        switch kind {
        case .options:
            let count: Int
            if case .choice(_, let options, _) = row.value { count = options.count + (onReset == nil ? 0 : 1) } else { count = 0 }
            return RowPopoverLayout.options(row: rowRect, count: count, stage: size, top: top, bottom: bottom, side: side)
        case .slider:
            return (RowPopoverLayout.slider(row: rowRect, stage: size, top: top, bottom: bottom, side: side), 0)
        }
    }

    @ViewBuilder private func content(listHeight: Double, width: Double, height: Double) -> some View {
        switch kind {
        case .options:
            if case let .choice(_, options, selected) = row.value {
                OptionsList(
                    title: row.label, options: options, selected: selected, focus: focus, listHeight: listHeight, onPick: onPick,
                    onReset: onReset)
            }
        case .slider:
            if let slider { SliderPopupContent(title: row.label, model: slider, onClose: onClose) }
        }
    }
}

/// The options of a choice row (touch; Android issue #92): the title, and the values in a list that scrolls when it is longer than
/// the room, the current one checked and focused. A tap picks a value; with a controller up and down move, A picks.
private struct OptionsList: View {
    let title: String
    let options: [String]
    let selected: Int?
    let focus: FocusModel
    let listHeight: Double
    let onPick: (Int) -> Void
    let onReset: (() -> Void)?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    private typealias L = RowPopoverLayout

    var body: some View {
        VStack(alignment: .leading, spacing: stage.px(L.gap)) {
            Text(title)
                .font(DelosFonts.figtree(stage.tpx(20), .semibold))
                .foregroundStyle(colors.text3.color)
                .lineLimit(1)
                .padding(.horizontal, stage.px(24))
                .frame(height: stage.px(L.title), alignment: .top)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: stage.px(L.gap)) {
                        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                            FocusItem(id: RowPopover.optionID(index), model: focus, action: { onPick(index) }) { focused in
                                optionView(option, current: index == selected, focused: focused)
                            }
                            .id(RowPopover.optionID(index))
                        }
                        if let onReset {
                            FocusItem(id: RowPopover.resetID, model: focus, action: onReset) { focused in
                                optionView(DelosUI.L("settings_game_reset_menu"), icon: Symbols.reset, current: false, focused: focused)
                            }
                            .id(RowPopover.resetID)
                        }
                    }
                    .padding(.vertical, stage.px(L.listRoom))
                    .focusDrivenScroll()
                }
                .focusable(false)
                // A long list fades where options go on behind its edges, like a context menu's
                .scrollEdgeFade(.vertical, .menu)
                .frame(height: stage.px(listHeight))
                .onAppear { proxy.scrollTo(RowPopover.optionID(selected ?? 0)) }
                .onChange(of: focus.focused) { _, now in if let now, !focus.pointerMoved { proxy.scrollTo(now) } }
            }
        }
        .padding(.vertical, stage.px(L.pad))
        .padding(.horizontal, stage.px(12))
        .padding(.top, stage.px(L.gap))
    }

    /// An option (`.menu-item` of the prototype): the focused one on a tint of the main color with a 3 px ring, the current one
    /// with a check; [icon] leads an item that is an action (the reset).
    private func optionView(_ label: String, icon: String? = nil, current: Bool, focused: Bool) -> some View {
        HStack(spacing: stage.px(18)) {
            if let icon { SymbolView(symbol: icon, size: 30, color: focused ? colors.accent : colors.text2) }
            // Scrolls while focused when it does not fit (RowPicker.kt:299-302)
            MarqueeLabel(text: label, active: focused)
                .font(DelosFonts.figtree(stage.tpx(23), .semibold))
                .foregroundStyle(colors.text.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            if current {
                SymbolView(symbol: Symbols.check, size: 30, color: focused ? colors.accent : colors.text2)
            }
        }
        .padding(.leading, stage.px(24))
        .padding(.trailing, stage.px(22))
        .frame(height: stage.px(L.option))
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: stage.px(28))
                .fill(colors.accent.opacity(0.17).color)
                .overlay(RoundedRectangle(cornerRadius: stage.px(28)).strokeBorder(colors.accent.color, lineWidth: stage.px(3)))
                .opacity(focused ? 1 : 0)
        }
    }
}

/// The slider popover's parts, sized for a finger: the arrows, the value's field and the slider's track are ``RowPopoverLayout/touch``
/// high (44 points at the least), the card about twice a compact card wide.
private struct SliderPopupContent: View {
    let title: String
    let model: SliderPopupModel
    let onClose: () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(Layers.self) private var layers: Layers?

    private typealias L = RowPopoverLayout

    var body: some View {
        VStack(alignment: .leading, spacing: stage.px(L.sliderGap)) {
            Text(title)
                .font(DelosFonts.figtree(stage.tpx(24), .semibold))
                .foregroundStyle(colors.text3.color)
                .lineLimit(1)
                .frame(height: stage.px(L.sliderTitle), alignment: .center)
            ValueField(model: model)
                .frame(height: stage.px(L.fieldHeight))
            HStack(spacing: stage.px(L.controlGap)) {
                HoldStepButton(model: model, direction: -1)
                SliderTrackView(model: model)
                HoldStepButton(model: model, direction: 1)
            }
            .frame(height: stage.px(L.touch))
        }
        .padding(stage.px(L.sliderPad))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The value as a large field: the number and its unit; a tap on it opens the system keyboard to type a value, which is validated,
/// snapped to the grid and clamped when the field is left (the check button, Return, a tap elsewhere).
private struct ValueField: View {
    let model: SliderPopupModel
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(Navigator.self) private var navigator
    @Environment(Layers.self) private var layers: Layers?
    @State private var editing = false
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var typing: Bool

    private typealias L = RowPopoverLayout

    var body: some View {
        let spec = model.spec
        HStack(spacing: stage.px(L.controlGap)) {
            ZStack {
                RoundedRectangle(cornerRadius: stage.px(28)).fill(colors.surface2.color)
                RoundedRectangle(cornerRadius: stage.px(28))
                    .strokeBorder(invalid ? colors.accent3.color : editing ? colors.accent.color : colors.line.color, lineWidth: stage.px(editing || invalid ? 3 : 1))
                HStack(spacing: stage.px(12)) {
                    if editing {
                        field(spec)
                    } else {
                        Text(spec.numberText(model.value))
                            .font(DelosFonts.figtree(stage.tpx(L.numberSize), .semibold))
                            .monospacedDigit()
                            .foregroundStyle(colors.text.color)
                    }
                    Text(spec.unit.trimmingCharacters(in: .whitespaces))
                        .font(DelosFonts.figtree(stage.tpx(L.unitSize)))
                        .foregroundStyle(colors.text2.color)
                }
                .padding(.horizontal, stage.px(24))
            }
            .contentShape(Rectangle())
            .onTapGesture { if !editing { begin() } }
            // The field while it is typed in stays reachable; otherwise it is one button that reads the value
            .accessibilityElement(children: editing ? .contain : .ignore)
            .accessibilityLabel(tr("row_slider_enter_value"))
            .accessibilityValue(editing ? "" : spec.label(model.value))
            .accessibilityAddTraits(editing ? [] : .isButton)
            if editing {
                Button(action: commit) {
                    SymbolView(symbol: Symbols.check, size: 40, color: colors.onAccent)
                        .frame(width: stage.px(L.touch), height: stage.px(L.touch))
                        .background(Circle().fill(colors.accent.color))
                }
                .pressButton()
                .accessibilityLabel(tr("row_slider_enter_value"))
            }
        }
        .onChange(of: typing) { _, now in if !now, editing { commit() } }
        // B or Escape while typing leaves the field without applying what was typed
        .onChange(of: navigator.isEditingText) { _, now in if !now, editing { editing = false; typing = false } }
        .onDisappear { if editing { navigator.textEditing(false) } }
    }

    private func field(_ spec: SliderSpec) -> some View {
        TextField("", text: $text)
            .font(DelosFonts.figtree(stage.tpx(L.numberSize), .semibold))
            .foregroundStyle(colors.text.color)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .focused($typing)
            .submitLabel(.done)
            .onSubmit(commit)
            #if os(iOS)
            .keyboardType(spec.divisor > 1 ? .decimalPad : .numberPad)
            #endif
            .onChange(of: text) { _, now in
                invalid = false
                if !SliderSpec.typable(now) { text = now.filter { $0.isASCII && $0.isNumber || $0 == "." || $0 == "," } }
            }
            .fixedSize(horizontal: false, vertical: true)
    }

    private func begin() {
        text = model.spec.numberText(model.value)
        invalid = false
        editing = true
        navigator.textEditing(true)
        layers?.feedback?.play(.open)
        Task { @MainActor in typing = true }
    }

    /// The typed number applies (validated, snapped, clamped); text that is no number is thrown away with the error cue.
    private func commit() {
        guard editing else { return }
        editing = false
        typing = false
        navigator.textEditing(false)
        if let value = model.spec.parse(text) {
            if model.apply(value) { layers?.feedback?.play(.select) }
        } else {
            layers?.feedback?.play(.error)
        }
    }
}

/// ◀ or ▶ of the slider popover: a tap steps once, holding repeats after a pause, faster the longer it is held (the acceleration of
/// a held key). Dimmed at its end of the range.
private struct HoldStepButton: View {
    let model: SliderPopupModel
    let direction: Int
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(Layers.self) private var layers: Layers?
    @State private var holding: Task<Void, Never>?

    private typealias L = RowPopoverLayout

    var body: some View {
        let atEnd = direction < 0 ? model.value <= model.spec.min : model.value >= model.spec.max
        SymbolView(symbol: direction < 0 ? Symbols.chevronLeft : Symbols.chevronRight, size: 44, color: colors.accent2)
            .frame(width: stage.px(L.touch), height: stage.px(L.touch))
            .background(Circle().fill(.white.opacity(holding == nil ? 0.10 : 0.22)))
            .opacity(atEnd ? 0.4 : 1)
            .contentShape(Circle())
            .touching(onChanged: { _ in if holding == nil { begin() } }, onEnded: { end() })
            .pressLook(holding != nil)
            .hoverLook(pressed: holding != nil)
            .accessibilityElement()
            .accessibilityLabel(tr(direction < 0 ? "row_slider_decrease" : "row_slider_increase"))
            .accessibilityAddTraits(.isButton)
            // The press-and-hold gesture is a touch's; VoiceOver's activation steps once
            .accessibilityAction { model.step(direction) }
            .onDisappear { end() }
    }

    private func begin() {
        stepOnce(1)
        holding = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(HoldRepeat.firstDelay)) } catch { return }
            var repeats = 0
            while !Task.isCancelled {
                repeats += 1
                stepOnce(HoldRepeat.steps(model.spec, repeatCount: repeats))
                do { try await Task.sleep(for: .seconds(HoldRepeat.interval)) } catch { return }
            }
        }
    }

    private func end() {
        holding?.cancel()
        holding = nil
    }

    private func stepOnce(_ steps: Int) {
        if model.step(direction * steps) { layers?.feedback?.play(.move) }
    }
}

/// The slider's track in the popover: a tap or a drag anywhere on its ``RowPopoverLayout/touch`` high strip sets the value.
private struct SliderTrackView: View {
    let model: SliderPopupModel
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(Layers.self) private var layers: Layers?

    private typealias L = RowPopoverLayout

    var body: some View {
        GeometryReader { proxy in
            let spec = model.spec
            let span = Double(Swift.max(spec.max - spec.min, 1))
            let fraction = Swift.min(Swift.max(Double(model.value - spec.min) / span, 0), 1)
            let knob = stage.px(L.knob)
            let usable = Swift.max(proxy.size.width - knob, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(colors.surface3.color).frame(height: stage.px(16))
                Capsule()
                    .fill(LinearGradient(colors: [colors.accent.color, colors.accent2.color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: knob / 2 + usable * fraction, height: stage.px(16))
                Circle().fill(.black.opacity(0.3)).frame(width: knob, height: knob).offset(x: usable * fraction, y: stage.px(3))
                Circle().fill(colors.text.color).frame(width: knob, height: knob).offset(x: usable * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .touching(onChanged: { location in
                let f = Swift.min(Swift.max((location.x - knob / 2) / usable, 0), 1)
                if model.apply(spec.min + Int((Double(spec.max - spec.min) * f).rounded())) { layers?.feedback?.play(.move) }
            })
        }
        .accessibilityElement()
        .accessibilityLabel(model.spec.label(model.value))
        .accessibilityAdjustableAction { direction in
            model.step(direction == .increment ? 1 : -1)
        }
    }
}

private func tr(_ key: String) -> String { L(key) }

/// The popover that is open on a settings screen: its row, its kind, the options list's focus and the slider's state.
@MainActor
struct RowPopupState {
    let id: String
    let kind: RowPopupKind
    let focus: FocusModel
    let slider: SliderPopupModel?

    /// The popover [row] opens, nil for a row without one. [onSet]: applies a slider's value.
    static func open(_ row: SettingRow, onSet: @escaping (Int) -> Void) -> RowPopupState? {
        guard let kind = RowPopupKind.of(row) else { return nil }
        switch kind {
        case .options:
            guard case let .choice(_, _, selected) = row.value else { return nil }
            return RowPopupState(id: row.id, kind: kind, focus: FocusModel(initial: RowPopover.optionID(selected ?? 0)), slider: nil)
        case .slider:
            guard let spec = SliderSpec(row.value) else { return nil }
            return RowPopupState(id: row.id, kind: kind, focus: FocusModel(), slider: SliderPopupModel(spec: spec, onSet: onSet))
        }
    }

    /// A command of the controller or the keyboard while the popover is open; nothing reaches the screen behind it. An options
    /// list: up and down move, A picks, B closes. The slider: left and right step (faster the longer held), A and B close. While a
    /// value is typed the keys are the field's, and B leaves the field.
    func capture(_ command: MenuCommand, navigator: Navigator, feedback: Feedback?, close: () -> Void) {
        if navigator.isEditingText {
            if command == .back { navigator.isEditingText = false }
            return
        }
        switch (kind, command) {
        case (_, .back):
            feedback?.play(.back)
            close()
        case (.options, .up), (.options, .down):
            if focus.handle(command) { feedback?.play(.move) }
        case (.options, .accept):
            if focus.handle(.accept) { feedback?.play(.select) }
        case (.slider, .accept):
            feedback?.play(.back)
            close()
        case (.slider, .left), (.slider, .right):
            guard let slider else { return }
            let steps = HoldRepeat.steps(slider.spec, repeatCount: navigator.commandRepeat)
            if slider.step((command == .right ? 1 : -1) * steps) { feedback?.play(.move) }
        default:
            break
        }
    }
}

extension View {
    /// A touch that begins at once and follows the finger ([onChanged] with its location), until it lifts ([onEnded]). Nothing on
    /// tvOS, which has no touch.
    @ViewBuilder fileprivate func touching(onChanged: @escaping (CGPoint) -> Void, onEnded: @escaping () -> Void = {}) -> some View {
        #if os(tvOS)
        self
        #else
        gesture(DragGesture(minimumDistance: 0).onChanged { onChanged($0.location) }.onEnded { _ in onEnded() })
        #endif
    }
}
