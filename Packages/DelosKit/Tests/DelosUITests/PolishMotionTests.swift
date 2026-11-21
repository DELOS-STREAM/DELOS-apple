import Accessibility
import Foundation
import SwiftUI
import Testing
@testable import DelosUI

@MainActor @Suite struct PolishMotionTests {
    @Test func thePlateFollowsTheWholeScaledRowIncludingVariableHeight() {
        let row = CGRect(x: 18, y: 54, width: 1000, height: 92)
        #expect(SettingsPlateGeometry.target(row) == CGRect(x: 8, y: 53.08, width: 1020, height: 93.84))
        let taller = SettingsPlateGeometry.target(CGRect(x: 18, y: 200, width: 1000, height: 160))
        #expect(taller.minY == 198.4)
        #expect(taller.height == 163.2)
        #expect(SettingsPlateGeometry.target(.zero) == .zero)
        #expect(SettingsPlateGeometry.duration == 0.520)
    }

    @Test func screenTimingKeepsTheOldScreenLeavingFasterThanTheNewOneSettles() {
        #expect(ScreenMotion.enter == 0.560)
        #expect(ScreenMotion.fade == 0.280)
        #expect(ScreenMotion.exit == 0.240)
        #expect(ScreenMotion.scale > 1)
    }

    @Test func theLastTabSurvivesAVisitButNotANewSession() {
        let session = SettingsSession()
        session.tab = .appearance
        #expect(session.opening() == .appearance)
        #expect(session.opening(.audio) == .audio)
        #expect(SettingsSession().opening() == .stream)
        if !SettingsTab.availableCases.contains(.about) {
            session.tab = .about
            #expect(session.opening() == .stream)
        }
    }

    @Test func marqueeWaitsTravelsAtReadingSpeedThenResetsForTheLoopPause() {
        #expect(SettingsReadingMotion.marqueeOffset(elapsed: 0.699, width: 56) == 0)
        #expect(abs(SettingsReadingMotion.marqueeOffset(elapsed: 1.7, width: 56) - 56) < 0.0001)
        #expect(SettingsReadingMotion.marqueeOffset(elapsed: 3.0, width: 56) == 0)
        #expect(abs(SettingsReadingMotion.marqueeOffset(elapsed: 4.6, width: 56) - 56) < 0.0001)
        #expect(SettingsReadingMotion.marqueeOffset(elapsed: 2, width: 0) == 0)
    }

    @Test func bouncingMarqueePausesAtBothEndsWithoutWrapping() {
        func offset(_ elapsed: Double) -> Double {
            SettingsReadingMotion.bounceOffset(elapsed: elapsed, travel: 112, speed: 56)
        }
        #expect(offset(0.699) == 0)
        #expect(abs(offset(1.7) - 56) < 0.0001)
        #expect(abs(offset(2.7) - 112) < 0.0001)
        #expect(abs(offset(3.5) - 112) < 0.0001)
        #expect(abs(offset(4.6) - 56) < 0.0001)
        #expect(abs(offset(5.6)) < 0.0001)
        #expect(abs(offset(6.4)) < 0.0001)
        #expect(abs(offset(7.5) - 56) < 0.0001)
        #expect(SettingsReadingMotion.bounceOffset(elapsed: 2, travel: 0) == 0)
        #expect(SettingsReadingMotion.bounceOffset(elapsed: 2, travel: 112, speed: 0) == 0)
    }

    @Test func helpReadingSpeedAndPausesAreBounded() {
        #expect(SettingsReadingMotion.helpDuration(overflow: 100) == 5)
        #expect(SettingsReadingMotion.helpDuration(overflow: 1) == 1)
        #expect(SettingsReadingMotion.helpDuration(overflow: 10_000) == 120)
        #expect(SettingsReadingMotion.helpFirstPause == 3)
        #expect(SettingsReadingMotion.helpEndPause == 2.5)
    }

    @Test func anErrorInterruptsButOrdinarySpeechWaitsAndUndoIsIncluded() {
        let error = ToastAnnouncement(toast(kind: .error))
        #expect(error.urgent)
        #expect(error.speech.accessibilitySpeechAnnouncementPriority == .high)
        #expect(error.text == "ERROR. message")
        let ordinary = ToastAnnouncement(toast(kind: .info))
        #expect(!ordinary.urgent)
        #expect(ordinary.speech.accessibilitySpeechAnnouncementPriority == .low)
        #expect(ordinary.text == "INFO. message")
        let undo = ToastAnnouncement(toast(kind: .action, action: ToastAction(label: "Undo", run: {})))
        #expect(undo.text == "UNDO. message. Undo")
        #expect(!undo.urgent)
    }

    private func toast(kind: ToastKind, action: ToastAction? = nil) -> Toast {
        Toast(id: 1, text: "message", icon: nil, action: action, durationMs: 4500, kind: kind)
    }
}
