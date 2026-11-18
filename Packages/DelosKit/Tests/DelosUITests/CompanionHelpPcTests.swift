import DelosHost
import DelosInput
import Testing
@testable import DelosUI

/// The settings help's fit (`CompanionHelpTest` of DELOS for Android).
@Suite struct CompanionHelpFitTests {
    let metrics = FakeMetrics()

    @Test func headingKeepsATitleThatFits() {
        // 400 wide less the 80 of the disc: 16 title letters
        #expect(HelpFit.heading(title: "Bitrate", section: "Settings · Stream", width: 400, metrics: metrics)
            == CompanionHelpHeading(title: "Bitrate", subtitle: "Settings · Stream"))
    }

    @Test func headingSwapsInThePlaceWhenTheTitleIsTooLong() {
        let title = "Frame pacing and smoothing"
        #expect(HelpFit.heading(title: title, section: "Display", width: 400, metrics: metrics)
            == CompanionHelpHeading(title: "Display", subtitle: title))
        // The full title does not fit the small line either: left out, never cut
        let longer = String(repeating: "x", count: 40)
        #expect(HelpFit.heading(title: longer, section: "Display", width: 400, metrics: metrics) == CompanionHelpHeading(title: "Display", subtitle: nil))
        // No place that fits: the title stays (the line cuts it)
        #expect(HelpFit.heading(title: title, section: "A very long section name", width: 400, metrics: metrics)
            == CompanionHelpHeading(title: title, subtitle: "A very long section name"))
    }

    @Test func sourceSplitsAtTheMarker() {
        let source = CompanionHelpSource.make(
            custom: true, icon: "", title: "Custom", sentence: "Profile value: \u{1}. Press X to go back.", marker: "\u{1}", strong: "720p")
        #expect(source.before == "Profile value: ")
        #expect(source.strong == "720p")
        #expect(source.after == ". Press X to go back.")
        let plain = CompanionHelpSource.make(custom: false, icon: "", title: "T", sentence: "No marker.", marker: "\u{1}", strong: "x")
        #expect(plain.before == "No marker." && plain.strong.isEmpty && plain.after.isEmpty)
    }

    @Test func sourceKeepsWholeSentencesBehindItsTitle() {
        let source = CompanionHelpSource.make(
            custom: true, icon: "", title: "Custom", sentence: "Profile value: \u{1}. Press X to go back.", marker: "\u{1}", strong: "720p")
        #expect(HelpFit.source(source, maxLines: 2, width: 1000, metrics: metrics)
            == CompanionSourceView(title: "Custom", before: "Profile value: ", strong: "720p", after: ". Press X to go back."))
        // 300 of room: "Custom Profile value: 720p." fits one line, the second sentence does not
        #expect(HelpFit.source(source, maxLines: 1, width: 390, metrics: metrics)
            == CompanionSourceView(title: "Custom", before: "Profile value: ", strong: "720p", after: "."))
        // Not even the first sentence: the title alone
        #expect(HelpFit.source(source, maxLines: 1, width: 150, metrics: metrics) == CompanionSourceView(title: "Custom", before: "", strong: "", after: ""))
    }

    @Test func valueKeepsItsEndBehindAnEllipsis() {
        #expect(HelpFit.value("short", maxLines: 1, width: 100, metrics: metrics) == "short")
        let cut = HelpFit.value("/very/long/path/name", maxLines: 1, width: 100, metrics: metrics)
        #expect(cut == "\u{2026}path/name")
    }

    @Test func prepareEndsEveryLineWithAMark() {
        #expect(HelpFit.prepare("Balanced\nSmooths the frames") == "Balanced.\nSmooths the frames.")
        #expect(HelpFit.prepare("Done!\n\nWhat?") == "Done!\n\nWhat?")
        #expect(HelpFit.prepare("1.5x  ") == "1.5x.")
        #expect(HelpFit.prepare("日本語") == "日本語\u{3002}")
        #expect(CompanionFit.sentences(HelpFit.prepare("Balanced\nSmooths the frames")) == ["Balanced.", "Smooths the frames."])
    }

    @Test func swatchesShareARowOnlyWhenAllFit() {
        // 40 + 60 + 60 of names, 3 × 70 of chrome and 2 × 8 of gaps: 386
        #expect(HelpFit.swatchesInRow(["Main", "Second", "Accent"], width: 386, metrics: metrics))
        #expect(!HelpFit.swatchesInRow(["Main", "Second", "Accent"], width: 385, metrics: metrics))
    }

    @Test func bodyLinesGiveWayToOtherBlocks() {
        let tall = CompanionFit.budget(CompanionPanel(width: 1200, height: 1000))
        let short = CompanionFit.budget(CompanionPanel(width: 1200, height: 700))
        var help = CompanionHelp(identity: "a", icon: "", title: "A", body: "B")
        #expect(HelpFit.bodyLines(help, budget: tall) == tall.helpLines)
        help.value = "x"
        #expect(HelpFit.bodyLines(help, budget: tall) == 4)
        #expect(HelpFit.bodyLines(help, budget: short) == 2)
        help.swatches = [CompanionHelpSwatch(color: RGBA(red: 1, green: 0, blue: 0), label: "Main")]
        #expect(HelpFit.bodyLines(help, budget: tall) == 3)
        #expect(HelpFit.bodyLines(help, budget: short) == 1)
    }

    @Test func descriptionHidesOnlyWhileAWindowShowsTheHelp() {
        let help = CompanionHelp(identity: "a", icon: "", title: "A", body: "B")
        #expect(companionHidesDescription(windowShowsHelp: true, help: help))
        #expect(!companionHidesDescription(windowShowsHelp: false, help: help))
        #expect(!companionHidesDescription(windowShowsHelp: true, help: nil))
    }

    @Test func shortFormFallsBackToTheFirstSentenceThenTheTitle() {
        #expect(companionHelpShort(summary: " One line. ", body: "First. Second.", title: "T") == "One line.")
        #expect(companionHelpShort(summary: nil, body: "First. Second.", title: "T") == "First.")
        #expect(companionHelpShort(summary: "", body: "", title: "T") == "T")
    }
}

