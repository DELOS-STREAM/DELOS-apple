import DelosData
import DelosInput
import Foundation
import SwiftUI

/// How the settings search compares text, so that the letter picker of every language can find every title
/// (`SearchText` of DELOS for Android; the keys of `settings_screen_search_letters`):
///
/// * Latin, Cyrillic: lower-cased substring.
/// * Japanese: the picker has the 46 basic hiragana. Both the query and the text are folded to a kana skeleton (``fold(_:)``:
///   katakana become hiragana, dakuten and small kana are dropped, the long-vowel mark is dropped) so that `ひつとれと` finds
///   ビットレート; the kanji of titles are replaced by their readings (the system's Japanese tokenizer, where Android has a
///   table) before folding.
/// * Korean: the picker has the 14 initial consonants. A query of them finds the titles whose syllables start with those
///   consonants in that order (``initials(_:pinyin:)``): `ㅎㅅㄷ` finds 해상도.
/// * Chinese: the picker has A-Z; besides matching Latin text, a letter sequence also finds the titles whose characters have
///   these pinyin initials (the system's Mandarin transliteration): `sz` finds 设置.
enum SettingsSearchText {
    /// Lower case; kana as hiragana without dakuten, small forms and the long-vowel mark. Text without kana is only lower-cased.
    static func fold(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for original in text.lowercased().unicodeScalars {
            let code = original.value
            if code == 0x30FC || code == 0x3099 || code == 0x309A { continue }
            let scalar = (0x30A1...0x30F6).contains(code) ? Unicode.Scalar(code - 0x60) ?? original : original
            if (0x3041...0x3096).contains(scalar.value) {
                let base = String(scalar).decomposedStringWithCanonicalMapping.unicodeScalars.first ?? scalar
                out.append(smallKana[base] ?? base)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// The initials of [text] with the spaces and punctuation removed: the initial consonant of every Hangul syllable, the pinyin
    /// initial of every Han character when [pinyin] (a placeholder for one that has none), letters and digits as they are. Nil when
    /// the text has no Hangul and no pinyin Han, so that other languages never match by initials.
    static func initials(_ text: String, pinyin: Bool) -> String? {
        var any = false
        var out = ""
        for ch in text.lowercased() {
            guard let code = ch.unicodeScalars.first?.value, ch.unicodeScalars.count == 1 else {
                if ch.isLetter || ch.isNumber { out.append(ch) }
                continue
            }
            switch code {
            case 0xAC00...0xD7A3:
                out.append(plainJamo(choseong[Int(code - 0xAC00) / (21 * 28)]))
                any = true
            case 0x3131...0x314E:
                out.append(plainJamo(ch))
                any = true
            case 0x4E00...0x9FFF:
                out.append(pinyin ? pinyinInitial(ch) ?? noInitial : noInitial)
                if pinyin { any = true }
            default:
                if ch.isLetter || ch.isNumber { out.append(ch) }
            }
        }
        return any ? out : nil
    }

    /// A double consonant as its plain one: the picker offers 14, an input method also types ㄲ ㄸ ㅃ ㅆ ㅉ.
    static func plainJamo(_ ch: Character) -> Character { doubleJamo[ch] ?? ch }

    /// Whether [word] (one word of the query) is found in a row: [text] is everything the row is searched by, [titles] the short
    /// names that readings and initials are made of, [language] the language of the texts (`ja`, `zh`, ...).
    static func matches(word: String, text: String, titles: String, language: String) -> Bool {
        if text.lowercased().contains(word) { return true }
        let folded = fold(text) + " " + (language == "ja" ? fold(japaneseReading(titles)) : "")
        if folded.contains(fold(word)) { return true }
        guard word.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        return initials(titles, pinyin: language == "zh")?.contains(String(word.map(plainJamo))) == true
    }

    private static let noInitial: Character = "\u{FFFF}"
    private static let choseong = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    private static let doubleJamo: [Character: Character] = ["ㄲ": "ㄱ", "ㄸ": "ㄷ", "ㅃ": "ㅂ", "ㅆ": "ㅅ", "ㅉ": "ㅈ"]
    private static let smallKana: [Unicode.Scalar: Unicode.Scalar] = [
        "ぁ": "あ", "ぃ": "い", "ぅ": "う", "ぇ": "え", "ぉ": "お", "っ": "つ", "ゃ": "や", "ゅ": "ゆ", "ょ": "よ",
        "ゎ": "わ", "ゕ": "か", "ゖ": "け",
    ]

    /// The first letter of the pinyin of a Han character, without tone marks.
    private static func pinyinInitial(_ ch: Character) -> Character? {
        String(ch).applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?.lowercased().first
    }

    /// The text with the kanji replaced by their hiragana readings (the system's Japanese tokenizer; Android has a table of
    /// them: `JapaneseReadings`).
    static func japaneseReading(_ text: String) -> String {
        let string = text as NSString
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, text as CFString, CFRange(location: 0, length: string.length),
            kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale)
        var out = ""
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = string.substring(with: NSRange(location: range.location, length: range.length))
            if token.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) || $0.value == 0x3005 }),
               let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
               let kana = latin.applyingTransform(.latinToHiragana, reverse: false) {
                out += kana
            } else {
                out += token
            }
        }
        return out
    }
}

