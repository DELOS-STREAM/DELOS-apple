import SwiftUI

/// Where the popover of a page sits, stage pixels: the card's left edge, its width, the caret's center from the left edge
/// and the card's height (the caret excluded).
struct PopoverPlacement: Equatable {
    var left: Double
    var width: Double
    var caretX: Double
    var height: Double
}

/// The popover of the stream menu (`StreamMenuPopover` of DELOS for Android): a frosted card above the tile that opened it
/// with a caret pointing down at that tile. It grows from 0.86 around the caret's tip while its glass fades in, shrinks
/// back into it, and slides and resizes when another tile's page replaces the page shown.
struct StreamPopoverHost: View {
    let controller: StreamController
    /// The center of the tile that opened the page, stage pixels.
    let anchorX: Double
    /// The card's bottom edge (the caret excluded), stage pixels from the stage's top.
    let bottom: Double
    /// The tallest the card may be.
    let maxHeight: Double
    @Environment(\.reducedMotion) private var reducedMotion
    /// The popover is mounted from its opening until it has animated out.
    @State private var present = false

    var body: some View {
        let menu = controller.menu
        ZStack(alignment: .topLeading) {
            if present {
                StreamPopover(controller: controller, anchorX: anchorX, bottom: bottom, maxHeight: maxHeight, leaving: !menu.isOpen)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: menu.isOpen, initial: true) { _, isOpen in
            if isOpen {
                present = true
            } else if present {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(Int(Motion.exit) + 30))
                    if !menu.isOpen { present = false }
                }
            }
        }
    }
}

private struct StreamPopover: View {
    let controller: StreamController
    let anchorX: Double
    let bottom: Double
    let maxHeight: Double
    let leaving: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion
    @State private var appeared = false

    private typealias M = StreamMenuLayout

    /// x, width, caret and height follow their targets with a slightly under-damped spring (the prototype's `stepGeo`).
    private static let follow = Animation.spring(Spring(mass: 1, stiffness: 190, damping: 2 * 0.8 * (190.0).squareRoot()))

    var body: some View {
        let menu = controller.menu
        let page = menu.shownPage
        let content = controller.menuContent(page)
        let place = placement(page: page, content: content)
        let shape = StreamCardShape(caretX: stage.px(place.caretX), unit: stage.px(1))
        let tip = UnitPoint(x: place.caretX / place.width, y: (place.height + M.caretHeight / 2) / (place.height + M.caretHeight))
        let visible = appeared && !leaving
        ZStack(alignment: .topLeading) {
            glass(shape)
            PopoverContent(controller: controller, page: page, content: content, height: place.height)
                .id(menu.session)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.4).delay(0.15)),
                    removal: .opacity.combined(with: .offset(y: reducedMotion ? 0 : -stage.px(10))).animation(.easeIn(duration: 0.14))))
        }
        .frame(width: stage.px(place.width), height: stage.px(place.height + M.caretHeight), alignment: .topLeading)
        .contentShape(shape)
        // A tap on the card (between the rows) stays on it; a tap beside it reaches the backdrop and closes the popover
        .onTapGesture {}
        .animation(menu.morph && !reducedMotion ? Self.follow : nil, value: place)
        .scaleEffect(visible || reducedMotion ? 1 : M.hiddenScale, anchor: tip)
        .animation(visible ? Motion.spring(Motion.popIn) : Motion.out(Motion.exit), value: visible)
        .opacity(visible ? 1 : 0)
        .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: (visible ? Motion.cardFadeIn : Motion.exit) / 1000), value: visible)
        .offset(x: stage.px(place.left), y: stage.px(bottom - place.height))
        .animation(menu.morph && !reducedMotion ? Self.follow : nil, value: place)
        .onAppear { appeared = true }
    }

    /// The card above its tile, between the margins, as tall as its rows and help need up to the shared maximum.
    private func placement(page: MenuPage, content: StreamMenuContent) -> PopoverPlacement {
        let margin = M.popoverMargin + max(stage.safe.leading, stage.safe.trailing)
        let width = M.popoverWidth(page, stageWidth: stage.width, margin: margin)
        let left = M.popoverLeft(anchorX: anchorX, width: width, stageWidth: stage.width, margin: margin)
        let rows: Int
        switch content {
        case .rows(let list): rows = list.count
        case .pills: rows = 1
        }
        let height = min(M.naturalHeight(rows: rows, textScale: stage.textScale), maxHeight)
        return PopoverPlacement(left: left, width: width, caretX: M.caretCenter(anchorX: anchorX, left: left, width: width), height: height)
    }

    private func glass(_ shape: StreamCardShape) -> some View {
        PopoverGlass(shape: shape)
    }
}

