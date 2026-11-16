import DelosData
import DelosHost
import ImageIO
import SwiftUI

/// What the library of a PC shows (`Library` of DELOS for Android, for one PC).
enum HomeContent: Equatable {
    /// The apps are being asked for the first time.
    case loading
    case offline
    case empty
    case apps([HostApp])

    /// [apps]: the list as last loaded (nil: never); [loadFailed]: the last attempt to load it failed.
    init(apps: [HostApp]?, loadFailed: Bool) {
        if let apps, !loadFailed {
            self = apps.isEmpty ? .empty : .apps(apps)
        } else if loadFailed {
            self = .offline
        } else {
            self = .loading
        }
    }
}

/// The library of a paired PC (`HomeScreen` of DELOS for Android), a first version: the row of covers (the PC's box
/// art, the first one three covers wide), the focused app's title above it; A starts the app. The PC is asked again
/// and its apps loaded when the screen shows.
struct HomeScreen: View {
    let hostID: String
    let focus: FocusModel
    let onApp: @MainActor (HostApp) -> Void
    @Environment(HostStore.self) private var hosts
    @Environment(\.stage) private var stage
    @State private var loadFailed = false

    /// The focus the screen opens with: no item has it, so the covers, once loaded, give it to the first one.
    static let initialFocus = "first-app"

    var body: some View {
        let name = hosts.host(hostID)?.name ?? ""
        Group {
            switch HomeContent(apps: hosts.apps[hostID], loadFailed: loadFailed) {
            case .loading: HomeMessage(icon: Symbols.loading, title: L("home_loading"), text: nil)
            case .offline: HomeMessage(icon: Symbols.wifiOff, title: L("home_offline_title", name), text: nil)
            case .empty: HomeMessage(icon: Symbols.sportsEsports, title: L("home_empty_title", name), text: L("home_empty_note"))
            case .apps(let apps): AppRow(hostID: hostID, apps: apps, focus: focus, onApp: onApp)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: hostID) {
            await hosts.refresh(hostID)
            do {
                try await hosts.loadApps(hostID)
                loadFailed = false
            } catch {
                loadFailed = true
            }
        }
    }
}

/// The row of covers, 150 stage pixels from the left and 70 above the bottom; the focused cover's title above it. The
/// focused cover stays where the first one starts (Android keeps it at the left edge too).
private struct AppRow: View {
    let hostID: String
    let apps: [HostApp]
    let focus: FocusModel
    let onApp: @MainActor (HostApp) -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @State private var position = ScrollPosition(edge: .leading)

    static let tile = 300.0, height = 450.0, gap = 44.0
    /// The wide first cover: three covers and the two gaps between them.
    static let wide = 3 * tile + 2 * gap

    /// Where cover [index] starts in the row, stage pixels from the first one.
    static func itemStart(_ index: Int) -> Double {
        index == 0 ? 0 : wide + gap + Double(index - 1) * (tile + gap)
    }

    var body: some View {
        let focusedIndex = apps.firstIndex { focus.focused == AnyHashable(Self.id($0)) }
        VStack(alignment: .leading, spacing: stage.px(40)) {
            Spacer()
            Text(apps[focusedIndex ?? 0].title)
                .font(DelosFonts.unbounded(stage.px(64)))
                .foregroundStyle(colors.text.color)
                .lineLimit(1)
                .padding(.leading, stage.px(150 + stage.safe.leading))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: stage.px(Self.gap)) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        FocusItem(id: Self.id(app), model: focus, action: { onApp(app) }) { focused in
                            Cover(hostID: hostID, app: app, wide: index == 0, focused: focused)
                        }
                    }
                }
                .padding(.horizontal, stage.px(150 + stage.safe.leading))
                .padding(.vertical, stage.px(40))
            }
            .scrollClipDisabled()
            .scrollPosition($position)
            .onChange(of: focusedIndex) { _, now in
                guard let now else { return }
                withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(x: stage.px(Self.itemStart(now))) }
            }
        }
        .padding(.bottom, stage.px(70 + stage.safe.bottom))
        // The first cover takes the focus, before the covers register (the model would take whichever comes first)
        .onAppear { if focusedIndex == nil { focus.focus(Self.id(apps[0])) } }
    }

    static func id(_ app: HostApp) -> String { "app-\(app.id)" }
}

/// A cover: the PC's box art, or the title on a plain card until it is loaded (or when the PC has none).
private struct Cover: View {
    let hostID: String
    let app: HostApp
    let wide: Bool
    let focused: Bool
    @Environment(HostStore.self) private var hosts
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @State private var art: CGImage?

    var body: some View {
        let width = wide ? AppRow.wide : AppRow.tile
        let shape = RoundedRectangle(cornerRadius: stage.px(26))
        ZStack {
            shape.fill(colors.surface2.color)
            if let art {
                Image(decorative: art, scale: 1).resizable().scaledToFill()
            } else {
                Text(app.title)
                    .font(DelosFonts.figtree(stage.px(30), .semibold))
                    .foregroundStyle(colors.text2.color)
                    .multilineTextAlignment(.center)
                    .padding(stage.px(24))
            }
        }
        .frame(width: stage.px(width), height: stage.px(AppRow.height))
        .clipShape(shape)
        .overlay(shape.strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        .focusLook(focused, scale: 1.08, ring: 5, glowBlur: 50, glowY: 18, corner: 26)
        .task(id: app.id) { await load() }
    }

    private func load() async {
        guard art == nil, let (client, _, pin) = try? hosts.pairedClient(hostID),
              let data = try? await client.appAsset(appID: app.id, pin: pin),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return }
        art = CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// A centered message for the loading, offline and empty states.
private struct HomeMessage: View {
    let icon: String
    let title: String
    let text: String?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        VStack(spacing: stage.px(22)) {
            SymbolView(symbol: icon, size: 110, color: colors.accent, filled: true)
            Text(title)
                .font(DelosFonts.unbounded(stage.px(52)))
                .foregroundStyle(colors.text.color)
            if let text {
                Text(text)
                    .font(DelosFonts.figtree(stage.px(26)))
                    .foregroundStyle(colors.text2.color)
            }
        }
        .multilineTextAlignment(.center)
    }
}
