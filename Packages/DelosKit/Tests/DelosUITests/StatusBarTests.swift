import DelosData
import Foundation
import SwiftUI
import Testing
@testable import DelosUI

@Suite struct StatusClockTests {
    /// 2026-11-16 15:07:00 UTC.
    let date = Date(timeIntervalSince1970: 1_795_360_020)
    let utc = TimeZone(identifier: "UTC")!

    @Test func twelveAndTwentyFourHoursInTheLanguage() {
        let us = Locale(identifier: "en_US")
        #expect(StatusClock.text(date, format: .h12, locale: us, timeZone: utc) == "3:07 PM")
        #expect(StatusClock.text(date, format: .h24, locale: us, timeZone: utc) == "15:07")
        let czech = Locale(identifier: "cs_CZ")
        #expect(StatusClock.text(date, format: .h24, locale: czech, timeZone: utc) == "15:07")
        #expect(StatusClock.text(date, format: .h12, locale: czech, timeZone: utc).hasPrefix("3:07"))
    }

    @Test func systemFollowsTheLocalesHourCycle() {
        #expect(!StatusClock.uses24Hours(.system, locale: Locale(identifier: "en_US")))
        #expect(StatusClock.uses24Hours(.system, locale: Locale(identifier: "de_DE")))
        // The device's 24-Hour Time switch reaches the locale as its hour cycle
        #expect(StatusClock.uses24Hours(.system, locale: Locale(identifier: "en_US@hours=h23")))
        #expect(!StatusClock.uses24Hours(.system, locale: Locale(identifier: "de_DE@hours=h12")))
        #expect(!StatusClock.uses24Hours(.h12, locale: Locale(identifier: "de_DE")))
        #expect(StatusClock.uses24Hours(.h24, locale: Locale(identifier: "en_US")))
    }

    @Test func theNarrowNoBreakSpaceBeforeAMOrPMBecomesASpace() {
        for id in ["en_US", "en_GB", "ja_JP", "ko_KR", "zh_CN", "pl_PL", "fr_FR", "es_ES", "it_IT", "pt_BR"] {
            let text = StatusClock.text(date, format: .h12, locale: Locale(identifier: id), timeZone: utc)
            #expect(!text.contains("\u{202F}"), "\(id): \(text)")
            #expect(!StatusClock.pattern(.h12, locale: Locale(identifier: id)).contains("\u{202F}"))
        }
    }
}

@Suite struct DeviceStatusTests {
    @Test func theBatteryIsGreenAboveTwentyPercentOrWhileCharging() {
        #expect(BatteryStatus(level: 0.21, charging: false).low == false)
        #expect(BatteryStatus(level: 0.2, charging: false).low)
        #expect(BatteryStatus(level: 0.05, charging: false).low)
        #expect(BatteryStatus(level: 0.05, charging: true).low == false)
    }

    @Test func theChargeFillsAtLeastASliverAndThePercentIsRounded() {
        #expect(BatteryStatus(level: 0, charging: false).fill == 0.04)
        #expect(BatteryStatus(level: 0.5, charging: false).fill == 0.5)
        #expect(BatteryStatus(level: 0.875, charging: false).percent == "88%")
        #expect(BatteryStatus(level: 1, charging: false).percent == "100%")
        #expect(BatteryStatus(level: 0.004, charging: false).percent == "0%")
    }

    @Test func anUnknownBatteryIsNotShown() {
        #expect(BatteryStatus(level: -1, state: .unknown) == nil)
        #expect(BatteryStatus(level: 0.5, state: .unknown) == nil)
        #expect(BatteryStatus(level: -1, state: .unplugged) == nil)
        #expect(BatteryStatus(level: 0.5, state: .unplugged) == BatteryStatus(level: 0.5, charging: false))
        #expect(BatteryStatus(level: 0.5, state: .charging)?.charging == true)
        #expect(BatteryStatus(level: 1, state: .full)?.charging == true)
    }

    @Test func wifiShowsOnlyForASatisfiedWifiPath() {
        #expect(WifiStatus(satisfied: true, usesWifi: true) == .connected)
        #expect(WifiStatus(satisfied: false, usesWifi: true) == .none)
        #expect(WifiStatus(satisfied: true, usesWifi: false) == .none)
        #expect(WifiStatus.connected.icon == Symbols.wifi)
        #expect(WifiStatus.none.icon == Symbols.wifiOff)
    }
}

/// The cases of `StatusBarFitTest` in DELOS for Android.
@Suite struct StatusBarFitTests {
    let c = StatusBarLayout.self