/// The card and its caret as ONE outline (the prototype's `cardPath`, `caretCardPath` of DELOS for Android): a rounded
/// rectangle with the shared ``CardCaret`` on its bottom edge, centered at [caretX]; or only its rounded body or its caret
/// ([part]: the glass goes in the body, ``CaretCardGlass``). The rect holds the caret in its last ``CardCaret/depth`` stage pixels.
struct StreamCardShape: CaretCard {
    var caretX: CGFloat
    /// Points per stage pixel.
    let unit: CGFloat
    var part = CardPart.whole

    var animatableData: CGFloat {
        get { caretX }
        set { caretX = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let card = CGRect(x: 0, y: 0, width: rect.width, height: max(rect.height - CardCaret.depth * unit, 0))
        return CardCaret.path(part, card: card, radius: StreamMenuLayout.popoverRadius * unit, side: .bottom, center: caretX, unit: unit)
    }
}

/// The page inside the card: the header (the back circle and the title), the rows in a scroller that fades at its edges when
/// it scrolls, and under them the help of the focused row in a box of two lines (three from scale 1.15).
private struct PopoverContent: View {
    let controller: StreamController
    let page: MenuPage
    let content: StreamMenuContent
    /// The card's height, caret excluded.
    let height: Double
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion
    @Namespace private var plate
    @Environment(Layers.self) private var layers: Layers?

    private typealias M = StreamMenuLayout

