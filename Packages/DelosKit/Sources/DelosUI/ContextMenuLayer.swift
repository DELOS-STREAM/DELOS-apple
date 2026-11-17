import SwiftUI

/// Red of a destructive row and of its plate (the prototype's `--danger`).
private let menuDanger = RGBA(red: 1, green: 0x8F / 255, blue: 0x86 / 255)

/// The glyph color on a [fill]: near black on a light one, white on a dark one (`onColor` of DELOS for Android).
func onColor(_ fill: RGBA) -> RGBA {
    func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    let luminance = 0.2126 * linear(fill.red) + 0.7152 * linear(fill.green) + 0.0722 * linear(fill.blue)
    return luminance > 0.42 ? RGBA(red: 0x14 / 255, green: 0x11 / 255, blue: 0x0A / 255) : RGBA(red: 1, green: 1, blue: 1)
}

/// The context menu (`ContextMenuLayer` of DELOS for Android): an anchored glass card with a caret pointing at the
/// element, a header (an icon tile, a status line, the title), the rows on one gliding plate, and submenus that swap
/// inside the same card. It grows from the caret's tip; ``Layers`` holds what is open and handles the controller.
struct ContextMenuLayer: View {
    let layers: Layers
    let menu: ContextMenu
    /// The element's frame in global points.
    let anchor: CGRect?
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion
    /// The card's size without the caret's room, stage pixels; nil until it is measured.
    @State private var size: CGSize?
    /// Where the layer starts in global points (the anchor is converted to the layer's stage pixels).
    @State private var origin = CGPoint.zero
    @State private var shown = false

    private typealias L = ContextMenuLayout

    // The card keeps clear of the safe area too (on Apple TV the overscan margins, 60 and 90 points)
    private var marginX: Double { (stage.compact ? L.compactMargin : L.marginX) + max(stage.safe.leading, stage.safe.trailing) }
    private var marginY: Double { (stage.compact ? L.compactMargin : L.marginY) + stage.safe.top }
    private var marginBottom: Double { (stage.compact ? L.compactMargin : L.marginY) + stage.safe.bottom }

    private var stageAnchor: CGRect? {
        anchor.map {
            CGRect(x: ($0.minX - origin.x) / stage.scale, y: ($0.minY - origin.y) / stage.scale,
                   width: $0.width / stage.scale, height: $0.height / stage.scale)
        }
    }

    private var placement: MenuPlacement {
        let estimated = CGSize(width: L.minWidth, height: 110 + Double(menu.items.count) * (L.rowHeight + L.rowGap) + 2 * L.padding + 8)
        let card = size ?? estimated
        return placeContextMenu(
            anchor: stageAnchor, w: card.width, h: card.height, below: menu.below, stageW: stage.width, stageH: stage.height,
            marginX: marginX, marginY: marginY, marginBottom: marginBottom, besideWhenCramped: stage.compact)
    }

    var body: some View {
        let place = placement
        let room = L.caretDepth
        // The point the card grows from and shrinks to: the caret's tip, within the card with its room
        let card = size ?? CGSize(width: L.minWidth, height: 200)
        let tip = UnitPoint(x: (place.tipX - place.x + room) / (card.width + 2 * room), y: (place.tipY - place.y + room) / (card.height + 2 * room))
        MenuCard(layers: layers, menu: menu, path: layers.menuPath, maxHeight: L.maxHeight(stageHeight: stage.height, marginY: marginY, marginBottom: marginBottom))
            .padding(stage.px(room))
            .background { CardGlass(side: place.side, caret: place.caret) }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { points in
                size = CGSize(width: points.width / stage.scale - 2 * room, height: points.height / stage.scale - 2 * room)
            }
            .scaleEffect(shown || reducedMotion ? 1 : Motion.popFromScale, anchor: tip)
            .animation(.timingCurve(0.34, 1.56, 0.64, 1, duration: Motion.popIn / 1000), value: shown)
            .opacity(shown ? 1 : 0)
            .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: (reducedMotion ? Motion.fade : Motion.cardFadeIn) / 1000), value: shown)
            .offset(x: stage.px(place.x - room), y: stage.px(place.y - room))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin = $0 }
            .onChange(of: size != nil, initial: true) { _, measured in
                if measured { shown = true }
            }
            .onChange(of: place, initial: true) { _, now in
                layers.menuTip = CGPoint(x: now.tipX / stage.width, y: now.tipY / stage.height)
            }
    }
}