/// The PC pages' data and decisions (`CompanionPcPageTest` of DELOS for Android).
@Suite struct CompanionPcDataTests {
    private func pc(
        online: Bool = true, canWake: Bool = false, nvidia: Bool = false, running: Int = 0, defaultID: String? = nil, library: String? = "pc1",
        apps: [HostApp]? = [HostApp(id: 1, title: "Hades"), HostApp(id: 2, title: "Celeste")], name: String = "Den", serverName: String = "Den",
        defaultKnown: Bool = true
    ) -> CompanionPcData {
        CompanionPcCard.make(
            id: "pc1", name: name, serverName: serverName, online: online, canWake: canWake, nvidia: nvidia, runningAppID: running,
            defaultID: defaultID, libraryHostID: library, apps: apps, defaultKnown: defaultKnown)
    }

    @Test func statusFollowsReachabilityAndMac() {
        #expect(CompanionPcCard.status(online: true, canWake: false) == .online)
        #expect(CompanionPcCard.status(online: false, canWake: true) == .asleep)
        #expect(CompanionPcCard.status(online: false, canWake: false) == .offline)
    }

    @Test func onlinePcWithItsLibrary() {
        let d = pc(nvidia: false, running: 2, defaultID: "pc1")
        #expect(d.connected)
        #expect(d.isDefault == true)
        #expect(d.apps == 2)
        #expect(!d.appsCached)
        #expect(d.busy)
        #expect(d.runningGame == "Celeste")
        #expect(d.software == .sunshine)
        #expect(pc(nvidia: true).software == .geforce)
    }

    @Test func offlinePcKnowsOnlyWhatIsStored() {
        let d = pc(online: false, canWake: true, running: 2)
        #expect(d.status == .asleep)
        #expect(!d.connected)
        #expect(d.software == nil)
        #expect(d.appsCached)
        #expect(!d.busy)
        #expect(d.runningGame == nil)
        // Another PC's library is no source of this one's count
        #expect(pc(library: "other").apps == nil)
        #expect(pc(defaultKnown: false).isDefault == nil)
    }