    var body: some View {
        let menu = controller.menu
        let ts = stage.textScale
        let helpHeight = M.helpHeight(textScale: ts)
        // The rows' area: what is left of the card between the header and the help
        let chrome = M.popoverPaddingY + M.popoverHead + M.popoverGapAfterHead + M.popoverHelpGap + helpHeight + M.popoverPaddingBottom
        let rowsArea = max(height - chrome, 0)
        VStack(alignment: .leading, spacing: 0) {
            header(title: title)
            Spacer().frame(height: stage.px(M.popoverGapAfterHead))
            rowsView(menu: menu, area: rowsArea)
                .frame(height: stage.px(rowsArea), alignment: .top)
            Spacer().frame(height: stage.px(M.popoverHelpGap))
            PageHelp(text: help(menu: menu))
                .frame(height: stage.px(helpHeight), alignment: .topLeading)
        }
        .padding(.horizontal, stage.px(M.popoverPaddingX))
        .padding(.top, stage.px(M.popoverPaddingY))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var title: String {
        switch page {
        case .more: L("stream_menu_title_more")
        case .keys: L("stream_menu_title_keys")
        case .commands: L("stream_menu_title_commands")
        case .brightness: L("stream_menu_title_brightness")
        case .bitrate: L("stream_menu_title_bitrate")
        case .upscaler: controller.upscaler.supersamplingMode ? L("stream_menu_title_supersampling") : L("stream_menu_title_upscaler")
        case .mouse: L("stream_menu_title_mouse")
        case .rumble: L("stream_menu_title_rumble")
        case .main: ""
        }
    }

    /// The help of the focused row (the page's first row before anything is focused).
    private func help(menu: StreamMenuState) -> String {
        let focused = menu.focus.focused?.base as? String
        switch content {
        case .rows(let rows):
            return (rows.first { StreamMenuState.rowID($0.id) == focused } ?? rows.first)?.help ?? ""
        case .pills(let pills, _):
            return (pills.first { StreamMenuState.pillID($0.id) == focused } ?? pills.first)?.help ?? ""
        }
    }

    // MARK: Header

    private func header(title: String) -> some View {
        HStack(spacing: stage.px(20)) {
            FocusItem(id: StreamMenuState.backID, model: controller.menu.focus, clickCue: .back, action: { controller.menuBack() }) { focused in
                BackCircle(focused: focused)
            }
            // Scrolls whenever it does not fit (StreamMenuPopover.kt:337-345)
            MarqueeLabel(text: title, active: true)
                .font(DelosFonts.unbounded(stage.px(M.popoverTitle)))
                .foregroundStyle(colors.text.color)
        }
        .frame(height: stage.px(M.popoverHead))
    }

    // MARK: Rows

    @ViewBuilder private func rowsView(menu: StreamMenuState, area: Double) -> some View {
        switch content {
        case .rows(let rows):
            let overflows = M.rowsHeight(rows.count) > area
            FocusScroll(axis: .vertical, fades: FadeEdges(start: FadeEdge(solid: 26), end: FadeEdge(solid: 64))) {
                VStack(spacing: stage.px(M.rowGap)) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        FocusItem(
                            id: StreamMenuState.rowID(row.id), model: menu.focus, clickCue: row.enabled ? cue(row) : .error,
                            action: { if !menu.swallowsAccept(), row.enabled { row.activate() } },
                            tap: { wasFocused in tapped(row, wasFocused: wasFocused) }
                        ) { focused in
                            PopoverRow(row: row, focused: focused, index: index, plate: plate)
                        }
                        .accessibilityStepper(row.adjustable) { direction in row.adjust(direction) }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("stream-menu")) } action: { menu.rowFrames[row.id] = $0 }
                    }
                }
                .padding(.vertical, stage.px(2))
            }
            .scrollDisabled(!overflows)
        case .pills(let pills, let empty):
            if pills.isEmpty {
                Text(empty ?? "")
                    .font(DelosFonts.figtree(stage.tpx(M.helpSize), .regular))
                    .foregroundStyle(colors.text2.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, stage.px(16))
            } else {
                FocusScroll(axis: .horizontal) {
                    HStack(spacing: stage.px(M.pillGap)) {
                        ForEach(Array(pills.enumerated()), id: \.element.id) { index, pill in
                            FocusItem(
                                id: StreamMenuState.pillID(pill.id), model: menu.focus,
                                action: { if !menu.swallowsAccept() { pill.run() } }
                            ) { focused in
                                PopoverPill(label: pill.label, focused: focused, index: index, plate: plate)
                            }
                        }
                    }
                    .padding(.horizontal, stage.px(4))
                    .padding(.vertical, stage.px(4))
                }
            }
        }
    }

    private func cue(_ row: StreamMenuRow) -> Cue {
        if case .action = row.value { .open } else if case .text = row.value { .open } else { .select }
    }

    /// A tap on a row (StreamMenuPopover.kt:474-482): a choice or slider row's first tap focuses it, the next opens its popup;
    /// a disabled row refuses with the error cue; the others act.
    private func tapped(_ row: StreamMenuRow, wasFocused: Bool) {
        let menu = controller.menu
        switch row.tap(wasFocused: wasFocused) {
        case .refuse:
            layers?.feedback?.play(.error)
        case .focus:
            menu.focus.focus(StreamMenuState.rowID(row.id))
            layers?.feedback?.play(.move)
        case .popup:
            layers?.feedback?.play(.open)
            controller.openPicker(row.id)
        case .activate:
            menu.focus.focus(StreamMenuState.rowID(row.id))
            layers?.feedback?.play(cue(row))
            row.activate()
        }
    }
}

/// The back circle of a popover (`.back`): 64 px, a pale fill, the chevron in the secondary accent; its focus is the gold ring.
private struct BackCircle: View {
    let focused: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion

