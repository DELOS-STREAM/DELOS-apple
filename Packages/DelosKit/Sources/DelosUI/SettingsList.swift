import SwiftUI

/// The frames of the rows of a settings list in its content, which the list reads when the focus moves (not observed: they change
/// with every scrolled frame).
@MainActor
final class SettingsRowFrames {
    var frames: [String: CGRect] = [:]
}

extension EnvironmentValues {
    /// Where the rows of a ``settingsListScroll(focus:contains:resetKey:fadeTop:fadeBottom:compact:reveal:)`` list report their frames
    /// in the list's content (see ``View/reportsRowFrame(_:)``).
    @Entry var settingsRowFrames: SettingsRowFrames?
}

extension View {
    /// Reports the frame of the row [id] in the content of the surrounding settings list (the content must be marked with
    /// ``SettingsListScroll/contentSpace``).
    func reportsRowFrame(_ id: String) -> some View { modifier(ReportsRowFrame(id: id)) }

    /// The scrolling of a list of settings rows (`SettingRowList` and `rememberMarginBringIntoView` of DELOS for Android), on the
    /// `ScrollView` that holds them: the focused row is kept clear of the faded edges and only scrolls when it would leave
    /// them, on a critically damped spring (``SettingsScrollMotion``); the top and bottom edges fade only while rows continue
    /// behind them. [contains] says whether an id is one of the list's rows, [resetKey] scrolls it back to the top when it changes
    /// (another tab), [reveal] brings a row into view once its list is laid out (a result of the search).
    func settingsListScroll(
        focus: FocusModel, contains: @escaping (String) -> Bool, resetKey: AnyHashable, fadeTop: Double, fadeBottom: Double,
        compact: Bool, reveal: Binding<String?> = .constant(nil)
    ) -> some View {
        modifier(SettingsListScroll(
            focus: focus, contains: contains, resetKey: resetKey, fadeTop: fadeTop, fadeBottom: fadeBottom, compact: compact, reveal: reveal))
    }
}

private struct ReportsRowFrame: ViewModifier {
    let id: String
    @Environment(\.settingsRowFrames) private var sink

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SettingsListScroll.contentSpace)) } action: { sink?.frames[id] = $0 }
    }
}

struct SettingsListScroll: ViewModifier {
    static let contentSpace = "settings-list-content"

    let focus: FocusModel
    let contains: (String) -> Bool
    let resetKey: AnyHashable
    let fadeTop: Double
    let fadeBottom: Double
    let compact: Bool
    @Binding var reveal: String?
    @State private var position = ScrollPosition(y: 0)
    @State private var glide = ScrollGlide(pace: .list)
    @State private var metrics = SettingsScrollMetrics()
    /// Where the list is scrolling to (nil: at rest): a new focus is judged against it, not against where the spring is now.
    @State private var goal: Double?
    @State private var frames = SettingsRowFrames()
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced

    func body(content: Content) -> some View {
        content
            .scrollGlide(glide, axis: .vertical, position: $position)
            .onScrollGeometryChange(for: SettingsScrollMetrics.self) { geometry in
                SettingsScrollMetrics(offset: geometry.contentOffset.y + geometry.contentInsets.top, viewport: geometry.containerSize.height, content: geometry.contentSize.height)
            } action: { _, now in
                metrics = now
                if let goal, abs(goal - now.offset) < 1 { self.goal = nil }
            }
            .focusable(false)
            .scrollClipDisabled()
            // The top and bottom edges fade only while rows continue behind them, so the first and the last row's plate are
            // never dimmed; the mask reaches to the sides for the plate's glow
            .scrollEdgeFade(.vertical, FadeEdges(start: FadeEdge(solid: fadeTop), end: FadeEdge(solid: fadeBottom)))
            .environment(\.settingsRowFrames, frames)
            .onChange(of: focus.focused) { _, now in
                guard let id = now as? String, contains(id) else { return }
                bringIntoView(id)
            }
            .onChange(of: resetKey) { _, _ in
                goal = nil
                glide.jump(to: 0)
            }
            .task(id: reveal) {
                guard let id = reveal else { return }
                // The rows of the tab are laid out a moment later
                try? await Task.sleep(for: .milliseconds(150))
                bringIntoView(id)
                reveal = nil
            }
    }

    /// Keeps the focused row inside the list with room for the faded edges, only when it would leave it.
    private func bringIntoView(_ id: String) {
        guard let frame = frames.frames[id], metrics.viewport > 0 else { return }
        let scale = stage.scale
        let current = goal ?? metrics.offset
        guard let next = SettingsScrollMotion.target(
            rowTop: frame.minY, rowBottom: frame.maxY, current: current, viewport: metrics.viewport, maxOffset: metrics.maxOffset,
            before: SettingsScrollMotion.before * scale, after: (compact ? SettingsScrollMotion.compactAfter : SettingsScrollMotion.after) * scale)
        else { return }
        goal = next
        if reduced {
            glide.jump(to: next)
        } else {
            // One glide: a new focus while it runs retargets it and keeps its speed
            glide.glide(to: next, unit: scale)
        }
    }
}
