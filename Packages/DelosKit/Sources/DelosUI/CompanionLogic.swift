import Foundation

/*
 * The pure parts of the companion screen (no SwiftUI), the port of `shell/companion/CompanionLogic.kt` and
 * `CompanionFit.kt` of DELOS for Android: the burn-in policy, the line and entry budgets of a panel and the cutting of
 * texts at a sentence, the buttons of the game card and the echo of the touch keyboard.
 */

/// The burn-in policy of the companion screen (`CompanionBurnIn`, CompanionLogic.kt:22-37): everything moves by
/// ``step`` points every ``period`` along a fixed serpentine path over a 3 × 3 grid (an 18-minute cycle), always; the
/// idle dimming (``CompanionDim``) fades the content to ``dimAlpha``.
enum CompanionBurnIn {
    static let period: TimeInterval = 120
    static let step = 3.0
    static let dimAlpha = 0.22
    /// The fade into and out of the dim.
    static let dimFade: TimeInterval = 1.2

    /// A position of the shift in steps: -1, 0 or 1 on each axis.
    struct Shift: Equatable, Sendable {
        let x: Int
        let y: Int
    }

    static let path = [
        Shift(x: 0, y: 0), Shift(x: 1, y: 0), Shift(x: 1, y: 1), Shift(x: 0, y: 1), Shift(x: -1, y: 1), Shift(x: -1, y: 0),
        Shift(x: -1, y: -1), Shift(x: 0, y: -1), Shift(x: 1, y: -1),
    ]

    /// The shift [elapsed] seconds after the window opened: in place first, the whole path once per cycle.
    static func shift(at elapsed: TimeInterval) -> Shift {
        path[Int(max(elapsed, 0) / period) % path.count]
    }
}

/// Which published page wins when a screen and a layer over it both publish (`PagePriority`, CompanionPage.kt:17-30).
enum PagePriority {
    /// The focused game of Home.
    static let game = 50
    /// What a screen publishes about its focused item, and the settings help.
    static let screen = 100
    /// A sheet over the screen that changes what it shows (the filter sheets).
    static let modal = 200
    /// A launch in progress, a stream result, a problem: what must be seen first.
    static let overlay = 300
}

/// The companion's panel in fit units: its stage pixels divided by the interface scale (text grows with it).
struct CompanionPanel: Equatable, Sendable {
    var width: Double
    var height: Double

    /// A stage this high or higher is tall (room for more lines); 4:3 and 3:2 panels are short.
    static let roomyHeight = 900.0
    var roomy: Bool { height >= Self.roomyHeight }
}

/// What a kind of text measures with: the body face at the companion's smallest size, or a title in the display face.
enum FitText: Sendable { case body, title }

/// How a page measures text: the lines [text] needs in [width] fit pixels, and its width on one line.
protocol CompanionTextMetrics {
    func lines(_ text: String, width: Double, kind: FitText) -> Int
    func width(_ text: String, kind: FitText) -> Double
}

extension CompanionTextMetrics {
    func lines(_ text: String, width: Double) -> Int { lines(text, width: width, kind: .body) }
    func width(_ text: String) -> Double { width(text, kind: .body) }
}

/// The line and entry budgets of one panel (`FitBudget`).
struct FitBudget: Equatable, Sendable {
    var roomy: Bool
    /// Plain explanatory text (a pairing step, an empty library, a result).
    var bodyLines: Int
    /// The description of a setting.
    var helpLines: Int
    /// The source block of a per-game setting.
    var sourceLines: Int
    var genres: Int
    /// Controller hints in the fallback and the pairing steps.
    var hints: Int
    /// Facts of a PC card.
    var facts: Int
    /// The error text of a problem, and the recovery sentence under it.
    var errorLines: Int
    var recoveryLines: Int
    /// The width a line of text has inside a card, in fit pixels.
    var innerWidth: Double
}

/// Rule 0 of the companion (`CompanionFit`, CompanionFit.kt): every state fits its panel, nothing scrolls. Blocks are
/// ranked, long texts are cut at a sentence (never in one, never with an ellipsis), lists show the first entries and a
/// count, visuals shrink in ratio.
enum CompanionFit {
    /// The card's outer margin, on every side.
    static let margin = 48.0
    /// The header strip (brand and PC) and the strip kept free at the bottom (room for the burn-in shift).
    static let header = 64.0
    static let footer = 32.0
    /// A panel this narrow or narrower gets a little less padding and gap.
    static let narrowWidth = 800.0
    /// The smallest text and the smallest touch target, in stage pixels.
    static let minText = 28.0
    static let minTarget = 64.0
    static let titleSize = 36.0

