import DelosData
import DelosInput
import SwiftUI

/*
 * The settings help on the companion screen (`CompanionHelp.kt`, `CompanionHelpContent.kt` and `HelpFit` in
 * `CompanionPageFit.kt` of DELOS for Android, docs/DUAL_SCREEN.md §9 "Settings help"): what a settings screen hands to the
 * companion window about its focused row, as immutable data, the pure fit of it for one panel and the page that draws it.
 * While a window shows the page (``CompanionHub/showsHelp``) the screen leaves out its own description and gives the list
 * the room (``companionHidesDescription(windowShowsHelp:help:)``).
 *
 * DELOS for Apple has no Debug info screen, so Android's debug details (`CompanionHelp.details`, `HelpFit.details`) are
 * not ported.
 */

/// Where a per-app value comes from (`HelpSource`, CompanionHelp.kt:58): the marker (custom for this app or from the
/// profile) and the sentence with its [strong] part in bold.
struct CompanionHelpSource: Hashable, Sendable {
    let custom: Bool
    let icon: String
    let title: String
    let before: String
    let strong: String
    let after: String

    /// The sentence formatted around [marker], which [strong] then replaces so it can be set in bold
    /// (`helpSource`, CompanionHelp.kt:85-89). A sentence without the marker is plain text.
    static func make(custom: Bool, icon: String, title: String, sentence: String, marker: String, strong: String) -> CompanionHelpSource {
        guard !marker.isEmpty, let range = sentence.range(of: marker) else {
            return CompanionHelpSource(custom: custom, icon: icon, title: title, before: sentence, strong: "", after: "")
        }
        return CompanionHelpSource(
            custom: custom, icon: icon, title: title, before: String(sentence[..<range.lowerBound]), strong: strong,
            after: String(sentence[range.upperBound...]))
    }
}

/// One color of the palette row with its name (`HelpSwatch`).
struct CompanionHelpSwatch: Equatable, Sendable {
    let color: RGBA
    let label: String
}

/// The game background as the settings rows change it (`HelpBackdrop`, CompanionHelp.kt:68-77): [active] while a game
/// background is on and a game's art is there, at [opacity]; [title] is the name on the preview. Android hands over the
/// rendered lens image; here the page renders it itself from [hero] at [blur] through the shell's [art], because the
/// lens is made off the main thread and a page is built synchronously.
struct CompanionHelpBackdrop: Equatable {
    let title: String
    let active: Bool
    let hero: GameArt?
    let blur: Int
    let opacity: Double
    let art: HomeArt

    static func == (a: CompanionHelpBackdrop, b: CompanionHelpBackdrop) -> Bool {
        a.title == b.title && a.active == b.active && a.hero == b.hero && a.blur == b.blur && a.opacity == b.opacity && a.art === b.art
    }
}

/// The description of the row focused on a settings screen (`CompanionHelp`, CompanionHelp.kt:20-55). [identity] names
/// the row: a new one crossfades, an update of the same row (a changed value) does not.
struct CompanionHelp: Hashable {
    let identity: String
    let icon: String
    let title: String
    /// The value's own detail and the explanation of the setting.
    let body: String
    /// An authored one-sentence form of [body], used when not even its first sentence fits.
    var short: String?
    /// Where the row lives ("Settings · Display", "App settings").
    var section: String?
    /// The body warns about a risk: it is set in the warm notice color.
    var notice = false
    var source: CompanionHelpSource?
    var unavailable = false
    /// A text row's current text, set apart in the accent color.
    var value: String?
    var impact: SettingImpact?
    var swatches: [CompanionHelpSwatch] = []
    var backdrop: CompanionHelpBackdrop?
    /// Per-app settings: "Saved automatically".
    var savedNote = false

    static func == (a: CompanionHelp, b: CompanionHelp) -> Bool {
        a.identity == b.identity && a.icon == b.icon && a.title == b.title && a.body == b.body && a.short == b.short && a.section == b.section
            && a.notice == b.notice && a.source == b.source && a.unavailable == b.unavailable && a.value == b.value && a.impact == b.impact
            && a.swatches == b.swatches && a.backdrop == b.backdrop && a.savedNote == b.savedNote
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
        hasher.combine(title)
        hasher.combine(body)
        hasher.combine(value)
    }
}