    var body: some View {
        SymbolView(symbol: Symbols.chevronLeft, size: 36, color: colors.accent2)
            .frame(width: stage.px(StreamMenuLayout.popoverHead), height: stage.px(StreamMenuLayout.popoverHead))
            .background(Circle().fill(.white.opacity(focused ? 0.20 : 0.10)))
            .overlay {
                Circle().strokeBorder(colors.accent.color, lineWidth: stage.px(StreamMenuLayout.rowRing)).opacity(focused ? 1 : 0)
            }
            .focusLift(focused, scale: reducedMotion ? 1 : 1.06)
            .animation(.easeOut(duration: Motion.fade / 1000), value: focused)
            .contentShape(Circle())
            .accessibilityElement()
            .accessibilityLabel(L("stream_menu_hint_back"))
            .accessibilityAddTraits(.isButton)
    }
}

/// The plate of the focused row: the accent at 17 %, a 3 px ring inside and a soft inner glow. One plate glides between the
/// rows of a page (520 ms).
private struct FocusPlate: View {
    let corner: Double?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        if let corner {
            plate(RoundedRectangle(cornerRadius: stage.px(corner), style: .continuous))
        } else {
            plate(Capsule())
        }
    }

    private func plate<S: InsettableShape>(_ shape: S) -> some View {
        shape.fill(colors.accent.opacity(0.17).color)
            .overlay { shape.strokeBorder(colors.accent.color, lineWidth: stage.px(StreamMenuLayout.rowRing)) }
            .overlay {
                shape.inset(by: stage.px(StreamMenuLayout.rowRing))
                    .stroke(colors.accent.opacity(0.22).color, lineWidth: stage.px(14))
                    .blur(radius: stage.px(12))
                    .clipShape(shape.inset(by: stage.px(StreamMenuLayout.rowRing)))
            }
    }
}

/// A row of a popover page (`.row`): 72 px, the icon in a 56 px column, the label, and the value on the right. The page's
/// plate carries its pale gold fill and ring; the icon turns gold and filled. It rises in after the card opens, one after
/// the other, its plate with it (`staggerEntrance()` of the row, places from 0 and no cap, `EntranceStagger` of the page).
private struct PopoverRow: View {
    let row: StreamMenuRow
    let focused: Bool
    let index: Int
    let plate: Namespace.ID
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion

    private typealias M = StreamMenuLayout

