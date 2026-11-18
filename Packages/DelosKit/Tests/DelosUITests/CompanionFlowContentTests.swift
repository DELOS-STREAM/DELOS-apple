import DelosData
import Foundation
import Testing
@testable import DelosUI

/// The pure parts of the flow and content pages of the companion screen (`CompanionFlowPagesTest` and
/// `CompanionContentPagesTest` of DELOS for Android): the folding of the loader's steps, the cut of the result texts and
/// the chips and counts of the filter pages.
@Suite struct CompanionFlowContentTests {
    private let metrics = FakeMetrics()
    private let tall = CompanionFit.budget(CompanionPanel(width: 1920, height: 1080))
    private let short = CompanionFit.budget(CompanionPanel(width: 1024, height: 768))

    // MARK: Steps

    @Test func everyStageHasExactlyOneCurrentStepAfterTheDoneOnes() {
        for stage in [CompanionStartStage.launching, .connecting, .connected] {
            let marks = CompanionFlowSteps.steps(stage).map(\.mark)
            #expect(marks.count == 4)
            #expect(marks.filter { $0 == .current }.count == 1)
            let current = marks.firstIndex(of: .current)!
            #expect(marks[..<current].allSatisfy { $0 == .done })
            #expect(marks[(current + 1)...].allSatisfy { $0 == .pending })
        }
        #expect(CompanionFlowSteps.steps(.launching).first?.mark == .done)
    }

    @Test func aTallPanelShowsAllFourSteps() {
        #expect(CompanionFlowSteps.rowBudget(tall) == 4)
        let rows = CompanionFlowSteps.rows(.launching, maxRows: 4)
        #expect(rows.map(\.kind) == CompanionStepKind.allCases)
        #expect(rows.allSatisfy { $0.hiddenAfter == 0 })
    }

    @Test func aShortPanelFoldsTheLastPendingStep() {
        #expect(CompanionFlowSteps.rowBudget(short) == 3)
        let rows = CompanionFlowSteps.rows(.launching, maxRows: 3)
        #expect(rows.map(\.kind) == [.hostFound, .launchAccepted, .waitingVideo])
        #expect(rows.map(\.hiddenAfter) == [0, 0, 1])
    }

    @Test func theCurrentStepStaysWhenTheOldestDoneOnesLeave() {
        let rows = CompanionFlowSteps.rows(.connected, maxRows: 3)
        #expect(rows.map(\.kind) == [.launchAccepted, .waitingVideo, .streamReady])
        #expect(rows.last?.mark == .current)
        #expect(rows.allSatisfy { $0.hiddenAfter == 0 })
        #expect(CompanionFlowSteps.rows(.connecting, maxRows: 2).map(\.kind) == [.launchAccepted, .waitingVideo])
        #expect(CompanionFlowSteps.rows(.connecting, maxRows: 2).last?.hiddenAfter == 1)
    }

    @Test func theLaunchIsAcceptedOnceAConnectionStageWasTold() {
        #expect(CompanionStartStage.of(progress: 0) == .launching)
        #expect(CompanionStartStage.of(progress: 0.08) == .connecting)
    }

    // MARK: Texts

    @Test func theRequestedLineFallsBackToShorterForms() {
        #expect(CompanionFlowText.requestedForms("1920 × 1080 · HEVC · 120 FPS") == ["1920 × 1080 · HEVC · 120 FPS", "1920 × 1080 · 120 FPS", "1920 × 1080"])
        #expect(CompanionFlowText.requestedForms("1920 × 1080") == ["1920 × 1080"])
        #expect(CompanionFlowText.requestedForms(nil).isEmpty)
        let format = { (pc: String, requested: String) in "\(pc) · \(requested)" }
        let line = CompanionFlowText.requestedLine(
            pc: "Desk", alias: "PC · 7C2A", requested: "1920 × 1080 · HEVC · 120 FPS", format: format, width: 300, metrics: metrics)
        #expect(line == "Desk · 1920 × 1080 · 120 FPS")
        #expect(CompanionFlowText.requestedLine(pc: "Desk", alias: "PC", requested: nil, format: format, width: 230, metrics: metrics) == "Desk")
    }

    @Test func thePCAliasNeedsAnID() {
        #expect(CompanionFlowText.pcAlias("PC", id: "ab-12-7c2a") == "PC · 7C2A")
        #expect(CompanionFlowText.pcAlias("PC", id: "--") == "PC")
    }

    @Test func gameAndPCDropWhatDoesNotFit() {
        #expect(CompanionFlowText.gameAndPC(game: "Hades", pc: "Desk", alias: "PC", width: 500, metrics: metrics) == "Hades · Desk")
        #expect(CompanionFlowText.gameAndPC(game: "Hades", pc: "A very long desktop name", alias: "PC", width: 100, metrics: metrics) == "Hades · PC")
        #expect(CompanionFlowText.gameAndPC(game: "", pc: "Desk", alias: "PC", width: 100, metrics: metrics) == "Desk")
    }

