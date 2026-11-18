import Foundation
import SwiftUI
import Testing
@testable import DelosUI

/// Text measured as 10 fit pixels per character, titles 20: enough to test the budgets without fonts.
struct FakeMetrics: CompanionTextMetrics {
    func lines(_ text: String, width: Double, kind: FitText) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int((self.width(text, kind: kind) / max(width, 1)).rounded(.up))
    }

    func width(_ text: String, kind: FitText) -> Double { Double(text.count) * (kind == .title ? 20 : 10) }
}

/// The pure parts of the companion screen (`CompanionLogicTest`, `CompanionFitTest`, `CompanionGamePageTest`,
/// `CompanionRoutesTest` of DELOS for Android).
@Suite struct CompanionCoreTests {
    private let metrics = FakeMetrics()

    @Test func burnInWalksTheWholeGridOncePerCycle() {
        #expect(CompanionBurnIn.shift(at: 0) == .init(x: 0, y: 0))
        #expect(CompanionBurnIn.shift(at: 119) == .init(x: 0, y: 0))
        #expect(CompanionBurnIn.shift(at: 120) == .init(x: 1, y: 0))
        #expect(CompanionBurnIn.shift(at: -5) == .init(x: 0, y: 0))
        let cycle = (0..<9).map { CompanionBurnIn.shift(at: Double($0) * CompanionBurnIn.period) }
        #expect(Set(cycle.map { "\($0.x),\($0.y)" }).count == 9)
        #expect(CompanionBurnIn.shift(at: 9 * CompanionBurnIn.period) == cycle[0])
        // Every step moves by one grid cell at most on each axis: no jump across the grid
        for (a, b) in zip(cycle, cycle.dropFirst()) { #expect(abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1) }
    }

    @Test func budgetsFollowThePanel() {
        let tall = CompanionFit.budget(CompanionPanel(width: 1099, height: 957))
        #expect(tall.roomy && tall.bodyLines == 5 && tall.helpLines == 6 && tall.genres == 4 && tall.hints == 5 && tall.facts == 6)
        #expect(tall.innerWidth == 1099 - 96 - 48)
        let short = CompanionFit.budget(CompanionPanel(width: 720, height: 640))
        #expect(!short.roomy && short.bodyLines == 3 && short.helpLines == 3 && short.genres == 2 && short.hints == 2 && short.facts == 4)
        #expect(short.errorLines == 2 && short.recoveryLines == 2 && short.innerWidth == 720 - 96 - 40)
        #expect(CompanionFit.cardHeight(CompanionPanel(width: 1000, height: 900)) == 900 - 64 - 32 - 96)
    }

    @Test func sentencesEndAtAMarkBeforeASpaceOrALineBreak() {
        #expect(CompanionFit.sentences("One. Two! Three?") == ["One.", "Two!", "Three?"])
        #expect(CompanionFit.sentences("Version 2.0.1 is 1.5x faster. Done") == ["Version 2.0.1 is 1.5x faster.", "Done"])
        #expect(CompanionFit.sentences("He said \"stop.\" Then left.") == ["He said \"stop.\"", "Then left."])
        #expect(CompanionFit.sentences("Title\nBody text.") == ["Title", "Body text."])
        #expect(CompanionFit.sentences("一つ。二つ。") == ["一つ。", "二つ。"])
        #expect(CompanionFit.sentences("  \n ").isEmpty)
    }

    @Test func summaryKeepsWholeSentencesOrFallsBack() {
        let full = "Short one. A much longer second sentence follows here."
        #expect(CompanionFit.summary(full, short: "S", maxLines: 1, width: 100, metrics: metrics, last: "L") == "Short one.")
        #expect(CompanionFit.summary(full, short: "S", maxLines: 9, width: 100, metrics: metrics, last: "L") == full)
        #expect(CompanionFit.summary("A sentence far too long for one line.", short: "Short.", maxLines: 1, width: 100, metrics: metrics, last: "L") == "Short.")
        #expect(CompanionFit.summary("A sentence far too long for one line.", short: "Also far too long here.", maxLines: 1, width: 100, metrics: metrics, last: "L") == "L")
    }

    @Test func chipsCountWhatDoesNotFit() {
        let more = { (n: Int) in "+\(n)" }
        #expect(CompanionFit.chips(["A", "B", "C"], maxItems: 4, width: 1000, metrics: metrics, more: more) == ["A", "B", "C"])
        #expect(CompanionFit.chips(["A", "B", "C"], maxItems: 2, width: 1000, metrics: metrics, more: more) == ["A", "B", "+1"])
        // A chip is its text (10 a letter) and 26, the gaps 8: all three take 124, two and "+1" 134, one and "+2" 90
        #expect(CompanionFit.chips(["A", "B", "C"], maxItems: 3, width: 124, metrics: metrics, more: more) == ["A", "B", "C"])
        #expect(CompanionFit.chips(["A", "B", "C"], maxItems: 2, width: 134, metrics: metrics, more: more) == ["A", "B", "+1"])
        #expect(CompanionFit.chips(["A", "B", "C"], maxItems: 3, width: 123, metrics: metrics, more: more) == ["A", "+2"])
        #expect(CompanionFit.chips(["A", "B", "C"], maxItems: 3, width: 89, metrics: metrics, more: more) == ["+3"])
        #expect(CompanionFit.top([1, 2, 3], 2) == ([1, 2], 1))
        #expect(CompanionFit.top([1], 5) == ([1], 0))
    }

    @Test func aTitleThatDoesNotFitBecomesItsAlias() {
        #expect(CompanionFit.title("Gaming PC", alias: "x", width: 400, metrics: metrics) == "Gaming PC")
        #expect(CompanionFit.title("A very very long PC name", alias: "PC · 7C2A", width: 200, metrics: metrics) == "PC · 7C2A")
        #expect(CompanionFit.title(" ", alias: "PC", width: 400, metrics: metrics) == "PC")
        #expect(CompanionFit.alias("PC", id: "1234-abcd-7c2a") == "PC \u{00B7} 7C2A")
    }

    @Test func gameCardButtonsFollowWhatRuns() {
        #expect(ShellButton.buttons(running: false, otherRunning: false) == [.start, .gameSettings])
        #expect(ShellButton.buttons(running: true, otherRunning: false) == [.resume, .gameSettings])
        #expect(ShellButton.buttons(running: false, otherRunning: true) == [.resumeOther, .quitAndStart, .gameSettings])
    }

    @Test func gameTextPicksTheSummaryOnTallPanelsAndFactsOnShortOnes() {
        let tall = CompanionFit.budget(CompanionPanel(width: 1099, height: 957))
        let short = CompanionFit.budget(CompanionPanel(width: 1099, height: 700))
        let text = GameFit.text(genres: ["RPG"], summary: "A game. More.", facts: "HLTB 19 h", budget: tall, metrics: metrics) { "+\($0)" }
        #expect(text == GameText(genres: ["RPG"], body: "A game. More."))
        #expect(GameFit.text(genres: [], summary: "A game.", facts: "HLTB 19 h", budget: short, metrics: metrics) { "+\($0)" }.body == "HLTB 19 h")
        #expect(GameFit.text(genres: [], summary: nil, facts: "", budget: short, metrics: metrics) { "+\($0)" }.body == nil)
        #expect(GameFit.nameSize("Hades", width: 900, height: 300) == 58)
        #expect(GameFit.nameSize(String(repeating: "W", count: 40), width: 300, height: 60) == CompanionFit.minText)
    }

    @Test func typedEchoKeepsTheLastCharacters() {
        var echo = TypedEcho()
        for c in "hello" { echo = echo.typed(c) }
        #expect(echo.backspace().value == "hell")
        #expect(echo.enter().value == "hello\u{21B5}")
        #expect(echo.cleared().value.isEmpty)
        var long = TypedEcho()
        for _ in 0..<50 { long = long.typed("x") }
        #expect(long.value.count == TypedEcho.max)
    }

    @Test func fitColumnDropsTheLowestOptionalBlocksFirst() {
        let blocks = [FitBlock(), FitBlock(priority: 50), FitBlock(priority: 80), FitBlock(priority: 30)]
        let heights: [CGFloat] = [100, 100, 100, 100]
        #expect(FitColumn.alive(blocks: blocks, heights: heights, gap: 10, height: 430) == [true, true, true, true])
        #expect(FitColumn.alive(blocks: blocks, heights: heights, gap: 10, height: 400) == [true, true, true, false])
        #expect(FitColumn.alive(blocks: blocks, heights: heights, gap: 10, height: 150) == [true, false, false, false])
        // Mandatory blocks stay even when they do not fit
        #expect(FitColumn.alive(blocks: [FitBlock(), FitBlock()], heights: [100, 100], gap: 0, height: 50) == [true, true])
    }

    @Test func sliderSnapsToItsGrid() {
        #expect(snapSliderValue(0.5, min: 0, max: 100, step: 10) == 50)
        #expect(snapSliderValue(0.54, min: 0, max: 100, step: 10) == 50)
        #expect(snapSliderValue(-1, min: 10, max: 100, step: 5) == 10)
        #expect(snapSliderValue(2, min: 10, max: 100, step: 5) == 100)
    }

    @Test func everyScreenHasContentOrTheFallback() {
        #expect(CompanionContentKind.of(.home(hostID: "h")) == .game)
        #expect(CompanionContentKind.of(.start) == .pc && CompanionContentKind.of(.devices) == .pc)
        #expect(CompanionContentKind.of(.settings) == .help && CompanionContentKind.of(.appSettings(hostID: "h", appID: 1)) == .help)
        #expect(CompanionContentKind.of(.oscPreview) == .fallback)
        #expect(CompanionContentKind.title(.devices) == "Devices" || !CompanionContentKind.title(.devices).isEmpty)
        #expect(!CompanionContentKind.purpose(.boot).isEmpty)
    }

    @MainActor @Test func theHighestPriorityWinsElseWelcomeOrFallback() {
        func page(_ key: String, _ priority: Int) -> CompanionPage { CompanionPage(key: key, priority: priority, revision: key) { EmptyView() } }
        #expect(CompanionHub.choose([(1, page("game", 50)), (2, page("help", 100))], context: nil).key == "help")
        #expect(CompanionHub.choose([(2, page("a", 100)), (1, page("b", 100))], context: nil).key == "b")
        #expect(CompanionHub.choose([], context: ShellContext(title: "T", purpose: "", hints: [], host: nil, welcome: true)).key == "welcome")
        #expect(CompanionHub.choose([], context: ShellContext(title: "T", purpose: "", hints: [], host: nil, welcome: false)).key == "fallback/T")

        let hub = CompanionHub()
        let a = UUID(), b = UUID()
        hub.publish(a, page("game", PagePriority.game))
        hub.publish(b, page("result", PagePriority.overlay))
        #expect(hub.shellPage.key == "result" && hub.overlayPage?.key == "result")
        hub.publish(b, nil)
        #expect(hub.shellPage.key == "game" && hub.overlayPage == nil)
    }
}