    var body: some View {
        HStack(spacing: 0) {
            SymbolView(symbol: row.icon, size: M.rowIcon, color: focused ? colors.accent2 : colors.accent2.opacity(0.62), filled: focused)
                .frame(width: stage.px(M.rowIconColumn))
            Spacer().frame(width: stage.px(M.rowColumnGap))
            // Scrolls while focused when it does not fit (StreamMenuPopover.kt:549-553)
            MarqueeLabel(text: row.label, active: focused)
                .font(DelosFonts.figtree(stage.tpx(M.rowSize), .semibold))
                .foregroundStyle(colors.text.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: stage.px(M.rowColumnGap))
            value
        }
        .padding(.leading, stage.px(M.rowPaddingStart))
        .padding(.trailing, stage.px(M.rowPaddingEnd))
        .frame(height: stage.px(M.rowHeight))
        .background {
            if focused {
                FocusPlate(corner: M.rowRadius)
                    .matchedGeometryEffect(id: "plate", in: plate)
            }
        }
        .animation(reducedMotion ? .easeOut(duration: 0.18) : .timingCurve(0.3, 1.22, 0.42, 1, duration: Motion.rowFocus / 1000), value: focused)
        .opacity(row.enabled ? 1 : 0.45)
        .staggerEntrance(index: index)
        .contentShape(Rectangle())
        // The name and the value (a switch reads On or Off); the focus item makes it a button
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.label)
        .accessibilityValue(row.accessibilityValue)
        .accessibilityHint(row.enabled ? "" : L("settings_screen_unavailable"))
        .accessibilityAddTraits(isToggle ? .isToggle : [])
    }

    private var isToggle: Bool {
        if case .toggle = row.value { true } else { false }
    }

    @ViewBuilder private var value: some View {
        let text = DelosFonts.figtree(stage.tpx(M.rowSize), .medium)
        let chevron = focused ? colors.accent : colors.text3.opacity(0.5)
        if let confirmation = row.confirmation {
            // A check and a word instead of the chevron (StreamMenuPopover.kt:577-580)
            HStack(spacing: stage.px(8)) {
                SymbolView(symbol: Symbols.check, size: 28, color: colors.accent)
                Text(confirmation).font(DelosFonts.figtree(stage.tpx(M.rowSize), .semibold)).foregroundStyle(colors.accent.color).lineLimit(1)
            }
        } else {
            switch row.value {
            case .action:
                SymbolView(symbol: Symbols.chevronRight, size: 28, color: chevron)
            case let .slider(number, range, step, _, _, _):
                HStack(spacing: stage.px(14)) {
                    PopoverSlider(value: number, range: range, focused: focused, step: row.set == nil ? 1 : step, onChange: { row.set?($0) })
                    Text(row.sliderSpec?.label(number) ?? "\(number)")
                        .font(text)
                        .monospacedDigit()
                        .foregroundStyle(colors.text.color)
                        .lineLimit(1)
                        .frame(width: stage.px(M.numberMinWidth * stage.textScale), alignment: .trailing)
                }
            case .toggle(let on):
                PopoverSwitch(on: on)
            case .choice(let label, _, _):
                // ◀ value ▶; a touch on an arrow steps at once (StreamMenuPopover.kt:582-594)
                HStack(spacing: stage.px(14)) {
                    SymbolView(symbol: Symbols.chevronLeft, size: 28, color: chevron)
                        .contentShape(Rectangle())
                        .pressTap { if row.enabled { row.step?(-1) } }
                    // A box of its own width, the value centred in it and scrolling while focused when it does not fit
                    // (StreamMenuPopover.kt:572-581)
                    MarqueeLabel(text: label, active: focused).font(text).foregroundStyle(colors.text2.color)
                        .frame(maxWidth: stage.px(520))
                        .frame(width: stage.px(M.choiceValueMinWidth * stage.textScale))
                    SymbolView(symbol: Symbols.chevronRight, size: 28, color: chevron)
                        .contentShape(Rectangle())
                        .pressTap { if row.enabled { row.step?(1) } }
                }
            case .text(let value):
                HStack(spacing: stage.px(14)) {
                    MarqueeLabel(text: value.isEmpty ? L("stream_menu_not_set") : value, active: focused).font(text).foregroundStyle(colors.text2.color)
                        .frame(maxWidth: stage.px(420), alignment: .trailing)
                    SymbolView(symbol: Symbols.chevronRight, size: 28, color: chevron)
                }
            }
        }
    }
}

/// The on/off switch of a row (`MotionSwitch(on, SWITCH_WIDTH, SWITCH_HEIGHT, white 18 %)` of DELOS for Android's stream menu):
/// 78 × 44, a light veil when off, the main colour into the secondary when on, the knob springing across while the track and
/// the knob's colour fade.
private struct PopoverSwitch: View {
    let on: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion

    var body: some View {
        let width = 78.0, height = 44.0, knob = height - 12
        let fade = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000)
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.18)).opacity(on ? 0 : 1).animation(fade, value: on)
            Capsule().fill(LinearGradient(colors: [colors.accent.color, colors.accent2.color], startPoint: .leading, endPoint: .trailing))
                .opacity(on ? 1 : 0)
                .animation(fade, value: on)
            Circle()
                .fill((on ? colors.onAccent : colors.text2).color)
                .animation(fade, value: on)
                .frame(width: stage.px(knob), height: stage.px(knob))
                .offset(x: stage.px(6 + (on ? width - height : 0)))
                .animation(reducedMotion ? nil : Motion.spring(Motion.focus), value: on)
        }
        .frame(width: stage.px(width), height: stage.px(height))
    }
}

/// The slider of a row (`.sl`): a 240 x 12 track with the accent filling it up to the 32 px knob; the focused row's knob
/// grows to 1.18 inside a soft halo. A touch or a drag sets the value on the slider's grid.
private struct PopoverSlider: View {
    let value: Int
    let range: ClosedRange<Int>
    let focused: Bool
    let step: Int
    let onChange: (Int) -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion
    @State private var dragging: Int?

    private typealias M = StreamMenuLayout