    @Test func theNavigationPillsWidth() {
        #expect(c.navWidth(buttons: 0, button: 56, gap: 14) == 0)
        #expect(c.navWidth(buttons: 3, button: 56, gap: 14) == 3 * 56 + 2 * 14 + 16)
        #expect(c.navWidth(buttons: 2, button: 64, gap: 6) == 2 * 64 + 6 + 16)
    }

    @Test func placeBetweenCentresWhenItFitsElseUsesTheFreeSpace() {
        #expect(c.placeBetween(start: 0, end: 100, width: 20, centre: 50) == 40)
        #expect(c.placeBetween(start: 50, end: 100, width: 20, centre: 50) == 65)
        #expect(c.placeBetween(start: 0, end: 10, width: 20, centre: 5) == nil)
    }

    @Test func aWideBarKeepsTheNavigationCentred() {
        let fit = c.fit(width: 1488, sideLeft: 72, sideRight: 72) { _ in StatusBarWidths(left: 200, nav: 200, right: 260) }
        #expect(fit.step == .full && fit.centred && fit.fits)
        #expect(fit.navX == 744 - 100)
    }

    @Test func aLopsidedBarMovesTheNavigationIntoTheFreeSpace() {
        let fit = c.fit(width: 1200, sideLeft: 72, sideRight: 72) { _ in StatusBarWidths(left: 500, nav: 200, right: 200) }
        #expect(fit.step == .full && !fit.centred && fit.fits)
        let start = 72.0 + 500 + 24, end = 1200.0 - 72 - 200 - 24
        #expect(fit.navX == start + (end - start - 200) / 2)
    }

    @Test func aNarrowBarTightensThenDropsThePercentage() {
        let widths: (StatusBarStep) -> StatusBarWidths = { step in
            switch step {
            case .full: StatusBarWidths(left: 300, nav: 220, right: 330)
            case .tight: StatusBarWidths(left: 300, nav: 200, right: 300)
            case .noPercent: StatusBarWidths(left: 300, nav: 200, right: 240)
            }
        }
        // The navigation needs 822, 792 and 732 stage pixels beside it
        let tight = c.fit(width: 1000, sideLeft: 72, sideRight: 72, widths: widths)
        #expect(tight.step == .tight && tight.fits)
        let bare = c.fit(width: 950, sideLeft: 72, sideRight: 72, widths: widths)
        #expect(bare.step == .noPercent && bare.fits)
        let none = c.fit(width: 800, sideLeft: 72, sideRight: 72, widths: widths)
        #expect(none.step == .noPercent && !none.fits && !none.centred)
        #expect(none.navX == 72 + 300 + (800 - 144 - 300 - 240 - 200) / 2)
    }

    @Test func aMissingClusterNeedsNoGap() {
        let fit = c.fit(width: 600, sideLeft: 72, sideRight: 72) { _ in StatusBarWidths(left: 0, nav: 200, right: 0) }
        #expect(fit.centred && fit.navX == 200)
    }
}

/// The interface scale: text grows with it, the bars are zoomed as a whole (Android's `tpx` and `ZoomedBar`).
@Suite struct InterfaceScaleTests {
    @Test func textGrowsWithTheScaleAndSizesDoNot() {
        let stage = Stage(size: CGSize(width: 932, height: 430), textScale: 1.3)
        #expect(stage.scale == Stage.minPointsPerPixel)
        #expect(abs(stage.px(100) - 43) < 1e-9)
        #expect(abs(stage.tpx(100) - 55.9) < 1e-9)
        #expect(Stage(size: CGSize(width: 932, height: 430)).tpx(100) == Stage(size: CGSize(width: 932, height: 430)).px(100))
    }

    @Test func aZoomedBarHasFewerLargerStagePixels() {
        let stage = Stage(size: CGSize(width: 932, height: 430), safeArea: EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59),
                          textScale: 1.3)
        let bar = stage.zoomed(by: stage.textScale)
        #expect(abs(bar.scale - stage.scale * 1.3) < 1e-12)
        #expect(abs(bar.width - stage.width / 1.3) < 1e-9 && abs(bar.height - stage.height / 1.3) < 1e-9)
        #expect(abs(bar.safe.leading - stage.safe.leading / 1.3) < 1e-9)
        #expect(bar.textScale == 1)
        #expect(bar.shape == stage.shape)
        // The same points across: the bar's stage covers the window
        #expect(abs(bar.px(bar.width) - stage.px(stage.width)) < 1e-9)
        // Text in the bar is as large as text outside it
        #expect(abs(bar.tpx(24) - stage.tpx(24)) < 1e-9)
        // Zoomed again it stays
        #expect(bar.zoomed(by: bar.textScale) == bar)
    }

    @Test func atOneHundredPercentTheBarIsTheStage() {
        let stage = Stage(size: CGSize(width: 1376, height: 1032))
        #expect(stage.zoomed(by: stage.textScale) == stage)
    }
}
