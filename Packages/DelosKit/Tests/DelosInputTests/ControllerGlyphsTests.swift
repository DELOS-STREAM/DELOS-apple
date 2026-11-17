import Testing
@testable import DelosInput

@Suite struct ControllerGlyphsTests {
    private func pad(_ profile: PadDescriptor.Profile, _ category: String = "", _ vendor: String? = nil) -> PadDescriptor {
        PadDescriptor(profile: profile, productCategory: category, vendorName: vendor)
    }

    @Test func theGamepadClassDecidesFirst() {
        #expect(pad(.dualSense, "DualSense", "DualSense Wireless Controller").family == .dualSense)
        #expect(pad(.dualShock, "DualShock 4", "DUALSHOCK 4 Wireless Controller").family == .dualShock)
        #expect(pad(.xbox, "Xbox One", "Xbox Wireless Controller").family == .xbox)
        // A class beats a misleading name
        #expect(pad(.xbox, "HID", "Nintendo Switch Pro Controller").family == .xbox)
    }

    @Test func nintendoPadsAreFoundByName() {
        #expect(pad(.other, "HID", "Pro Controller").family == .nintendo)
        #expect(pad(.other, "HID", "Joy-Con (L/R)").family == .nintendo)
        #expect(pad(.other, "HID", "Nintendo Switch Pro Controller").family == .nintendo)
        #expect(pad(.other, "Nintendo Switch", nil).family == .nintendo)
    }

    @Test func padsWithoutAClassAreFoundByName() {
        #expect(pad(.other, "HID", "Wireless Controller DualSense").family == .dualSense)
        #expect(pad(.other, "HID", "DUALSHOCK 4").family == .dualShock)
        #expect(pad(.other, "HID", "Xbox Elite Wireless Controller").family == .xbox)
    }

    @Test func anUnknownPadIsGeneric() {
        #expect(pad(.other, "MFi", "Some Pad").family == .generic)
        #expect(pad(.other, "HID", nil).family == .generic)
    }

    @Test func theControllerUsedLastWinsOverTheFirstConnected() {
        let ps = pad(.dualSense), xbox = pad(.xbox), nintendo = pad(.other, "HID", "Pro Controller")
        #expect(ControllerGlyphs.choose(current: nil, connected: [ps, xbox]) == .dualSense)
        #expect(ControllerGlyphs.choose(current: xbox, connected: [ps, xbox]) == .xbox)
        #expect(ControllerGlyphs.choose(current: nintendo, connected: [ps, nintendo]) == .nintendo)
    }

    @Test func noControllerOrOnlyARemoteIsGeneric() {
        #expect(ControllerGlyphs.choose(current: nil, connected: []) == .generic)
        let remote = pad(.none, "Siri Remote")
        #expect(ControllerGlyphs.choose(current: remote, connected: [remote]) == .generic)
        // A remote that is current does not hide a pad
        #expect(ControllerGlyphs.choose(current: remote, connected: [remote, pad(.dualShock)]) == .dualShock)
    }

    @Test func faceButtonsFollowThePosition() {
        // The south button confirms on every layout (A = cross = B of a Nintendo pad), the east one goes back
        #expect(PadFamily.xbox.mark(.south) == .letter("A"))
        #expect(PadFamily.generic.mark(.east) == .letter("B"))
        #expect(PadFamily.dualSense.mark(.south) == .cross)
        #expect(PadFamily.dualSense.mark(.east) == .circle)
        #expect(PadFamily.dualShock.mark(.west) == .square)
        #expect(PadFamily.dualShock.mark(.north) == .triangle)
        #expect(PadFamily.nintendo.mark(.south) == .letter("B"))
        #expect(PadFamily.nintendo.mark(.east) == .letter("A"))
        #expect(PadFamily.nintendo.mark(.west) == .letter("Y"))
        #expect(PadFamily.nintendo.mark(.north) == .letter("X"))
    }

    @Test func shouldersAndMenuButtonsFollowTheFamily() {
        #expect(PadFamily.generic.mark(.leftShoulder) == .letter("L1"))
        #expect(PadFamily.dualSense.mark(.rightTrigger) == .letter("R2"))
        #expect(PadFamily.xbox.mark(.leftShoulder) == .letter("LB"))
        #expect(PadFamily.xbox.mark(.rightTrigger) == .letter("RT"))
        #expect(PadFamily.nintendo.mark(.rightShoulder) == .letter("R"))
        #expect(PadFamily.nintendo.mark(.leftTrigger) == .letter("ZL"))
        #expect(PadFamily.nintendo.mark(.menuLeft) == .letter("\u{2212}"))
        #expect(PadFamily.nintendo.mark(.menuRight) == .letter("+"))
        #expect(PadFamily.xbox.mark(.menuLeft) == .view)
        #expect(PadFamily.dualSense.mark(.menuRight) == .menu)
        #expect(PadFamily.dualSense.mark(.touchpad) == .touchpad)
    }

    @Test func everyFamilyMarksEveryRole() {
        for family in PadFamily.allCases {
            for role in GlyphRole.allCases { _ = family.mark(role) }
        }
        #expect(GlyphMark.cross.text == "\u{2715}")
        #expect(GlyphMark.view.text == nil)
    }
}