    @Test func knownFactsComeFirst() {
        #expect(CompanionPcCard.facts(pc()) == [.flags, .host, .library, .session, .lastSeen, .version])
        // The host name only when the user named the PC differently
        #expect(CompanionPcCard.facts(pc(name: "Den", serverName: "DESKTOP-7")).contains(.hostName))
        let offline = pc(online: false, library: nil, apps: nil, defaultKnown: false)
        #expect(CompanionPcCard.facts(offline) == [.wake, .flags, .library, .lastSeen, .host, .session, .version])
        #expect(CompanionPcCard.select(CompanionPcCard.facts(pc()), max: 2) { $0 != .host } == [.flags, .library])
    }

    @Test func buttonsFollowStatusAndScreen() {
        #expect(CompanionPcCard.actions(pc(), context: .devices) == CompanionPcActionSet(primary: [.library, .rename, .defaultOn], separated: [.unpair, .remove]))
        #expect(CompanionPcCard.actions(pc(defaultID: "pc1"), context: .start)
            == CompanionPcActionSet(primary: [.library, .rename, .defaultOff], separated: [.remove]))
        #expect(CompanionPcCard.actions(pc(online: false, canWake: true), context: .devices).primary.first == .wake)
        #expect(CompanionPcCard.actions(pc(online: false), context: .devices) == CompanionPcActionSet(primary: [.search, .rename, .defaultOn], separated: [.remove]))
        #expect(CompanionPcCard.actions(pc(online: false), context: .home) == CompanionPcActionSet(primary: [.search, .rename], separated: []))
        #expect(CompanionPcCard.actions(pc(), context: .pair).separated.isEmpty)
    }

    @Test func buttonsShareARowWhileTheWidestLabelFits() {
        #expect(CompanionPcCard.buttonsPerRow([100, 100, 100], available: 500, gap: 8, padding: 44) == 3)
        #expect(CompanionPcCard.buttonsPerRow([100, 200, 100], available: 500, gap: 8, padding: 44) == 2)
        #expect(CompanionPcCard.buttonsPerRow([400], available: 300, gap: 8, padding: 44) == 1)
        #expect(CompanionPcCard.buttonsPerRow([], available: 300, gap: 8, padding: 44) == 1)
    }

    @Test func mainHintQuotesTheFirstButtonLetter() {
        let hints = [CompanionHint(button: .tap, label: "Open"), CompanionHint(button: .pad(.south), label: "Connect"), CompanionHint(button: .adjust, label: "Move")]
        let found = CompanionPcCard.mainHint(hints, keys: [nil, "A", nil])
        #expect(found?.hint.label == "Connect")
        #expect(found?.key == "A")
        #expect(found?.rest == 2)
        #expect(CompanionPcCard.mainHint(hints, keys: [nil, nil, nil]) == nil)
    }

    @Test func focusedIDStripsThePrefix() {
        #expect(CompanionPcCard.focusedID(AnyHashable("pc-abc"), prefix: "pc-") == "abc")
        #expect(CompanionPcCard.focusedID(AnyHashable("pair"), prefix: "pc-") == nil)
        #expect(CompanionPcCard.focusedID(nil, prefix: "pc-") == nil)
    }

    @Test func pinDigitsFillTheBoxWithoutWrapping() {
        // Width-bound: 400 wide, the PIN 200 wide at 100
        #expect(CompanionPinFit.fontSize(boxWidth: 400, boxHeight: 1000, widthAtRef: 200, ref: 100) == 200)
        // Height-bound: 120 high at a line of 2
        #expect(CompanionPinFit.fontSize(boxWidth: 4000, boxHeight: 120, widthAtRef: 200, ref: 100, lineRatio: 2) == 60)
        #expect(CompanionPinFit.fontSize(boxWidth: 0, boxHeight: 120, widthAtRef: 200, ref: 100) == 0)
    }
}
