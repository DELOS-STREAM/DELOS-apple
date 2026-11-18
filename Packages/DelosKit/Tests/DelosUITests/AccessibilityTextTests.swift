import Foundation
import Testing
@testable import DelosUI

/// What VoiceOver reads of a settings row and a stream menu row, and what its swipe up and down does.
@Suite struct AccessibilityTextTests {
    private func row(_ value: SettingValue, customLine: String? = nil, note: String? = nil, minText: String? = nil, enabled: Bool = true) -> SettingRow {
        SettingRow(
            id: "row", tab: .stream, section: "", icon: "", label: "Bitrate", value: value, help: "", enabled: enabled, note: note,
            customLine: customLine, sliderMinText: minText)
    }

    @Test func aSwitchReadsOnOrOffAndASliderItsNumberWithItsUnit() {
        #expect(row(.toggle(true)).accessibilityValue == L("common_on"))
        #expect(row(.toggle(false)).accessibilityValue == L("common_off"))
        #expect(row(.slider(value: 40, range: 0...100, step: 5, divisor: 1, unit: " %")).accessibilityValue.hasSuffix(" %"))
        #expect(row(.slider(value: 0, range: 0...100, step: 5, divisor: 1, unit: " %"), minText: "0 % (off)").accessibilityValue == "0 % (off)")
        #expect(row(.choice(label: "HEVC", options: ["Auto", "HEVC"], selected: 1)).accessibilityValue == "HEVC")
        #expect(row(.action(label: nil)).accessibilityValue.isEmpty)
    }

    @Test func aCustomRowReadsItsBadgeAndTheProfilesValueAfterItsName() {
        #expect(row(.toggle(true), customLine: "Profile: Off").accessibilityLabel == "Bitrate, \(L("row_badge_custom")), Profile: Off")
        #expect(row(.toggle(true), note: "3 hidden").accessibilityLabel == "Bitrate, 3 hidden")
        #expect(row(.toggle(true)).accessibilityLabel == "Bitrate")
    }

    @Test func onlyAnAvailableChoiceOrSliderIsAdjustable() {
        #expect(row(.choice(label: "A", options: ["A", "B"], selected: 0)).adjustable)
        #expect(row(.slider(value: 1, range: 0...2, step: 1, divisor: 1, unit: "")).adjustable)
        #expect(!row(.toggle(true)).adjustable)
        #expect(!row(.choice(label: "A", options: ["A", "B"], selected: 0), enabled: false).adjustable)
    }

    @MainActor @Test func aStreamMenuSliderStepsOnItsGridAndAChoiceThroughItsStep() {
        var set: [Int] = []
        let slider = StreamMenuRow(
            id: "s", icon: "", label: "", value: .slider(value: 50, range: 5...100, step: 5, unit: " %"), help: "", activate: {},
            set: { set.append($0) })
        #expect(slider.adjustable)
        slider.adjust(1)
        slider.adjust(-1)
        #expect(set == [55, 45])
        var steps: [Int] = []
        let choice = StreamMenuRow(
            id: "c", icon: "", label: "", value: .choice(label: "B", options: ["A", "B"], selected: 1), help: "", activate: {},
            step: { steps.append($0) })
        #expect(choice.adjustable && choice.accessibilityValue == "B")
        choice.adjust(-1)
        #expect(steps == [-1])
        let toggle = StreamMenuRow(id: "t", icon: "", label: "", value: .toggle(true), help: "", activate: {})
        #expect(!toggle.adjustable && toggle.accessibilityValue == L("common_on"))
        let confirmed = StreamMenuRow(id: "p", icon: "", label: "", value: .action, help: "", activate: {}, confirmation: "Active")
        #expect(confirmed.accessibilityValue == "Active")
    }
}
