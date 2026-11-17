import CoreText
import DelosInput
import Testing
@testable import DelosUI

@MainActor @Suite struct ControllerFontGlyphTests {
    @Test func faceButtonsPreservePhysicalPositions() {
        let roles: [GlyphRole] = [.south, .east, .west, .north]
        let expected: [(PadFamily, [String])] = [
            (.generic, [Symbols.padXboxA, Symbols.padXboxB, Symbols.padXboxX, Symbols.padXboxY]),
            (.xbox, [Symbols.padXboxA, Symbols.padXboxB, Symbols.padXboxX, Symbols.padXboxY]),
            (.dualSense, [Symbols.padDualsenseCross, Symbols.padDualsenseCircle, Symbols.padDualsenseSquare, Symbols.padDualsenseTriangle]),
            (.dualShock, [Symbols.padDualshock4Cross, Symbols.padDualshock4Circle, Symbols.padDualshock4Square, Symbols.padDualshock4Triangle]),
            (.nintendo, [Symbols.padJoyconB, Symbols.padJoyconA, Symbols.padJoyconY, Symbols.padJoyconX]),
        ]
        for (family, symbols) in expected {
            #expect(roles.map { ControllerFontGlyph.symbol($0, family: family) } == symbols)
        }
    }

    @Test func shouldersAndTriggersUseFamilyCaps() {
        let roles: [GlyphRole] = [.leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger]
        let expected: [(PadFamily, [String])] = [
            (.generic, [Symbols.padDualsenseL1, Symbols.padDualsenseR1, Symbols.padDualsenseL2, Symbols.padDualsenseR2]),
            (.xbox, [Symbols.padXboxLb, Symbols.padXboxRb, Symbols.padXboxLt, Symbols.padXboxRt]),
            (.dualSense, [Symbols.padDualsenseL1, Symbols.padDualsenseR1, Symbols.padDualsenseL2, Symbols.padDualsenseR2]),
            (.dualShock, [Symbols.padDualshock4L1, Symbols.padDualshock4R1, Symbols.padDualshock4L2, Symbols.padDualshock4R2]),
            (.nintendo, [Symbols.padJoyconL, Symbols.padJoyconR, Symbols.padJoyconZl, Symbols.padJoyconZr]),
        ]
        for (family, symbols) in expected {
            #expect(roles.map { ControllerFontGlyph.symbol($0, family: family) } == symbols)
        }
    }

    @Test func menuSticksDpadAndGuideUseTheirCompleteFamilyGlyphs() {
        let roles: [GlyphRole] = [.menuLeft, .menuRight, .leftStick, .rightStick, .dpad, .guide, .touchpad]
        let expected: [(PadFamily, [String])] = [
            (.generic, [Symbols.padXboxView, Symbols.padXboxMenu, Symbols.padXboxStickLClick, Symbols.padXboxStickRClick, Symbols.padXboxDpadNeutral, Symbols.padXboxGuide, Symbols.padDualsenseTouchpad]),
            (.xbox, [Symbols.padXboxView, Symbols.padXboxMenu, Symbols.padXboxStickLClick, Symbols.padXboxStickRClick, Symbols.padXboxDpadNeutral, Symbols.padXboxGuide, Symbols.padDualsenseTouchpad]),
            (.dualSense, [Symbols.padDualsenseCreate, Symbols.padDualsenseOptions, Symbols.padDualsenseStickLClick, Symbols.padDualsenseStickRClick, Symbols.padDualsenseDpadNeutral, Symbols.padDualsensePs, Symbols.padDualsenseTouchpad]),
            (.dualShock, [Symbols.padDualshock4Share, Symbols.padDualshock4Options, Symbols.padDualshock4StickLClick, Symbols.padDualshock4StickRClick, Symbols.padDualshock4DpadNeutral, Symbols.padDualshock4Ps, Symbols.padDualshock4Touchpad]),
            (.nintendo, [Symbols.padJoyconMinus, Symbols.padJoyconPlus, Symbols.padJoyconStickLClick, Symbols.padJoyconStickRClick, Symbols.padJoyconDpadNeutral, Symbols.padJoyconHome, Symbols.padDualsenseTouchpad]),
        ]
        for (family, symbols) in expected {
            #expect(roles.map { ControllerFontGlyph.symbol($0, family: family) } == symbols)
        }
    }

    @Test func everyFamilyAndRoleExistsInBothBundledFontStyles() throws {
        #expect(DelosFonts.register().isEmpty)
        for name in ["Phosphor", "Phosphor-Fill"] {
            let font = CTFontCreateWithName(name as CFString, 50, nil)
            #expect(CTFontCopyPostScriptName(font) as String == name)
            let characters = CTFontCopyCharacterSet(font)
            for family in PadFamily.allCases {
                for role in GlyphRole.allCases {
                    let symbol = ControllerFontGlyph.symbol(role, family: family)
                    #expect(symbol.unicodeScalars.count == 1)
                    let scalar = try #require(symbol.unicodeScalars.first)
                    #expect(CFCharacterSetIsLongCharacterMember(characters, scalar.value), "Missing \(family) / \(role) in \(name)")
                }
            }
        }
    }

}