/// Whether the main screen leaves out its description and gives the list the room (`hidesDescription`,
/// CompanionHelp.kt:79-83): only while a companion window has actually taken the help.
func companionHidesDescription(windowShowsHelp: Bool, help: CompanionHelp?) -> Bool { windowShowsHelp && help != nil }

/// The authored short form of a row's help (`helpShort`, CompanionHelp.kt:91-97): the catalog's one-line [summary], else
/// the first sentence of [body], else the row's [title].
func companionHelpShort(summary: String?, body: String, title: String) -> String {
    if let summary = summary?.trimmingCharacters(in: .whitespaces), !summary.isEmpty { return summary }
    return CompanionFit.sentences(body).first ?? title
}

// MARK: - Fit

/// The heading of a settings help after the fit (`HelpHeadingText`).
struct CompanionHelpHeading: Equatable, Sendable {
    let title: String
    let subtitle: String?
}

/// The source block's text after the fit (`SourceView`): the bold [title], then the sentence around its bold [strong] part.
struct CompanionSourceView: Equatable, Sendable {
    let title: String
    let before: String
    let strong: String
    let after: String
}

/// What the settings help shows for one panel (`HelpFit`, CompanionPageFit.kt:24-145): pure functions on top of the
/// budgets of ``CompanionFit``; the page only draws what these decide.
enum HelpFit {
    /// What the source block takes of the width besides the text: its padding, the icon and the gap after it.
    static let sourceChrome = 90.0
    /// The dot, its gap and the padding of one swatch chip.
    static let swatchChrome = 70.0
    /// The text value is at most two lines.
    static let valueLines = 2
    private static let ellipsis = "\u{2026}"

    /// The lines the description gets (`bodyLines`): fewer beside the swatches, the background preview or a text value.
    static func bodyLines(_ help: CompanionHelp, budget: FitBudget) -> Int {
        let limit: Int
        if !help.swatches.isEmpty {
            limit = budget.roomy ? 3 : 1
        } else if help.backdrop != nil {
            limit = budget.roomy ? 3 : 2
        } else if help.value != nil {
            limit = budget.roomy ? 4 : 2
        } else {
            limit = budget.helpLines
        }
        return min(limit, budget.helpLines)
    }

    /// The heading (`heading`): the row's title when it fits one line in the display face, else the place it lives becomes
    /// the title and the full title drops to the small line, so nothing is cut with an ellipsis. The disc takes
    /// ``PageHeading/chrome`` of the width.
    static func heading(title: String, section: String?, width: Double, metrics: some CompanionTextMetrics) -> CompanionHelpHeading {
        let room = width - PageHeading.chrome
        if metrics.lines(title, width: room, kind: .title) <= 1 { return CompanionHelpHeading(title: title, subtitle: section) }
        guard let place = section, !place.trimmingCharacters(in: .whitespaces).isEmpty, metrics.lines(place, width: room, kind: .title) <= 1 else {
            return CompanionHelpHeading(title: title, subtitle: section)
        }
        return CompanionHelpHeading(title: place, subtitle: metrics.lines(title, width: room) <= 1 ? title : nil)
    }

    /// The source sentence cut to [maxLines] at a sentence behind its bold title (`source`); the title always stays.
    static func source(_ source: CompanionHelpSource, maxLines: Int, width: Double, metrics: some CompanionTextMetrics) -> CompanionSourceView {
        let room = width - sourceChrome
        let lead = source.before + source.strong
        let body = lead + source.after
        func view(_ text: String) -> CompanionSourceView {
            if text == body { return CompanionSourceView(title: source.title, before: source.before, strong: source.strong, after: source.after) }
            if !source.strong.isEmpty, text.hasPrefix(lead) {
                return CompanionSourceView(title: source.title, before: source.before, strong: source.strong, after: String(text.dropFirst(lead.count)))
            }
            return CompanionSourceView(title: source.title, before: text, strong: "", after: "")
        }
        if metrics.lines("\(source.title) \(body)", width: room) <= maxLines { return view(body) }
        var kept = ""
        for sentence in CompanionFit.sentences(body) {
            let candidate = kept.isEmpty ? sentence : "\(kept) \(sentence)"
            if metrics.lines("\(source.title) \(candidate)", width: room) <= maxLines { kept = candidate } else { break }
        }
        return view(kept)
    }