/// The geometry of the on-screen letter picker (`LetterPicker`): nine keys to a row, and more columns of slightly smaller keys
/// when six rows are not enough. The compact stage does not squeeze that grid: its keys keep the 64 px target in two rows that
/// scroll sideways together.
///
/// The keys are a dense grid (``FocusSpacing``): a focused key does not grow and its ring lies inside its edge, so it reaches
/// nothing beyond the key and any gap of ``FocusSpacing/clearance`` or more keeps the focus off its neighbours.
enum LetterPicker {
    static let columns = 9, maxRows = 6, key = 74.0, gap = 12.0, width = 820.0
    static let compactRows = 2, compactKey = 64.0
    /// The focused key's ring, inside its edge, wide and compact.
    static let ring = 5.0, compactRing = 4.0
    /// Between two compact keys, and from the keys to the Delete / Clear circles: the circle's reach (64 px growing by 8 % with
    /// its 4 px ring 4 px out, inside its scale: 11.2) and the clearance.
    static let compactGap = 26.0
    /// Between the compact Delete and Clear circles, one above the other: twice the circle's reach and the clearance.
    static let compactCircleGap = 32.0
    /// The wide picker's field above the keys: the field's reach (84 px growing by 5 % with its 4 px ring 4 px out, inside its
    /// scale: 10.5) and the clearance.
    static let fieldGap = 34.0
    /// The wide picker's keys above the Space, Delete and Clear pills: a pill's reach (``FocusSpacing/pillHeight`` growing by
    /// ``FocusSpacing/pillScale``, its ring inside the scale: 11.68) and the clearance; the pills stand ``FocusSpacing/pillGap``
    /// apart. Six rows of keys still fit above the hint bar on a 1080 px stage.
    static let pillsGap = 20.0
    /// The faded ends of the compact picker's scrolling layer, and its room above and below the keys.
    static let compactEdge = 24.0, compactRingRoom = 12.0

    static func columns(keys: Int) -> Int { keys <= columns * maxRows ? columns : (keys + maxRows - 1) / maxRows }

    /// The key edge in stage px: ``key`` up to nine columns, else what fits the 820 px of the picker.
    static func keySize(columns: Int) -> Double { min(Double(Int((width - gap * Double(columns - 1)) / Double(columns))), key) }

    /// The keys of one of the compact picker's rows: the alphabet runs on from the first row into the second.
    static func compactColumns(keys: Int) -> Int { max((keys + compactRows - 1) / compactRows, 1) }
}

enum SettingsSearch {
    static let maxLength = 80