/// The card's glass with its caret: Liquid Glass in the card's outline, a white sheen from the top, a 1 px rim and the
/// soft shadow (`0 40px 90px -20px`).
private struct CardGlass: View {
    let side: CaretSide
    let caret: Double
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        let shape = MenuCardShape(side: side, caret: stage.px(caret), unit: stage.px(1))
        GlassShape(shape, tint: colors.surface3, role: .panel)
            .overlay {
                LinearGradient(stops: [
                    .init(color: .white.opacity(0.13), location: 0),
                    .init(color: .white.opacity(0), location: 0.52),
                ], startPoint: .top, endPoint: .bottom)
                .clipShape(shape)
                .allowsHitTesting(false)
            }
            // The rim is the inside half of a double-width stroke (the outline clips it) and the card's top edge is lit: what the
            // card has and the card moved down 1.5 px has not is a crescent of 26 % white
            .overlay { shape.stroke(.white.opacity(0.11), lineWidth: stage.px(2)).clipShape(shape).allowsHitTesting(false) }
            .overlay {
                shape.fill(.white.opacity(0.26))
                    .mask {
                        shape.fill(.white)
                            .overlay { shape.fill(.black).offset(y: stage.px(1.5)).blendMode(.destinationOut) }
                            .compositingGroup()
                    }
                    .allowsHitTesting(false)
            }
            .background { shape.fill(.black.opacity(0.66)).blur(radius: stage.px(45)).offset(y: stage.px(40)).padding(stage.px(20)) }
            // Taps on the card (between the rows) stay on it; a tap beside it reaches the scrim
            .contentShape(shape)
            .onTapGesture {}
    }
}

/// The card's outline as one shape: a rounded rectangle inside the rect, ``ContextMenuLayout/caretDepth`` in from each
/// side (the caret's room), with the shared ``CardCaret`` on [side] centered at [caret] points along that edge.
struct MenuCardShape: Shape {
    let side: CaretSide
    let caret: CGFloat
    /// Points per stage pixel.
    let unit: CGFloat

    func path(in rect: CGRect) -> Path {
        let d = ContextMenuLayout.caretDepth * unit
        let card = rect.insetBy(dx: d, dy: d)
        let center = side == .left || side == .right ? card.minY + caret : card.minX + caret
        return CardCaret.outline(card: card, radius: ContextMenuLayout.corner * unit, side: side, center: center, unit: unit)
    }
}

/// The card's content: the header and the rows of the menu level [path].
private struct MenuCard: View {
    let layers: Layers
    let menu: ContextMenu
    let path: [Int]
    /// The tallest the card may be (stage pixels); a longer list scrolls.
    let maxHeight: Double
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion

    private typealias L = ContextMenuLayout

    var body: some View {
        let items = MenuPath.items(menu.items, path)
        let parent = MenuPath.parent(menu.items, path)
        let rowsHeight = Double(items.count) * (L.rowHeight + L.rowGap) - L.rowGap + 8
        // As wide as the longest row, between the card's least and greatest width
        CardWidth(min: stage.px(L.minWidth - 2 * L.padding), max: stage.px(L.maxWidth - 2 * L.padding)) {
            VStack(alignment: .leading, spacing: 0) {
                MenuCardHeader(menu: menu, parent: parent, submenu: !path.isEmpty) {
                    layers.back()
                }
                if 2 * L.padding + 130 + rowsHeight > maxHeight {
                    FocusScroll(axis: .vertical, fades: .menu) { rows(items) }.focusable(false)
                        .frame(height: stage.px(maxHeight - 2 * L.padding - 130))
                } else {
                    rows(items)
                }
            }
        }
        .padding(stage.px(L.padding))
        // Switching level is a new card content: its rows rise in again
        .id(path)
        .animation(reducedMotion ? nil : .timingCurve(0.3, 1.22, 0.42, 1, duration: Motion.rowFocus / 1000), value: path)
    }