    /// A text row's current text in [maxLines] (`value`): whole when it fits, else its END behind a leading ellipsis (the
    /// end tells two paths or names apart). The only place an ellipsis stands for a cut, and for data, never for prose.
    static func value(_ value: String, maxLines: Int, width: Double, metrics: some CompanionTextMetrics) -> String {
        if metrics.lines(value, width: width) <= maxLines { return value }
        var low = 0
        var high = value.count
        while low < high {
            let mid = (low + high + 1) / 2
            if metrics.lines(ellipsis + value.suffix(mid), width: width) <= maxLines { low = mid } else { high = mid - 1 }
        }
        return ellipsis + value.suffix(low)
    }

    /// A description ready to be cut at sentences (`prepare`): every line that ends in a letter or digit gets a full stop
    /// (an ideographic one after CJK), so "Balanced" on a line of its own reads "Balanced." when the text is cut.
    static func prepare(_ body: String) -> String {
        body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line -> String in
            var text = String(line)
            while let last = text.last, last.isWhitespace { text.removeLast() }
            guard let last = text.last, last.isLetter || last.isNumber else { return text }
            return text + (isCJK(last) ? "\u{3002}" : ".")
        }.joined(separator: "\n")
    }

    /// Han, Hiragana or Katakana (`CJK_SCRIPTS`).
    private static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFF66...0xFF9F).contains(v) || (0x20000...0x2FA1F).contains(v)
    }

    /// Whether every swatch of [labels] fits one row of [width] (`swatchesInRow`); else the page stacks them.
    static func swatchesInRow(_ labels: [String], width: Double, metrics: some CompanionTextMetrics, chrome: Double = swatchChrome, gap: Double = 8) -> Bool {
        labels.reduce(0) { $0 + metrics.width($1) + chrome } + gap * Double(max(labels.count - 1, 0)) <= width
    }
}

// MARK: - Page

/// The settings help on the companion (`SettingsHelpPage`, CompanionHelpContent.kt:56-62): key "help/<row>", the settings
/// help flag set, so the screen gives its description's room to the list while it is shown.
enum SettingsHelpPage {
    static func page(_ help: CompanionHelp) -> CompanionPage {
        CompanionPage(key: "help/\(help.identity)", revision: help, isSettingsHelp: true) { CompanionHelpCard(help: help) }
    }
}

extension View {
    /// Publishes [help] as the settings help (`PublishCompanionHelp`, CompanionPublisher.kt:117-123).
    func companionHelp(_ help: @escaping @MainActor () -> CompanionHelp) -> some View {
        companionPage { SettingsHelpPage.page(help()) }
    }
}

/// One row's page, top to bottom (`HelpPage`, CompanionHelpContent.kt:70-100): the heading, the source of a per-app value,
/// the description, the text value, the swatches, the background preview, the unavailable notice and the saved note, and
/// at the bottom the three impact chips. The leftover room goes to the preview, else a filler.
private struct CompanionHelpCard: View {
    let help: CompanionHelp
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    /// The warm notice color (`LowRed`).
    static let notice = RGBA(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)
    /// The background preview's least height in stage pixels.
    static let previewMin = 80.0

    var body: some View {
        PageCard { fit in
            let b = fit.budget
            let head = HelpFit.heading(title: help.title, section: help.section, width: b.innerWidth, metrics: fit.metrics)
            PageHeading(icon: help.icon, title: head.title, subtitle: head.subtitle)
            if let source = help.source {
                CompanionSourceBlock(
                    view: HelpFit.source(source, maxLines: b.sourceLines, width: b.innerWidth, metrics: fit.metrics), custom: source.custom,
                    icon: source.icon)
            }
            BodyText(
                CompanionFit.summary(
                    HelpFit.prepare(help.body), short: help.short ?? "", maxLines: HelpFit.bodyLines(help, budget: b), width: b.innerWidth,
                    metrics: fit.metrics, last: L("companion_see_main")),
                color: help.notice ? Self.notice : colors.text)
            if let value = help.value {
                BodyText(
                    HelpFit.value(value, maxLines: HelpFit.valueLines, width: b.innerWidth, metrics: fit.metrics), color: colors.accent,
                    maxLines: HelpFit.valueLines)
                    .optional(90)
            }
            if !help.swatches.isEmpty {
                CompanionSwatches(
                    swatches: help.swatches, inRow: HelpFit.swatchesInRow(help.swatches.map(\.label), width: b.innerWidth, metrics: fit.metrics))
            }
            if let backdrop = help.backdrop {
                CompanionBackdropPreview(backdrop: backdrop).fills(minHeight: stage.px(Self.previewMin))
            }
            if help.unavailable { BodyText(L("settings_screen_unavailable"), color: colors.text2, maxLines: 2).optional(70) }
            if help.savedNote { CompanionSavedNote().optional(30) }
            if help.backdrop == nil { Filler() }
            CompanionImpactChips(impact: help.impact)
        }
    }
}