    @Test func aResultIsCutAtASentenceBoundaryOnly() {
        let sentence = "The connection to the PC was lost."
        let guidance = "The app may still be running on the host. Reconnect to resume when available."
        let roomy = CompanionFlowText.resultBody(
            sentence: sentence, guidance: guidance, guidanceShort: "It may still run.", budget: tall, metrics: metrics, last: "See main.")
        #expect(roomy == "\(sentence) \(guidance)")
        var narrow = short
        narrow.innerWidth = 300
        let cut = CompanionFlowText.resultBody(
            sentence: sentence, guidance: guidance, guidanceShort: "It may still run.", budget: narrow, metrics: metrics, last: "See main.")
        #expect(cut == "\(sentence) It may still run.")
        narrow.innerWidth = 10
        #expect(CompanionFlowText.resultBody(sentence: sentence, guidance: guidance, guidanceShort: "Short.", budget: narrow, metrics: metrics, last: "See main.")
            == "See main.")
    }

    @Test func theErrorLineIsTheFirstLineOfTheDetails() {
        let details = "\n  RTSP handshake failed (error 10060)\nMore text."
        #expect(CompanionFlowText.errorLine(details, maxLines: 1, width: 1000, metrics: metrics) == "RTSP handshake failed (error 10060)")
        #expect(CompanionFlowText.errorLine(details, maxLines: 1, width: 100, metrics: metrics) == nil)
        #expect(CompanionFlowText.errorLine(nil, maxLines: 2, width: 1000, metrics: metrics) == nil)
        let text = CompanionFlowText.errorText(sentence: "It failed.", details: details, short: "Short.", budget: tall, metrics: metrics, last: "See main.")
        #expect(text == "It failed. More text.")
    }

    @Test func aResultKindFollowsTheAttempt() {
        #expect(CompanionResultKind.of(title: "Closed", whileStarting: true, closedTitle: "Closed") == .failedToStart)
        #expect(CompanionResultKind.of(title: "Closed", whileStarting: false, closedTitle: "Closed") == .hostClosed)
        #expect(CompanionResultKind.of(title: "Lost", whileStarting: false, closedTitle: "Closed") == .lost)
    }

    // MARK: Filters

    @Test func filterCountsSayAllWhileNothingIsFiltered() {
        #expect(CompanionFilterCount.counting(shown: 12, total: 36, active: true) == .of(shown: 12, total: 36))
        #expect(CompanionFilterCount.counting(shown: 36, total: 36, active: false) == .all(total: 36))
        #expect(CompanionFilterCount.counting(shown: 12, total: nil, active: true) == .matching(shown: 12))
        #expect(CompanionFilterCount.counting(shown: 12, total: nil, active: false) == .all(total: 12))
    }

    @Test func filterChipsShowThreeAndCountTheRest() {
        let labels = CompanionFit.chips(["RPG", "Indie", "HDR", "Short"], maxItems: companionFilterChips, width: 10_000, metrics: metrics) { "+\($0)" }
        #expect(labels == ["RPG", "Indie", "HDR", "+1"])
    }

    @Test func resetIsPrimaryOnlyWhileFiltersAreActive() {
        let on = CompanionFilter.resetAction(label: "Reset", active: true) {}
        let off = CompanionFilter.resetAction(label: "Reset", active: false) {}
        #expect(on.style == .primary && on.enabled)
        #expect(off.style == .normal && !off.enabled)
    }

    @Test func libraryLabelsListTheActiveCriteriaInOrder() {
        #expect(CompanionFilter.libraryLabels(MetadataFilters(), genres: [], themes: []).isEmpty)
        let labels = CompanionFilter.libraryLabels(
            MetadataFilters(genreID: 999_001, themeID: 999_002, hdr: .hdr, length: .under10),
            genres: [GameGenre(id: 999_001, name: "Puzzle")], themes: [])
        #expect(labels == ["Puzzle", L("filters_section_theme"), LibraryFilter.hdrLabel(.hdr), LibraryFilter.lengthLabel(.under10)])
    }

    // MARK: Artwork and profile

    @Test func theArtworkBoxKeepsItsRatioAndNeverCrops() {
        let wide = CompanionArtworkFit.box(width: 1000, height: 400, ratio: 2)
        #expect(wide == CGSize(width: 450, height: 225))
        let tallBox = CompanionArtworkFit.box(width: 1000, height: 300, ratio: 2.0 / 3)
        #expect(tallBox.height == 300 && abs(tallBox.width - 200) < 0.001)
        #expect(CompanionArtworkFit.box(width: 0, height: 100, ratio: 1) == .zero)
        #expect(CompanionArtworkFit.lineCapacity(height: 100, lineHeight: 30, gap: 8) == 2)
    }

    @Test func artLinesKeepTheHighestPrioritiesInOrder() {
        let lines = [
            CompanionArtLine("size", tone: .normal, priority: 90), CompanionArtLine("score", tone: .sea, priority: 70),
            CompanionArtLine("author", tone: .normal, priority: 30), CompanionArtLine("added", tone: .muted, priority: 50),
            CompanionArtLine("in use", tone: .gold, priority: 100),
        ]
        #expect(CompanionArtLine.keepTop(lines, capacity: 3).map(\.text) == ["size", "score", "in use"])
        #expect(CompanionArtLine.keepTop(lines, capacity: 0).isEmpty)
        #expect(CompanionArtLine.keepTop(lines, capacity: 9) == lines)
    }

    @Test func theProfileLineSaysWhatChanged() {
        #expect(CompanionProfileLine.of(settings: nil, overrides: 2) == .unknown)
        #expect(CompanionProfileLine.of(settings: 0, overrides: 0) == .defaults)
        #expect(CompanionProfileLine.of(settings: 3, overrides: 0) == .settings)
        #expect(CompanionProfileLine.of(settings: 0, overrides: 1) == .overrides)
        #expect(CompanionProfileLine.of(settings: 3, overrides: 1) == .both)
        #expect(CompanionProfileLine.customCount(StreamSettings()) == 0)
        var changed = StreamSettings()
        changed.fps = 120
        changed.hdr = true
        #expect(CompanionProfileLine.customCount(changed) == 2)
    }

    @Test func bootListsBackOnlyWhenItCanGoBack() {
        #expect(CompanionBootPage.hints(canGoBack: false, begin: "Begin", back: "Back").map(\.label) == ["Begin"])
        #expect(CompanionBootPage.hints(canGoBack: true, begin: "Begin", back: "Back").map(\.label) == ["Begin", "Back"])
    }
}