    /// The order of Android's `nativeSettings`, which the results keep (they are not sorted by tab): the appearance form's rows
    /// of these tabs first (Theme … Animations, Haptics, Sounds), then the shell's other rows of these tabs, then the catalog.
    static let appearanceOrder: [SettingsTab] = [.appearance, .controls, .audio]
    static let shellOrder: [SettingsTab] = [.controls, .display, .devices, .covers, .about, .stream, .audio, .appearance]

    /// The extra words a row can be found by besides its own texts (`SearchAliases`): the English words (earlier names and the
    /// terms gamers search for in any language; data, not interface text) and the localized synonyms, which are never shown.
    static func aliases(_ id: String) -> String {
        switch id {
        case SettingKey.gamepadMotionSensors.rawValue:
            "allow use of gamepad motion sensors motion sensor " + L("settings_search_alias_motion_sensors")
        case SettingKey.gamepadMotionFallback.rawValue:
            "emulate gamepad motion sensor support motion sensors " + L("settings_search_alias_motion_sensors")
        case SettingKey.forceDeviceMotion.rawValue:
            "always use device's motion sensors motion sensors " + L("settings_search_alias_motion_sensors")
        case SettingKey.gyroSmoothing.rawValue:
            "gyroscope stabilisation stabilization motion sensors " + L("settings_search_alias_gyro_smoothing")
        case SettingKey.vrr.rawValue:
            "vrr arr adaptive refresh rate freesync g-sync variable"
        case AppearanceForm.matchColors, AppearanceForm.heroBackground, AppearanceForm.heroBlur, AppearanceForm.heroOpacity,
             CoversForm.choose:
            "game " + L("settings_search_alias_game")
        case LinkGuidanceRows.testID:
            "bandwidth probe measure speed network wifi " + L("settings_search_alias_link_test")
        case LinkGuidanceRows.useID:
            "recommended bitrate link " + L("settings_search_alias_link_use")
        default: ""
        }
    }

    /// The rows whose texts contain every word of [query], in any order and case (`searchSettings`).
    static func results(_ rows: [SettingRow], query: String, language: String) -> [SettingRow] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return rows.filter { row in
            let tab = row.tab.label
            let options: String
            if case .choice(_, let all, _) = row.value { options = all.joined(separator: " ") } else { options = "" }
            let terms = [options, aliases(row.id)].filter { !$0.isEmpty }.joined(separator: " ")
            let text = "\(row.label) \(row.note ?? "") \(row.help) \(terms) \(row.section) \(tab)"
            let titles = "\(row.label) \(row.section) \(tab)"
            return words.allSatisfy { SettingsSearchText.matches(word: $0, text: text, titles: titles, language: language) }
        }
    }

    /// The language the texts are in (`ja`, `ko`, `zh`, ...), for the readings and initials.
    static var language: String {
        let code = Bundle.module.preferredLocalizations.first ?? Bundle.module.developmentLocalization ?? "en"
        return String(code.prefix(while: { $0 != "-" }))
    }
}

/// The search of Settings (`SettingsSearch` of DELOS for Android): a letter picker and a field share one query, and the rows of
/// every tab that match it are listed; a result opens its tab on that row. Controller: the letters, Space, Delete and Clear are
/// items of the screen's focus; the field takes a tap or A to type with the keyboard.
struct SettingsSearchView: View {
    let rows: [SettingRow]
    let focus: FocusModel
    let navigator: Navigator
    @Binding var query: String
    let onOpen: (SettingRow) -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion
    @FocusState private var editing: Bool
    @State private var typing = false

    static let fieldID = "search-field"
    static let spaceID = "search-space"
    static let deleteID = "search-delete"
    static let clearID = "search-clear"
    static func letterID(_ index: Int) -> String { "search-letter-\(index)" }
    /// Where the focus starts: the field, as on Android. On tvOS the field is the system's own text field, not an item of the
    /// focus, so the first letter.
    static var initialFocus: String {
        #if os(tvOS)
        letterID(0)
        #else
        fieldID
        #endif
    }
    static func resultID(_ id: String) -> String { "search-result-\(id)" }