/// Where the value of a per-app row comes from (`SourceBlock`): a quiet frame, violet while the value is custom.
private struct CompanionSourceBlock: View {
    let view: CompanionSourceView
    let custom: Bool
    let icon: String
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        let tint = colors.accent3
        let shape = RoundedRectangle(cornerRadius: stage.px(22), style: .continuous)
        HStack(spacing: stage.px(14)) {
            SymbolView(symbol: icon, size: 32, color: custom ? tint : colors.text2, filled: true)
            Text(text(tint: tint))
                .font(DelosFonts.figtree(stage.tpx(CompanionFit.minText)))
                .foregroundStyle(colors.text2.color)
                .lineSpacing(stage.tpx(CompanionFit.minText) * 0.2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, stage.px(18))
        .padding(.vertical, stage.px(10))
        .background(shape.fill(custom ? tint.opacity(0.22).color : colors.text.opacity(0.06).color))
        .overlay(shape.strokeBorder(custom ? tint.opacity(0.5).color : colors.line.color, lineWidth: stage.px(1)))
    }

    private func text(tint: RGBA) -> AttributedString {
        var title = AttributedString(view.title)
        title.foregroundColor = (custom ? tint : colors.text2).color
        title.font = DelosFonts.figtree(stage.tpx(CompanionFit.minText), .bold)
        var strong = AttributedString(view.strong)
        strong.foregroundColor = colors.text.color
        strong.font = DelosFonts.figtree(stage.tpx(CompanionFit.minText), .bold)
        return title + AttributedString("  " + view.before) + strong + AttributedString(view.after)
    }
}