    private func rows(_ items: [MenuItem]) -> some View {
        let focusedIndex = items.indices.first { layers.focus.focused == Layers.rowID($0) }
        let danger = focusedIndex.map { items[$0].danger } ?? false
        return VStack(alignment: .leading, spacing: stage.px(L.rowGap)) {
            ForEach(items.indices, id: \.self) { index in
                FocusItem(id: Layers.rowID(index), model: layers.focus, action: { if !layers.swallowsAccept() { layers.choose(index) } }) { focused in
                    MenuRow(item: items[index], index: index, focused: focused)
                }
            }
        }
        .padding(.horizontal, stage.px(4))
        .padding(.top, stage.px(6))
        .padding(.bottom, stage.px(2))
        .background(alignment: .topLeading) {
            // The one plate under the focused row: it glides from row to row, red under a destructive one
            if let focusedIndex {
                RowPlate(color: danger ? menuDanger : colors.accent)
                    .frame(height: stage.px(L.rowHeight))
                    .padding(.horizontal, stage.px(4))
                    .offset(y: stage.px(6 + Double(focusedIndex) * (L.rowHeight + L.rowGap)))
                    .animation(reducedMotion ? .easeOut(duration: 0.18) : .timingCurve(0.3, 1.22, 0.42, 1, duration: Motion.rowFocus / 1000), value: focusedIndex)
            }
        }
    }
}

/// The plate of the focused row: the color at 17 %, a 3 px ring and a soft glow around it.
private struct RowPlate: View {
    let color: RGBA
    @Environment(\.stage) private var stage

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: stage.px(ContextMenuLayout.rowRadius), style: .continuous)
        shape.fill(color.opacity(0.17).color)
            .overlay { shape.strokeBorder(color.color, lineWidth: stage.px(ContextMenuLayout.rowRing)) }
            .shadow(color: color.opacity(0.45).color, radius: stage.px(10))
            .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.rowFocus / 1000), value: color)
    }
}

/// A row: icon, label and, for a submenu, a chevron. It rises in after the card opens, one after the other.
private struct MenuRow: View {
    let item: MenuItem
    let index: Int
    let focused: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion
    @State private var appeared = false

    private typealias L = ContextMenuLayout

