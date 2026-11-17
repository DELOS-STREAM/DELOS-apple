import DelosInput
import SwiftUI

/// The recording of the stream menu's buttons (`ButtonCaptureLayer` of DELOS for Android): over the scrim a card with the
/// controller symbol, "Press the stream menu buttons", how it works, and the buttons pressed so far as accent chips. A tap
/// anywhere ends it unchanged.
struct ButtonCaptureLayer: View {
    let capture: MenuButtonCapture
    let onTap: @MainActor () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    /// Android's `fadeIn(tween(250))` and `fadeOut(tween(250))`: 250 ms with Compose's default `FastOutSlowInEasing`.
    static let fade = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.25)

    var body: some View {
        ZStack {
            colors.scrim.color.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
            VStack(spacing: stage.px(26)) {
                SymbolView(symbol: Symbols.sportsEsports, size: 72, color: colors.accent, filled: true)
                Text(L("shell_button_capture_title"))
                    .font(DelosFonts.unbounded(stage.tpx(36), .semibold))
                    .foregroundStyle(colors.text.color)
                    .multilineTextAlignment(.center)
                Text(L("shell_button_capture_note"))
                    .font(DelosFonts.figtree(stage.tpx(24)))
                    .foregroundStyle(colors.text2.color)
                    .lineSpacing(stage.tpx(24) * 0.4)
                    .multilineTextAlignment(.center)
                HStack(spacing: stage.px(14)) {
                    ForEach(capture.combination, id: \.self) { button in
                        Text(StreamMenuButtonsText.name(button))
                            .font(DelosFonts.figtree(stage.tpx(26), .bold))
                            .foregroundStyle(colors.onAccent.color)
                            .padding(.horizontal, stage.px(26))
                            .padding(.vertical, stage.px(12))
                            .background(Capsule().fill(colors.accent.color))
                    }
                }
                .frame(height: stage.px(64))
            }
            .padding(stage.px(52))
            .frame(width: stage.px(820))
            .background(RoundedRectangle(cornerRadius: stage.px(40)).fill(colors.surface3.color))
            .overlay(RoundedRectangle(cornerRadius: stage.px(40)).strokeBorder(colors.line.color, lineWidth: stage.px(1)))
            .clipShape(RoundedRectangle(cornerRadius: stage.px(40)))
            // A tap on the card cancels too (Android's tap handler covers the whole layer)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
    }
}

/// The names of the stream menu's buttons (`StreamMenuSettings.label` and `buttonName` of DELOS for Android): a pad's own
/// legends (the letters; L1, R1, L2, R2, L3 and R3 as printed; P1 to P4 on the paddles), Start, Select and Home as words.
enum StreamMenuButtonsText {
    /// "L3 + R3", "Start + Select", …
    static func label(_ buttons: Set<ShortcutButton>) -> String {
        buttons.sorted().map(name).joined(separator: " + ")
    }

    static func name(_ button: ShortcutButton) -> String {
        switch button {
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .l1: "L1"
        case .r1: "R1"
        case .l2: "L2"
        case .r2: "R2"
        case .l3: "L3"
        case .r3: "R3"
        case .start: L("stream_menu_button_start")
        case .select: L("stream_menu_button_select")
        case .home: L("stream_menu_button_home")
        case .paddle1: "P1"
        case .paddle2: "P2"
        case .paddle3: "P3"
        case .paddle4: "P4"
        // Android names a button without a legend by its platform constant (a technical readout): Share is
        // KEYCODE_MEDIA_RECORD there
        case .share: "Media record"
        // A keyboard's key the same way: "Ctrl left", "Escape", "F5"
        case .key(let usage): ShortcutButton.keyName(usage)
        }
    }
}