/// The palette's colors, one chip each (`Swatches`): in one row when they fit, else one under the other.
private struct CompanionSwatches: View {
    let swatches: [CompanionHelpSwatch]
    let inRow: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        if inRow {
            HStack(spacing: stage.px(8)) { chips }
        } else {
            VStack(spacing: stage.px(8)) { chips }
        }
    }

    private var chips: some View {
        let shape = RoundedRectangle(cornerRadius: stage.px(14), style: .continuous)
        return ForEach(swatches, id: \.label) { swatch in
            HStack(spacing: stage.px(12)) {
                Circle().fill(swatch.color.color)
                    .overlay(Circle().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                    .frame(width: stage.px(34), height: stage.px(34))
                Text(swatch.label)
                    .font(DelosFonts.figtree(stage.tpx(CompanionFit.minText)))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, stage.px(14))
            .padding(.vertical, stage.px(6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(colors.surface3.color))
            .overlay(shape.strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
    }
}

/// The preview of the game background (`BackdropPreview`): the lens image (or the placeholder hues) at the set opacity,
/// with the setting's name over it, in the room the other blocks leave and at most 16:9.
private struct CompanionBackdropPreview: View {
    let backdrop: CompanionHelpBackdrop
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @State private var rendered: CGImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: stage.px(22), style: .continuous)
        let area = HeroArea.of(stageWidth: stage.width, stageHeight: stage.height)
        GeometryReader { proxy in
            let height = min(proxy.size.height, proxy.size.width * 9 / 16)
            ZStack {
                colors.bg2.color
                if backdrop.active, let hero = backdrop.hero {
                    Group {
                        if hero.image != nil {
                            if let rendered { Image(decorative: rendered, scale: 1).resizable().scaledToFill() }
                        } else {
                            PlaceholderArt(hue: hero.hue, hue2: hero.hue2, icon: hero.icon, glyphSize: 160)
                        }
                    }
                    .opacity(backdrop.opacity)
                }
                Text(backdrop.title)
                    .font(DelosFonts.figtree(stage.tpx(CompanionFit.minText), .semibold))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
            }
            .frame(width: proxy.size.width, height: height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
        .task(id: "\(backdrop.hero?.id ?? "")/\(backdrop.blur)/\(area.width)x\(area.height)") {
            rendered = nil
            if let hero = backdrop.hero, hero.image != nil { rendered = await backdrop.art.background(hero, blur: backdrop.blur, area: area) }
        }
    }
}

/// "Saved automatically" (`SavedNote`): a per-app row needs no Save button.
private struct CompanionSavedNote: View {
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(alignment: .top, spacing: stage.px(12)) {
            SymbolView(symbol: Symbols.checkCircle, size: 32, color: colors.text3)
            BodyText(L("settings_game_saved_note"), color: colors.text3, maxLines: 2)
        }
    }
}

// MARK: - Builders

extension CompanionHelp {
    /// What the companion shows of the row focused in Settings (`settingsHelp`, SettingsScreen.kt:555-582): the pieces of
    /// the description panel as data; the tab's own help while no row is focused.
    @MainActor
    static func settings(tab: SettingsTab, row: SettingRow?, colors: DelosColors, appearance: Appearance, art: HomeArt) -> CompanionHelp {
        let title = row?.label ?? tab.label
        let body = row.flatMap { $0.help.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.help } ?? tab.help
        let backgroundRows = [AppearanceForm.heroBackground, AppearanceForm.heroBlur, AppearanceForm.heroOpacity]
        var notice = false
        if row?.id == DisplaySetting.dimID, case .choice(let label, _, _) = row?.value { notice = label == L("common_off") }
        return CompanionHelp(
            identity: row?.id ?? "tab:\(tab)", icon: row?.icon ?? tab.icon, title: title, body: body,
            short: companionHelpShort(summary: nil, body: body, title: title), section: L("companion_help_settings_section", tab.label),
            notice: notice, unavailable: row?.enabled == false, value: row?.value.heldText, impact: row?.impact,
            swatches: row?.id == AppearanceForm.palette
                ? [
                    CompanionHelpSwatch(color: colors.accent, label: L("settings_screen_palette_main")),
                    CompanionHelpSwatch(color: colors.accent2, label: L("settings_screen_palette_secondary")),
                    CompanionHelpSwatch(color: colors.accent3, label: L("settings_screen_palette_accent")),
                ] : [],
            backdrop: row.map { backgroundRows.contains($0.id) } == true
                ? CompanionHelpBackdrop(
                    title: L("settings_native_hero_background_title"), active: appearance.heroBackground && art.hero != nil, hero: art.hero,
                    blur: appearance.heroBlur, opacity: Double(appearance.heroOpacity) / 100, art: art)
                : nil)
    }

    /// What the companion shows of the row focused in an app's settings (GameSettingsScreen.kt:205-220 and
    /// `gameSettingsSource`, :536-555): the source of its value with that value in bold, the help and the saved note.
    @MainActor
    static func game(
        app: String, row: SettingRow?, custom: Bool, profileLabel: String, currentLabel: String, streamCount: Int, displayCount: Int
    ) -> CompanionHelp {
        let title = row?.label ?? L("settings_game_panel_title")
        let body = row.flatMap { $0.help.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.help } ?? L("settings_game_only_this_game", app)
        // The sentence is formatted around a marker that the value then replaces
        let marker = "\u{1}"
        let source: CompanionHelpSource
        if row == nil {
            let total = streamCount + displayCount
            source = .make(
                custom: total > 0, icon: total > 0 ? Symbols.tune : Symbols.checkCircle, title: GameSettingsText.customLabel(total),
                sentence: GameSettingsText.summary(stream: streamCount, display: displayCount), marker: "", strong: "")
        } else if custom {
            #if os(iOS)
            let sentence = L("settings_game_profile_value_touch", marker)
            #else
            let sentence = L("settings_game_profile_value_button", marker, ControllerGlyphs.shared.mark(.west).text ?? "X")
            #endif
            source = .make(
                custom: true, icon: Symbols.tune, title: L("settings_game_custom_title"), sentence: sentence, marker: marker, strong: profileLabel)
        } else {
            source = .make(
                custom: false, icon: Symbols.accountCircle, title: L("settings_game_from_profile"), sentence: L("settings_game_currently", marker),
                marker: marker, strong: currentLabel)
        }
        return CompanionHelp(
            identity: row?.id ?? "game", icon: row?.icon ?? Symbols.tune, title: title, body: body,
            short: companionHelpShort(summary: nil, body: body, title: title), section: L("companion_screen_game_settings"), source: source,
            impact: row?.impact, savedNote: true)
    }
}