    var body: some View {
        let shown = dragging ?? value
        let fraction = min(max(Double(shown - range.lowerBound) / Double(max(range.upperBound - range.lowerBound, 1)), 0), 1)
        let width = stage.px(M.sliderWidth)
        let knob = stage.px(M.knob) * (focused ? 1.18 : 1)
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.18)).frame(height: stage.px(M.sliderHeight))
            Capsule()
                .fill(LinearGradient(colors: [colors.accent.color, colors.accent2.color], startPoint: .leading, endPoint: .trailing))
                .frame(width: width * fraction, height: stage.px(M.sliderHeight))
            ZStack {
                if focused { Circle().fill(colors.accent3.opacity(0.40).color).frame(width: knob + stage.px(14) * 1.18) }
                Circle().fill(colors.text.color).frame(width: knob)
                    .shadow(color: .black.opacity(0.45), radius: stage.px(6), y: stage.px(4))
            }
            .frame(width: knob)
            .offset(x: width * fraction - knob / 2)
        }
        .frame(width: width, height: stage.px(M.knob + 12))
        .contentShape(Rectangle())
        .animation(dragging == nil && !reducedMotion ? .timingCurve(0.16, 1, 0.3, 1, duration: 0.28) : nil, value: shown)
        .animation(reducedMotion ? nil : Motion.spring(Motion.focus), value: focused)
        #if !os(tvOS)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in dragging = snapped(at: drag.location.x, width: width) }
                .onEnded { drag in
                    onChange(snapped(at: drag.location.x, width: width))
                    dragging = nil
                })
        #endif
    }

    /// The value under the finger, on the slider's grid.
    private func snapped(at x: CGFloat, width: CGFloat) -> Int {
        let raw = Double(range.lowerBound) + Double(range.upperBound - range.lowerBound) * Double(min(max(x / width, 0), 1))
        let snapped = range.lowerBound + Int(((raw - Double(range.lowerBound)) / Double(step)).rounded()) * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}

/// One choice of the Send keys or Commands page: text on a pale capsule; the focused one wears the gliding plate. The
/// choices rise in one after the other from the left (`staggerEntrance()` of the label in `PopoverPills`, places from 0
/// and no cap), the focused one's plate with it.
private struct PopoverPill: View {
    let label: String
    let focused: Bool
    let index: Int
    let plate: Namespace.ID
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion

    var body: some View {
        Text(label)
            .font(DelosFonts.figtree(stage.tpx(StreamMenuLayout.rowSize), .semibold))
            .foregroundStyle(colors.text.color)
            .lineLimit(1)
            .padding(.horizontal, stage.px(26))
            .padding(.vertical, stage.px(14))
            .background(Capsule().fill(.white.opacity(0.10)))
            .background {
                if focused {
                    FocusPlate(corner: nil)
                        .matchedGeometryEffect(id: "plate", in: plate)
                }
            }
            // The plate shows together with its pill, as a row's does (the owner's choice; Android's stays put from the first frame)
            .staggerEntrance(index: index)
            .animation(reducedMotion ? .easeOut(duration: 0.18) : .timingCurve(0.3, 1.22, 0.42, 1, duration: Motion.rowFocus / 1000), value: focused)
            .contentShape(Capsule())
            .accessibilityAddTraits(.isButton)
    }
}

/// The help of the focused row (`.phelp`): it rises 8 px out of nothing when it changes (300 ms); the first one of a page
/// waits 260 ms and takes 400, so it arrives after the rows.
private struct PageHelp: View {
    let text: String
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion
    @State private var shown = false

    var body: some View {
        Text(text)
            .font(DelosFonts.figtree(stage.tpx(StreamMenuLayout.helpSize), .medium))
            .lineSpacing(stage.tpx(StreamMenuLayout.helpSize) * (StreamMenuLayout.helpLineHeight - 1.2))
            .foregroundStyle(colors.text2.color)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(text)
            .transition(reducedMotion ? .opacity : .opacity.combined(with: .offset(y: stage.px(8))))
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.3), value: text)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.4).delay(0.26)) { shown = true }
            }
    }
}
