import DelosInput
import SwiftUI

/// One tab of a ``TabRow``: its icon, its label and, on the per-app settings, how many of its settings the app overrides.
struct TabSpec<ID: Hashable>: Identifiable {
    let id: ID
    let icon: String
    let label: String
    var badge = 0
}

/// The tabs between the L1 and R1 badges (`TabPill` in a `TabRow` of DELOS for Android) of Settings and of the per-app settings,
/// placed by ``TabRowLayout``. On the controller they are never focused: L1 and R1 switch them; a tap selects one and squeezes
/// it. On tvOS the Siri Remote has no L1 and R1, so each tab is also an item of the screen's focus (up from the first row):
/// select picks it. The selected one sits on the accent pill (``SelectionPillHost``), which glides to the next.
struct TabRow<ID: Hashable>: View {
    let tabs: [TabSpec<ID>]
    let selected: ID
    let focus: FocusModel
    /// The focus id of a tab (tvOS).
    let focusID: (ID) -> String
    /// Only the selected tab keeps its label, so the whole row stays on a narrow stage (``SettingsLayout/fullTabsMinWidth``).
    var collapse = false
    /// The content's edges in stage px (what a title or a button beside the row leaves): see ``TabRowLayout``.
    var left = SettingsLayout.titleX
    var right = Stage.designWidth - SettingsLayout.titleX
    /// Exactly centred on the stage, or (false) flush with [right] (the artwork screen's).
    var centred = true
    let onSelect: (ID) -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion
    /// The row's natural width in points.
    @State private var natural = 0.0

    private var row: some View {
        SelectionPillHost(selected: AnyHashable(selected)) {
            HStack(spacing: 0) {
                ShoulderLabel(role: .leftShoulder)
                ForEach(tabs) { tab in
                    tabView(tab)
                }
                ShoulderLabel(role: .rightShoulder)
            }
        }
        .fixedSize()
        .onGeometryChange(for: Double.self) { $0.size.width } action: { natural = $0 }
    }

    var body: some View {
        // Exactly centred on the stage, or flush with the right edge; a row wider than the room between the edges scrolls in it
        let placement = TabRowLayout.place(
            stageWidth: stage.width, rowWidth: natural / stage.scale, outset: ShoulderLabel.outset, left: left, right: right, centred: centred, spill: !stage.compact)
        ZStack(alignment: .topLeading) {
            if placement.scrolls {
                // Fading at the edge that has more tabs behind it (`tabScroll`)
                ScrollView(.horizontal, showsIndicators: false) { row }
                    .scrollEdgeFade(.horizontal, .tabs)
                    .frame(width: stage.px(placement.width))
                    .offset(x: stage.px(placement.x))
            } else {
                row.offset(x: stage.px(placement.x))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .opacity(natural > 0 ? 1 : 0)
    }

    @ViewBuilder private func tabView(_ tab: TabSpec<ID>) -> some View {
        #if os(tvOS)
        FocusItem(id: focusID(tab.id), model: focus, action: { onSelect(tab.id) }) { focused in
            pillView(tab)
                .focusLook(focused, scale: 1.06, ring: 3, glowBlur: 0, glowY: 0)
        }
        .padding(.horizontal, stage.cpx(stage.compact ? 3 : 5))
        #else
        Button { onSelect(tab.id) } label: {
            pillView(tab).contentShape(Capsule())
        }
        .buttonStyle(TabPressStyle(reduced: reduceMotion))
        .focusable(false)
        .padding(.horizontal, stage.cpx(stage.compact ? 3 : 5))
        #endif
    }

    private func pillView(_ tab: TabSpec<ID>) -> some View {
        let on = tab.id == selected
        // The content fades between the quiet and the dark color over Motion.FADE (CSS ease); reduced motion jumps
        let fade: Animation? = reduceMotion ? nil : .timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000)
        return HStack(spacing: stage.px(12)) {
            SymbolView(symbol: tab.icon, size: 30, color: on ? colors.onAccent : colors.text2, filled: on)
            if on || !collapse {
                Text(tab.label)
                    .font(DelosFonts.figtree(stage.tpx(22), .semibold))
                    .foregroundStyle((on ? colors.onAccent : colors.text2).color)
                    .lineLimit(1)
            }
            // The count of this tab's custom per-app settings: a quiet accent3 pill, dark on the selected tab's accent pill
            if tab.badge > 0 {
                Text("\(tab.badge)")
                    .font(DelosFonts.figtree(stage.tpx(16), .bold))
                    .foregroundStyle((on ? colors.onAccent : colors.accent3).color)
                    .padding(.horizontal, stage.px(9))
                    .padding(.vertical, stage.px(2))
                    .background(Capsule().fill((on ? colors.onAccent.opacity(0.16) : colors.accent3.opacity(0.22)).color))
            }
        }
        .animation(fade, value: on)
        .padding(.horizontal, stage.cpx(collapse && !on ? 16 : 22))
        .frame(height: stage.targetPx(66))
        .selectionPillTarget(tab.id)
        .accessibilityElement()
        .accessibilityLabel(tab.label)
        .accessibilityValue(tab.badge > 0 ? "\(tab.badge)" : "")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// A tap squeezes the tab for a moment (`rememberPressPulse`, ``Motion/pressScale``).
private struct TabPressStyle: ButtonStyle {
    let reduced: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Motion.pressScale : 1)
            .animation(.focusScale(pressed: configuration.isPressed, reduced: reduced), value: configuration.isPressed)
    }
}

/// The previous / next tab hint beside a row of tabs (the connected controller's L1 / R1, LB / RB, L / R); its border sits ``outset`` inside the room it takes (`ShoulderLabel`).
struct ShoulderLabel: View {
    /// The room outside the border: the visible ends of a tab row sit this far inside the row (stage px, `SHOULDER_OUTSET`).
    static let outset = 10.0
    let role: GlyphRole
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        Text(ControllerGlyphs.shared.mark(role).text ?? "")
            .font(DelosFonts.figtree(stage.tpx(18), .bold))
            .foregroundStyle(colors.text3.color)
            .padding(.horizontal, stage.px(12))
            .padding(.vertical, stage.px(6))
            .overlay(RoundedRectangle(cornerRadius: stage.px(10)).strokeBorder(colors.line.color, lineWidth: stage.px(1)))
            .padding(.horizontal, stage.px(Self.outset))
    }
}
