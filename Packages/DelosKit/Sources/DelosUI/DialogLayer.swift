import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A dialog in the middle of the screen (`DialogLayer` of DELOS for Android): title, note, its fields and the confirm
/// button with Cancel. The focus stays inside while it is open and starts on the first field (on the confirm button
/// when there is none). A on a field or a tap starts typing; Return in the last field confirms. While the system
/// keyboard is up, the card moves above it.
struct DialogLayer: View {
    let layers: Layers
    let spec: DialogSpec
    let navigator: Navigator
    @State private var values: [String]
    /// The field being typed in.
    @State private var typing: Int?
    /// The card's size and the layer's frame (global points): where the card sits before it moves above the keyboard.
    @State private var cardSize = CGSize.zero
    @State private var layerFrame = CGRect.zero
    @State private var keyboardTop: CGFloat?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    init(layers: Layers, spec: DialogSpec, navigator: Navigator) {
        self.layers = layers
        self.spec = spec
        self.navigator = navigator
        _values = State(initialValue: spec.fields.map(\.initial))
    }

    static func fieldID(_ index: Int) -> AnyHashable { AnyHashable("dialog-field-\(index)") }
    static let confirmID: AnyHashable = "dialog-confirm"
    static let cancelID: AnyHashable = "dialog-cancel"

    /// Where the focus starts: the first field, or the confirm button of a dialog without fields (a question).
    static func firstFocus(_ spec: DialogSpec) -> AnyHashable { spec.fields.isEmpty ? confirmID : fieldID(0) }

    private var width: Double { stage.compact ? min(760, stage.width - 2 * 48) : 760 }
    private var padding: Double { stage.compact ? 36 : 52 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: stage.px(40), style: .continuous)
        VStack(spacing: stage.px(22)) {
            Text(spec.title)
                .font(DelosFonts.unbounded(stage.tpx(38)))
                .foregroundStyle(colors.text.color)
            Text(spec.note)
                .font(DelosFonts.figtree(stage.tpx(24)))
                .lineSpacing(stage.px(24 * 0.4))
                .foregroundStyle(colors.text2.color)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(spec.fields.indices, id: \.self) { index in
                DialogFieldView(
                    field: spec.fields[index], value: $values[index], index: index, typing: $typing, focus: layers.focus,
                    width: width - 2 * padding
                ) {
                    if index == spec.fields.count - 1 { confirm() } else { layers.focus.focus(Self.fieldID(index + 1)) }
                }
            }
            HStack(spacing: stage.px(stage.compact ? 20 : 24)) {
                FocusItem(id: Self.confirmID, model: layers.focus, action: confirm) { focused in
                    PillButton(label: spec.confirm, icon: Symbols.check, primary: true, focused: focused)
                }
                FocusItem(id: Self.cancelID, model: layers.focus, clickCue: .back, action: layers.back) { focused in
                    PillButton(label: L("common_cancel"), focused: focused)
                }
            }
            .padding(.top, stage.px(8))
        }
        .multilineTextAlignment(.center)
        .padding(stage.px(padding))
        .frame(width: stage.px(width))
        .background {
            GlassShape(shape, tint: colors.surface3, role: .panel)
                .overlay(shape.strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                // box-shadow: 0 40px 100px -30px rgba(0, 0, 0, .7)
                .background { shape.fill(.black.opacity(0.7)).padding(stage.px(30)).blur(radius: stage.px(50)).offset(y: stage.px(40)) }
                // A tap on the card stays on it; a tap beside it reaches the scrim
                .contentShape(shape)
                .onTapGesture {}
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
        .offset(y: lift)
        .animation(.easeOut(duration: 0.25), value: keyboardTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { layerFrame = $0 }
        .onChange(of: typing != nil) { _, now in navigator.textEditing(now) }
        .onChange(of: navigator.isEditingText) { _, now in if !now { typing = nil } }
        .onDisappear { if typing != nil { navigator.isEditingText = false } }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardTop = frame.minY
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardTop = nil }
        #endif
    }

    /// How far the card moves up so its bottom stays 24 stage pixels above the keyboard, but its top not above the top
    /// margin of 48 (`moveAboveIme` of DELOS for Android).
    private var lift: CGFloat {
        guard let keyboardTop, cardSize.height > 0 else { return 0 }
        let top = layerFrame.midY - cardSize.height / 2
        let overlap = top + cardSize.height + stage.px(24) - keyboardTop
        guard overlap > 0 else { return 0 }
        return -min(overlap, max(0, top - stage.px(48 + stage.safe.top)))
    }

    /// Save: the dialog closes when its handler accepts the values.
    private func confirm() {
        typing = nil
        navigator.isEditingText = false
        let cleaned = zip(values, spec.fields).map { String($0.prefix($1.maxLength)) }
        if spec.onConfirm(cleaned) { layers.close() }
    }
}

/// One field of a dialog: the shared text pill, filling the dialog's width. A on it starts typing.
private struct DialogFieldView: View {
    let field: DialogField
    @Binding var value: String
    let index: Int
    @Binding var typing: Int?
    let focus: FocusModel
    let width: Double
    let onSubmit: () -> Void
    @FocusState private var editing: Bool

    var body: some View {
        #if os(tvOS)
        // The text field takes the focus itself and opens the system keyboard when it is selected; a focus item around it
        // would take the select instead
        TextPill(
            label: nil, icon: field.icon, placeholder: field.placeholder, text: $value, editing: $editing, focused: false,
            secret: field.secret, width: width, onSubmit: onSubmit
        )
        .multilineTextAlignment(.leading)
        .onChange(of: editing) { _, now in if now { focus.focus(DialogLayer.fieldID(index)) } }
        .onChange(of: value) { _, now in
            if now.count > field.maxLength { value = String(now.prefix(field.maxLength)) }
        }
        #else
        item
        #endif
    }

    #if !os(tvOS)
    private var item: some View {
        FocusItem(id: DialogLayer.fieldID(index), model: focus, action: { typing = index }) { focused in
            TextPill(
                label: nil, icon: field.icon, placeholder: field.placeholder, text: $value, editing: $editing, focused: focused,
                secret: field.secret, width: width, onSubmit: onSubmit
            )
            // The note above is centered; the value reads from the start of the field
            .multilineTextAlignment(.leading)
        }
        .onChange(of: typing) { _, now in editing = now == index }
        .onChange(of: editing) { _, now in
            if now {
                focus.focus(DialogLayer.fieldID(index))
                typing = index
            } else if typing == index {
                typing = nil
            }
        }
        .onChange(of: value) { _, now in
            if now.count > field.maxLength { value = String(now.prefix(field.maxLength)) }
        }
    }
    #endif
}
