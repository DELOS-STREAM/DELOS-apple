import DelosData
import DelosHost
import SwiftUI

/// The game focused in the library as the companion shows it (`CompanionGame`, CompanionState.kt:70-95 of DELOS for
/// Android). Equal by what it shows; [onAction] runs the controller's own paths.
struct CompanionGame: Hashable {
    /// "host/app", the key of the focused game.
    let key: String
    let name: String
    let running: Bool
    /// Another game that runs on the PC, nil when none or when this one runs.
    let otherRunning: String?
    /// The game's background, else nil (the placeholder's hues are used).
    let image: CGImage?
    let hue: Double
    let hue2: Double
    let summary: String?
    let genres: [String]
    let completionSeconds: Int64?
    let hdr: NativeHDR?
    /// What the game's effective stream settings cost, nil while unknown.
    let impact: SettingImpact?
    let pcName: String?
    let onAction: @MainActor (ShellButton) -> Void

    var buttons: [ShellButton] { ShellButton.buttons(running: running, otherRunning: otherRunning != nil) }

    static func == (a: CompanionGame, b: CompanionGame) -> Bool {
        a.key == b.key && a.name == b.name && a.running == b.running && a.otherRunning == b.otherRunning
            && a.image.map(ObjectIdentifier.init) == b.image.map(ObjectIdentifier.init) && a.hue == b.hue && a.hue2 == b.hue2
            && a.summary == b.summary && a.genres == b.genres && a.completionSeconds == b.completionSeconds && a.hdr == b.hdr
            && a.impact == b.impact && a.pcName == b.pcName
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(running)
        hasher.combine(otherRunning)
    }
}

/// The game card (`GamePage`, CompanionShellContent.kt): the heading, the banner (the game's image or its placeholder
/// colors, with its name on it) taking the height the other blocks leave, the genre chips, one muted line, the three
/// impact chips and the buttons. What does not fit is cut by ``GameFit``; ``FitColumn`` drops the optional lines before
/// anything would overflow.
enum GamePage {
    static func page(_ game: CompanionGame) -> CompanionPage {
        CompanionPage(key: "game/\(game.key)", priority: PagePriority.game, revision: game) { GameCard(game: game) }
    }
}

private struct GameCard: View {
    let game: CompanionGame
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    /// The banner's least height in stage pixels: below it the page drops its optional lines first.
    static let bannerMin = 120.0

    var body: some View {
        PageCard { fit in
            let b = fit.budget
            let state = game.running ? L("companion_game_running") : L("companion_game_focused")
            let pc = game.pcName.flatMap { $0.isEmpty ? nil : $0 }
            // The name in the display face when it fits one line; else the state is the title and the PC the line under it
            let title = CompanionFit.title(game.name, alias: state, width: b.innerWidth - PageHeading.chrome, metrics: fit.metrics)
            PageHeading(
                icon: Symbols.playArrow, title: title,
                subtitle: title == game.name ? [state, pc].compactMap { $0 }.joined(separator: " \u{00B7} ") : pc)
            GameBanner(game: game).fills(minHeight: stage.px(Self.bannerMin))
            let facts = [
                game.completionSeconds.map { L("home_chip_hltb", TagLook.completionText(CompletionLength(seconds: $0))) },
                game.hdr.map { hdr -> String in
                    switch hdr {
                    case .hdr: L("companion_hdr_native")
                    case .sdr: "SDR"
                    case .unknown: L("metadata_hdr_unverified")
                    }
                },
            ].compactMap { $0 }.joined(separator: " \u{00B7} ")
            let text = GameFit.text(genres: game.genres, summary: game.summary, facts: facts, budget: b, metrics: fit.metrics) {
                LPlural("companion_genres_more", $0)
            }
            if !text.genres.isEmpty { ChipRow(labels: text.genres).optional(50) }
            let running = game.otherRunning.map { L("companion_host_running", $0) }.flatMap { fit.metrics.lines($0, width: b.innerWidth) <= 1 ? $0 : nil }
            if let running {
                BodyText(running, color: colors.accent2).optional(60)
            } else if let body = text.body {
                BodyText(body, color: colors.text2, maxLines: GameFit.proseLines).optional(40)
            }
            CompanionImpactChips(impact: game.impact)
            WrappingActionRow(actions: game.buttons.enumerated().map { index, button in
                PageAction(label: Self.label(button), style: Self.style(button, first: index == 0)) { game.onAction(button) }
            })
        }
    }

    static func label(_ button: ShellButton) -> String {
        switch button {
        case .start: L("home_menu_start")
        case .resume: L("home_menu_resume")
        case .resumeOther: L("companion_game_resume_other")
        case .quitAndStart: L("companion_game_quit_start")
        case .gameSettings: L("home_menu_settings")
        }
    }