    var body: some View {
        let iconColor = item.danger ? menuDanger : focused ? colors.accent : colors.text2
        HStack(spacing: stage.px(18)) {
            SymbolView(symbol: item.icon, size: 30, color: iconColor, filled: focused)
            Text(item.label)
                .font(DelosFonts.figtree(stage.tpx(23), .semibold))
                .foregroundStyle((item.danger ? menuDanger : colors.text).color)
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.children != nil { SymbolView(symbol: Symbols.chevronRight, size: 26, color: colors.text3) }
        }
        .padding(.leading, stage.px(24))
        .padding(.trailing, stage.px(22))
        .frame(height: stage.px(L.rowHeight))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: stage.px(L.rowRadius)))
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reducedMotion ? 0 : stage.px(Motion.rise))
        .onAppear {
            let delay = Motion.menuDelay + Double(min(index + 1, Motion.staggerCap)) * Motion.staggerRow
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: Motion.rowIn / 1000).delay(delay / 1000)) { appeared = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The header: a back chip in a submenu or the subject's icon tile, the status line, the title and the line of facts,
/// over a thin divider.
private struct MenuCardHeader: View {
    let menu: ContextMenu
    let parent: MenuItem?
    let submenu: Bool
    let onBack: @MainActor () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(HomeArt.self) private var art
    @Environment(\.matchGameColors) private var matchGameColors
    /// The last color the tile had (the placeholder's, while the cover's is being worked out).
    @State private var held: RGBA?

    /// `gameHeaderTint`: nil while the cover's colors are being worked out.
    private func coverTint(hostID: String, appID: Int, hue: Double) -> RGBA? {
        guard matchGameColors else { return colors.accent }
        let key = GameArt.key(hostID, appID)
        let known = art.coverColors[key] != nil
        let hasCover = known || art.cachedImage(hostID: hostID, appID: appID, kind: .cover) != nil || art.artwork.lookupExpected
        if !hasCover { return hsl(hue, 70, 52) }
        guard known else { return nil }
        guard let cover = art.coverColors[key] ?? nil, let main = cover.hues.first, let saturation = cover.saturations.first else { return colors.accent }
        return hsl(main, saturation * 80, 52)
    }

    var body: some View {
        let eyebrow = submenu ? parent?.label : menu.header?.status
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: stage.px(18)) {
                if submenu {
                    // Touch only (B goes back on a controller): never focused
                    SymbolView(symbol: Symbols.chevronLeft, size: 28, color: colors.text)
                        .frame(width: stage.px(52), height: stage.px(52))
                        .background(Circle().fill(.white.opacity(0.10)))
                        .contentShape(Circle())
                        .onTapGesture(perform: onBack)
                        .accessibilityLabel(L("shell_hint_back"))
                        .accessibilityAddTraits(.isButton)
                        .inputKindVisibility(.withoutController)
                } else if let header = menu.header {
                    tile(header.tint)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if let eyebrow {
                        HStack(spacing: stage.px(8)) {
                            if !submenu, menu.header?.running == true {
                                Circle().fill(RGBA.onlineGreen.color).frame(width: stage.px(10), height: stage.px(10))
                            }
                            Text(eyebrow.uppercased(with: .current))
                                .font(DelosFonts.figtree(stage.tpx(16), .bold))
                                .tracking(stage.tpx(16) * 0.13)
                                .foregroundStyle(colors.text3.color)
                                .lineLimit(1)
                        }
                    }
                    Text(menu.title)
                        .font(DelosFonts.unbounded(stage.tpx(25)))
                        .foregroundStyle(colors.text.color)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, stage.px(eyebrow != nil ? 3 : 0))
                        .padding(.bottom, stage.px(2))
                    if let meta = menu.header?.meta {
                        Text(meta)
                            .font(DelosFonts.figtree(stage.tpx(19), .medium))
                            .foregroundStyle(colors.text2.color)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.leading, stage.px(10))
            .padding(.trailing, stage.px(16))
            .padding(.top, stage.px(8))
            .padding(.bottom, stage.px(14))
            Rectangle().fill(.white.opacity(0.10)).frame(height: stage.px(1)).padding(.bottom, stage.px(4))
        }
        // The header is the first element of the card's entrance (`staggerEntrance(0, Motion.MENU_DELAY)`)
        .staggerEntrance(index: 0, base: Motion.menuDelay)
    }

    /// The subject's tile: its color at 85 % with a faint sheen and a controller in the readable glyph color. A color still
    /// being worked out shows the neutral chip and fades in once; a known one is there from the first frame.
    private func tile(_ tint: HeaderTint) -> some View {
        let known: RGBA? = switch tint {
        case .accent: colors.accent
        case .color(let color): color
        case .cover(let hostID, let appID, let hue): coverTint(hostID: hostID, appID: appID, hue: hue)
        }
        // A cover that arrives while the menu is open keeps the placeholder's color until its own is worked out
        let fill = known ?? held ?? RGBA(red: 1, green: 1, blue: 1, alpha: 0.1 / 0.85)
        let shape = RoundedRectangle(cornerRadius: stage.px(14), style: .continuous)
        let glyph = known == nil && held == nil ? colors.text : onColor(fill)
        return SymbolView(symbol: Symbols.sportsEsports, size: 34, color: glyph, filled: true)
            .frame(width: stage.px(52), height: stage.px(78))
            .background {
                shape.fill(fill.opacity(0.85).color)
                    .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000), value: fill)
                    .overlay {
                        LinearGradient(stops: [.init(color: .white.opacity(0.22), location: 0), .init(color: .white.opacity(0), location: 0.6)],
                                       startPoint: .top, endPoint: .bottom).clipShape(shape)
                    }
                    .overlay { shape.strokeBorder(.white.opacity(0.16), lineWidth: stage.px(1)) }
            }
            .onChange(of: known, initial: true) { _, now in if let now { held = now } }
    }
}

/// Gives its content its ideal width kept between [min] and [max], and the height that has at that width: the card is as
/// wide as its longest row, and a longer row is cut at the greatest width.
private struct CardWidth: Layout {
    let min: CGFloat
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = Swift.min(Swift.max(content.sizeThatFits(.unspecified).width, min), max)
        return CGSize(width: width, height: content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