    static func cardPadding(_ panel: CompanionPanel) -> Double { panel.width <= narrowWidth ? 20 : 24 }
    static func gap(_ panel: CompanionPanel) -> Double { panel.width <= narrowWidth ? 10 : 12 }

    static func budget(_ panel: CompanionPanel) -> FitBudget {
        let roomy = panel.roomy
        return FitBudget(
            roomy: roomy, bodyLines: roomy ? 5 : 3, helpLines: roomy ? 6 : 3, sourceLines: 2, genres: roomy ? 4 : 2, hints: roomy ? 5 : 2,
            facts: roomy ? 6 : 4, errorLines: roomy ? 5 : 2, recoveryLines: 2, innerWidth: panel.width - 2 * margin - 2 * cardPadding(panel))
    }

    /// The room a card has below the header, above the footer and inside the margins.
    static func cardHeight(_ panel: CompanionPanel) -> Double { panel.height - header - footer - 2 * margin }

    private static let endings: Set<Character> = [".", "!", "?", "\u{2026}", "\u{3002}", "\u{FF01}", "\u{FF1F}"]
    private static let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "\u{300D}"]
    private static let cjkEndings: Set<Character> = ["\u{3002}", "\u{FF01}", "\u{FF1F}"]

    /// The sentences of [text], each with its closing mark (and a closing quote). A line break ends a sentence too; a mark
    /// ends one only before a space or the end ("1.5x" and "v2.0.1" stay whole); a text without a mark is one sentence.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let p = Array(paragraph.trimmingCharacters(in: .whitespaces))
            guard !p.isEmpty else { continue }
            var start = 0
            var i = 0
            while i < p.count {
                if endings.contains(p[i]) {
                    var end = i + 1
                    while end < p.count, endings.contains(p[end]) { end += 1 }
                    if end < p.count, closers.contains(p[end]) { end += 1 }
                    if end >= p.count || p[end].isWhitespace || cjkEndings.contains(p[end - 1]) {
                        out.append(String(p[start..<end]).trimmingCharacters(in: .whitespaces))
                        start = end
                    }
                    i = end
                } else {
                    i += 1
                }
            }
            if start < p.count { out.append(String(p[start...]).trimmingCharacters(in: .whitespaces)) }
        }
        return out.filter { !$0.isEmpty }
    }

    /// The longest run of complete leading sentences of [full] that fits [maxLines] lines of [width]; else [short] when it
    /// fits; else [last] (an authored "see the main screen" sentence). A sentence is never cut.
    static func summary(_ full: String, short: String, maxLines: Int, width: Double, metrics: some CompanionTextMetrics, last: String) -> String {
        var result = ""
        for sentence in sentences(full) {
            let candidate = result.isEmpty ? sentence : "\(result) \(sentence)"
            if metrics.lines(candidate, width: width) <= maxLines { result = candidate } else { break }
        }
        if !result.isEmpty { return result }
        if !short.trimmingCharacters(in: .whitespaces).isEmpty, metrics.lines(short, width: width) <= maxLines { return short }
        return last
    }

    /// The labels of one row of chips: at most [maxItems] of [items] and "+N more" ([more] gets the count) when some are
    /// left, fewer still while the row is wider than [width] (each chip adds [chipPadding], the row [gap] between chips).
    static func chips(
        _ items: [String], maxItems: Int, width: Double, metrics: some CompanionTextMetrics, more: (Int) -> String,
        chipPadding: Double = 26, gap: Double = 8
    ) -> [String] {
        var selected = Array(items.prefix(maxItems))
        func labels() -> [String] { selected + (items.count > selected.count ? [more(items.count - selected.count)] : []) }
        func rowWidth(_ labels: [String]) -> Double {
            labels.reduce(0) { $0 + metrics.width($1) + chipPadding } + gap * Double(max(labels.count - 1, 0))
        }
        while !selected.isEmpty, rowWidth(labels()) > width { selected.removeLast() }
        return labels()
    }

    /// The first [max] of [items] and how many are left out.
    static func top<T>(_ items: [T], _ max: Int) -> (shown: [T], rest: Int) {
        (Array(items.prefix(max)), items.count - min(max, items.count))
    }

    /// [name] when it fits one line of [width] as a title, else [alias] (an authored short name such as "PC · 7C2A").
    static func title(_ name: String, alias: String, width: Double, metrics: some CompanionTextMetrics) -> String {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && metrics.lines(name, width: width, kind: .title) <= 1 ? name : alias
    }

    /// A short name for a PC whose name does not fit: [prefix] and the last four letters or digits of its id.
    static func alias(_ prefix: String, id: String) -> String {
        "\(prefix) \u{00B7} \(String(id.filter { $0.isLetter || $0.isNumber }.suffix(4)).uppercased())"
    }
}