    static func style(_ button: ShellButton, first: Bool) -> CompanionButtonStyle {
        if first { return .primary }
        switch button {
        case .quitAndStart: return .danger
        case .gameSettings: return .normal
        default: return .secondary
        }
    }
}

/// The banner: the game's art (else its placeholder colors) under a scrim, and its name in the display face, as large as
/// the banner allows.
private struct GameBanner: View {
    let game: CompanionGame
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    static let inset = 28.0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: stage.px(28), style: .continuous)
        GeometryReader { proxy in
            let width = (proxy.size.width / stage.scale - 2 * Self.inset) / stage.textScale
            let height = (proxy.size.height / stage.scale - 2 * Self.inset) / stage.textScale
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [hsl(game.hue, 45, 22).color, hsl(game.hue2, 55, 12).color], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image = game.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
                // Legibility: the bottom fades into the page color
                LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.45), .init(color: colors.bg.opacity(0.92).color, location: 1)],
                    startPoint: .top, endPoint: .bottom)
                Text(verbatim: game.name)
                    .font(DelosFonts.unbounded(stage.tpx(GameFit.nameSize(game.name, width: width, height: height)), .bold))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(2)
                    .padding(.horizontal, stage.px(Self.inset))
                    .padding(.vertical, stage.px(Self.inset * 0.75))
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(colors.line.color, lineWidth: stage.px(1)))
    }
}

/// What a game costs in one summary (`gameImpact`, CompanionLogic.kt:184-194): on each axis the highest level any of its
/// effective stream settings has (the settings rows' own chips). Never a measurement.
@MainActor
func gameImpact(_ settings: StreamSettings) -> SettingImpact? {
    let context = StreamSettingsForm(settings: settings, device: .current).impactContext
    let all = [
        StreamSettingsForm.resolution, StreamSettingsForm.frameRate, StreamSettingsForm.bitrate, StreamSettingsForm.codec, StreamSettingsForm.hdr,
        StreamSettingsForm.framePacing, SettingKey.upscaler.rawValue, SettingKey.upscalerMode.rawValue, SettingKey.upscalerSharpness.rawValue,
        SettingKey.upscalerSupersampling.rawValue,
    ].compactMap { settingImpact(id: $0, context: context) }
    guard !all.isEmpty else { return nil }
    func top(_ level: (SettingImpact) -> ImpactLevel) -> ImpactLevel { all.map(level).max { $0.rawValue < $1.rawValue } ?? .none }
    return SettingImpact(gpu: top(\.gpu), latency: top(\.latency), network: top(\.network))
}

extension View {
    /// Publishes the game focused in the library to the companion (`PublishCompanionGame`, CompanionPublisher.kt:38-100),
    /// live: a focus move, new metadata or art and a change of what runs on the PC make a new card. Its buttons run the
    /// controller's paths: Start and Resume (``ShellActions/play(hostID:app:)``), Quit and start, the game's settings.
    func companionGame(hostID: String, app: HostApp, running: HostApp?, actions: ShellActions, art: HomeArt, metadata: GameMetadataModel) -> some View {
        companionPage {
            let host = actions.hosts.host(hostID)
            let data = metadata.data(for: app)
            let genres = (GameTags.topGenres(data?.candidate?.genres.filter { !$0.name.isEmpty } ?? [], steamTags: data?.steamTags ?? [], limit: 6)
                .map(TagLook.genreName)
                + GameTags.topThemes(data?.candidate?.themes.filter { !$0.name.isEmpty } ?? [], steamTags: data?.steamTags ?? [], limit: 4)
                .map(TagLook.themeName))
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let placeholder = GameArt(hostID: hostID, app: app)
            let hero = art.hero?.id == placeholder.id ? art.hero?.image : nil
            let other = running.flatMap { $0.id == app.id ? nil : $0 }
            let game = CompanionGame(
                key: placeholder.id, name: app.title, running: running?.id == app.id, otherRunning: other?.title, image: hero,
                hue: placeholder.hue, hue2: placeholder.hue2, summary: data?.candidate?.summary, genres: genres,
                completionSeconds: data?.completionSeconds, hdr: data?.hdrBadge,
                impact: gameImpact(actions.streamSettings(hostID: hostID, appID: app.id)), pcName: host?.name
            ) { [actions] button in
                switch button {
                case .start, .resume: actions.play(hostID: hostID, app: app)
                case .resumeOther: if let other { actions.play(hostID: hostID, app: other) }
                case .quitAndStart: if let other { actions.quitAndStart(hostID: hostID, running: other, app: app) }
                case .gameSettings: actions.openAppSettings(hostID: hostID, app: app)
                }
            }
            return GamePage.page(game)
        }
    }
}