    private var results: [SettingRow] { SettingsSearch.results(rows, query: query, language: SettingsSearch.language) }
    private var letters: [Character] { Array(L("settings_screen_search_letters")) }

    private func type(_ text: String) { query = String((query + text.lowercased()).prefix(SettingsSearch.maxLength)) }
    private func delete() { query = String(query.dropLast()) }
    private func clear() { query = "" }

    var body: some View {
        let compact = stage.compact
        let margin = SettingsLayout.margin(stage)
        let left = compact ? margin : margin + stage.safe.leading
        let right = compact ? margin : margin + stage.safe.trailing
        let bottom = SettingsLayout.bottom(scale: stage.textScale) + stage.safe.bottom
        Group {
            if compact { compactBody } else { wideBody }
        }
        .padding(.leading, stage.px(left))
        .padding(.trailing, stage.px(right))
        .padding(.top, stage.px((compact ? SettingsLayout.compactTabsY : 130) + stage.safe.top))
        .padding(.bottom, stage.px(bottom))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: typing) { _, now in navigator.textEditing(now) }
        // The letters are a 2-D grid (with the compact layout's Space key in it): Up and Down keep the column
        .onChange(of: [letters.count, compact ? 1 : 0], initial: true) { _, now in
            let keys = (0..<now[0]).map { AnyHashable(Self.letterID($0)) }
            focus.keepColumn(in: "search-letters", items: now[1] == 1 ? keys + [AnyHashable(Self.spaceID)] : keys)
        }
        .onChange(of: navigator.isEditingText) { _, now in if !now { typing = false } }
        .onDisappear { if typing { navigator.isEditingText = false } }
    }

    // MARK: Wide

    private var wideBody: some View {
        let keys = letters
        let columns = LetterPicker.columns(keys: keys.count)
        let size = LetterPicker.keySize(columns: columns)
        return VStack(alignment: .leading, spacing: 0) {
            Text(L("settings_screen_search_title"))
                .font(DelosFonts.unbounded(stage.tpx(46)))
                .foregroundStyle(colors.text.color)
            Text(L("settings_screen_search_hint"))
                .font(DelosFonts.figtree(stage.tpx(22)))
                .foregroundStyle(colors.text3.color)
                .padding(.top, stage.px(14))
                .padding(.bottom, stage.px(32))
            HStack(alignment: .top, spacing: stage.px(70)) {
                VStack(alignment: .leading, spacing: 0) {
                    field(width: 790)
                    VStack(alignment: .leading, spacing: stage.px(LetterPicker.gap)) {
                        ForEach(Array(stride(from: 0, to: keys.count, by: columns)), id: \.self) { start in
                            HStack(spacing: stage.px(LetterPicker.gap)) {
                                ForEach(start..<min(start + columns, keys.count), id: \.self) { index in
                                    letterKey(String(keys[index]), index: index, size: size)
                                }
                            }
                        }
                    }
                    .padding(.top, stage.px(LetterPicker.fieldGap))
                    HStack(spacing: stage.px(FocusSpacing.pillGap)) {
                        FocusItem(id: Self.spaceID, model: focus, action: { type(" ") }) { focused in
                            PillButton(label: L("settings_screen_search_space"), focused: focused)
                        }
                        FocusItem(id: Self.deleteID, model: focus, action: delete) { focused in
                            PillButton(label: L("settings_screen_search_delete"), icon: Symbols.backspace, focused: focused)
                        }
                        FocusItem(id: Self.clearID, model: focus, action: clear) { focused in
                            PillButton(label: L("settings_screen_search_clear"), icon: Symbols.clear, focused: focused)
                        }
                    }
                    .padding(.top, stage.px(LetterPicker.pillsGap))
                }
                .frame(width: stage.px(820), alignment: .topLeading)
                VStack(alignment: .leading, spacing: 0) {
                    count.padding(.bottom, stage.px(16))
                    resultsList
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: Compact

    /// No title and no squeezed grid: the field with the count beside it, the letters as two rows of full-size keys that scroll
    /// sideways together (Delete and Clear stay put at their right), and the results under them at the full width.
    private var compactBody: some View {
        let keys = letters
        let perRow = LetterPicker.compactColumns(keys: keys.count)
        let gap = LetterPicker.compactGap
        let rowsOfKeys = stride(from: 0, to: keys.count, by: perRow).map { Array($0..<min($0 + perRow, keys.count)) }
        let key = LetterPicker.compactKey
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                field(width: stage.width - 2 * SettingsLayout.margin(stage) - SettingsLayout.searchCountRoom)
                count.frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(spacing: stage.px(gap)) {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: stage.px(gap)) {
                        ForEach(Array(rowsOfKeys.enumerated()), id: \.offset) { row, indices in
                            HStack(spacing: stage.px(gap)) {
                                ForEach(indices, id: \.self) { index in
                                    letterKey(String(keys[index]), index: index, size: key, hosted: true)
                                }
                                if row == rowsOfKeys.count - 1 {
                                    FocusItem(id: Self.spaceID, model: focus, action: { type(" ") }) { focused in
                                        spaceKey(focused: focused, size: key)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, stage.px(LetterPicker.compactEdge))
                    .padding(.vertical, stage.px(LetterPicker.compactRingRoom))
                }
                .focusable(false)
                .scrollClipDisabled()
                // Both ends of the scrolling layer always fade, as Android's `fadeMask` does
                .scrollEdgeFade(.horizontal, FadeEdges(LetterPicker.compactEdge), growth: .always)
                VStack(spacing: stage.px(LetterPicker.compactCircleGap)) {
                    FocusItem(id: Self.deleteID, model: focus, action: delete) { focused in
                        circle(Symbols.backspace, focused: focused, size: key)
                    }
                    .accessibilityLabel(L("settings_screen_search_delete"))
                    FocusItem(id: Self.clearID, model: focus, action: clear) { focused in
                        circle(Symbols.clear, focused: focused, size: key)
                    }
                    .accessibilityLabel(L("settings_screen_search_clear"))
                }
            }
            .padding(.top, stage.px(gap))
            Spacer().frame(height: stage.px(10))
            resultsList.frame(maxHeight: .infinity)
        }
    }

    // MARK: Parts

    private var count: some View {
        Text(LPlural("settings_screen_search_count", results.count))
            .font(DelosFonts.figtree(stage.tpx(22)))
            .foregroundStyle(colors.text3.color)
            .lineLimit(1)
    }

    private func letterKey(_ letter: String, index: Int, size: Double, hosted: Bool = false) -> some View {
        FocusItem(id: Self.letterID(index), model: focus, action: { type(letter) }) { focused in
            Text(letter)
                .font(DelosFonts.figtree(stage.tpx(28), .semibold))
                .foregroundStyle((focused ? colors.accent : colors.text).color)
                .lineLimit(1)
                .frame(width: stage.px(size), height: stage.px(size))
                .background(keyFace(focused, ring: hosted ? LetterPicker.compactRing : LetterPicker.ring))
        }
    }

    private func spaceKey(focused: Bool, size: Double) -> some View {
        Text(L("settings_screen_search_space"))
            .font(DelosFonts.figtree(stage.tpx(28), .semibold))
            .foregroundStyle((focused ? colors.accent : colors.text).color)
            .lineLimit(1)
            .padding(.horizontal, stage.px(24))
            .frame(minWidth: stage.px(size), minHeight: stage.px(size), maxHeight: stage.px(size))
            .background(keyFace(focused, ring: LetterPicker.compactRing))
    }

    /// A key of the dense grid (``LetterPicker``): its plate, and when focused its ring in the main color inside its edge; it
    /// neither grows nor glows, so nothing of the focus reaches the next key.
    private func keyFace(_ focused: Bool, ring: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: stage.px(18))
        return GlassShape(shape, tint: focused ? colors.surface2 : colors.surface)
            .overlay(
                shape.strokeBorder(colors.accent.color, lineWidth: stage.px(ring))
                    .opacity(focused ? 1 : 0)
                    .animation(.focusRing(focused: focused), value: focused))
    }

    private func circle(_ icon: String, focused: Bool, size: Double) -> some View {
        CircleIconButton(icon: icon, focused: focused, size: size)
    }

    @ViewBuilder private func field(width: Double) -> some View {
        #if os(tvOS)
        TextPill(
            label: nil, icon: Symbols.search, placeholder: L("settings_screen_search_placeholder"), text: $query, editing: $editing,
            focused: false, width: width)
            .multilineTextAlignment(.leading)
            .onChange(of: editing) { _, now in if now { focus.focus(AnyHashable(Self.fieldID)) } }
            .onChange(of: query) { _, now in if now.count > SettingsSearch.maxLength { query = String(now.prefix(SettingsSearch.maxLength)) } }
        #else
        FocusItem(id: Self.fieldID, model: focus, action: { typing = true }) { focused in
            TextPill(
                label: nil, icon: Symbols.search, placeholder: L("settings_screen_search_placeholder"), text: $query, editing: $editing,
                focused: focused, width: width)
                .multilineTextAlignment(.leading)
        }
        .holdingField()
        .onChange(of: typing) { _, now in editing = now }
        .onChange(of: editing) { _, now in
            if now {
                focus.focus(AnyHashable(Self.fieldID))
                typing = true
            } else {
                typing = false
            }
        }
        .onChange(of: query) { _, now in if now.count > SettingsSearch.maxLength { query = String(now.prefix(SettingsSearch.maxLength)) } }
        #endif
    }

    /// The results, one action row each; no results: a line saying so.
    private var resultsList: some View {
        let found = results
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: stage.px(SettingsLayout.rowGap)) {
                    if found.isEmpty {
                        Text(L("settings_screen_search_none"))
                            .font(DelosFonts.figtree(stage.tpx(26)))
                            .foregroundStyle(colors.text2.color)
                    }
                    ForEach(found) { item in
                        let result = SettingRow(
                            id: item.id, tab: item.tab, section: item.section, icon: item.icon, label: item.label,
                            value: .action(label: nil), help: "", note: L("settings_screen_dot_join", item.tab.label, item.section))
                        FocusItem(id: Self.resultID(item.id), model: focus, clickCue: .open, action: { onOpen(item) }) { focused in
                            SettingRowView(row: result, focused: focused)
                        }
                        .id(Self.resultID(item.id))
                    }
                }
                .padding(.horizontal, stage.px(18))
                .padding(.top, stage.px(14))
                .padding(.bottom, stage.px(48))
                .focusDrivenScroll()
            }
            .focusable(false)
            .scrollClipDisabled()
            .scrollEdgeFade(.vertical, FadeEdges(
                start: FadeEdge(solid: stage.compact ? SettingsLayout.compactFadeTop : SettingsLayout.fadeTop), end: FadeEdge(solid: 40)))
            .onChange(of: focus.focused) { _, now in
                guard let id = now as? String, id.hasPrefix("search-result-"), !focus.pointerMoved else { return }
                withAnimation(reduceMotion ? nil : SettingsScrollMotion.animation(distance: 0)) { proxy.scrollTo(id) }
            }
        }
    }
}

/// An action beside a compact stage's tab row (the settings' search): its icon alone in a glass circle, where the labelled pill
/// would not fit beside the tabs (`CircleIconButton`). [size] is its edge in stage px.
struct CircleIconButton: View {
    let icon: String
    let focused: Bool
    let size: Double
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        SymbolView(symbol: icon, size: 30, color: colors.text, filled: focused)
            .frame(width: stage.px(size), height: stage.px(size))
            .background {
                GlassShape(Circle(), tint: colors.surface)
                    .overlay(Circle().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
            }
            // The pills' ring and glow (a 70 px circle around the centre)
            .focusLook(focused, scale: 1.08, ring: 4, glowBlur: 50, glowY: 18)
    }
}