/// The buttons of the game card (`ShellButton`, CompanionState.kt:64).
enum ShellButton: Equatable, Sendable {
    case start, resume, resumeOther, quitAndStart, gameSettings

    /// Which buttons show and in which order, the first the primary one (`shellButtons`, CompanionState.kt:101-105):
    /// nothing runs: Start; this game runs: Resume; another one runs: Resume that one (the safe choice) and Quit and
    /// start, the destructive one last of the launch buttons. Game settings closes the row.
    static func buttons(running: Bool, otherRunning: Bool) -> [ShellButton] {
        if running { return [.resume, .gameSettings] }
        if otherRunning { return [.resumeOther, .quitAndStart, .gameSettings] }
        return [.start, .gameSettings]
    }
}

/// The little echo of what the companion's keyboard typed (`TypedEcho`, CompanionLogic.kt:162-180): it has no text
/// field, the keys go to the stream. The last ``max`` characters; Backspace takes one off, Return shows as a mark.
struct TypedEcho: Equatable, Sendable {
    static let max = 40
    static let returnMark: Character = "\u{21B5}"

    private(set) var value = ""

    func typed(_ c: Character) -> TypedEcho { TypedEcho(value: String((value + String(c)).suffix(Self.max))) }
    func enter() -> TypedEcho { typed(Self.returnMark) }
    func backspace() -> TypedEcho { TypedEcho(value: String(value.dropLast())) }
    func cleared() -> TypedEcho { TypedEcho() }
}

/// What the game card says in text for one panel (`GameText`): the genre chips (with the count of the rest) and the one
/// muted line under them.
struct GameText: Equatable, Sendable {
    let genres: [String]
    let body: String?
}

/// The fit of the game card (`GameFit`, CompanionPageFit.kt:147-188).
enum GameFit {
    /// The lines the summary may take.
    static let proseLines = 2
    /// The width of one character of the display face as a share of its size (Unbounded is wide), and its line height.
    private static let em = 0.78
    private static let line = 1.15

    /// The first genres that fit one row and "+N genres" for the rest ([more]); the line under them is the summary on a
    /// tall panel (whole sentences in two lines) and the folded facts ("HLTB 19 h · Native HDR") on a short one, either
    /// falling back to the other when it has nothing.
    static func text(
        genres: [String], summary: String?, facts: String, budget: FitBudget, metrics: some CompanionTextMetrics, more: (Int) -> String
    ) -> GameText {
        let chips = CompanionFit.chips(genres, maxItems: budget.genres, width: budget.innerWidth, metrics: metrics, more: more)
        let prose = summary.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            .map { CompanionFit.summary($0, short: "", maxLines: proseLines, width: budget.innerWidth, metrics: metrics, last: "") } ?? ""
        let line = budget.roomy ? (prose.isEmpty ? facts : prose) : (facts.isEmpty ? prose : facts)
        return GameText(genres: chips, body: line.trimmingCharacters(in: .whitespaces).isEmpty ? nil : line)
    }

    /// The size in fit pixels of the game's name on its banner: larger for a shorter name, never more than two lines in
    /// [width], never taller than [height], never under the smallest text.
    static func nameSize(_ name: String, width: Double, height: Double) -> Double {
        var size = name.count > 26 ? 36.0 : name.count > 16 ? 46 : 58
        while size > CompanionFit.minText {
            let lines = max(Int((Double(name.count) * size * em / max(width, 1)).rounded(.up)), 1)
            if lines <= 2, Double(lines) * size * line <= height { break }
            size -= 2
        }
        return max(size, CompanionFit.minText)
    }
}
