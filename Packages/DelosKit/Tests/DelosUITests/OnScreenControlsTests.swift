import DelosCore
import DelosData
import DelosInput
import Foundation
import Testing
@testable import DelosUI

private typealias Layout = [OscElementID: OscSlot]

private func layout(_ width: Int, _ height: Int, onlyL3R3: Bool = false, showGuide: Bool = true) -> Layout {
    Dictionary(uniqueKeysWithValues: OscDefaultLayout.compute(OscPanel(width: width, height: height), onlyL3R3: onlyL3R3, showGuide: showGuide)
        .map { ($0.id, $0.slot) })
}

/// The panels of iPhones and iPads (their screens in pixels, both orientations) and Android's shapes
/// (`OscGeometryTest.SHAPES`).
private let shapes: [(name: String, width: Int, height: Int)] = [
    ("iPhone 18 Pro Max landscape", 2868, 1320), ("iPhone 18 Pro Max portrait", 1320, 2868),
    ("iPhone SE landscape", 1334, 750), ("iPhone SE portrait", 750, 1334),
    ("iPad Pro 13 landscape", 2752, 2064), ("iPad Pro 13 portrait", 2064, 2752),
    ("iPad mini landscape", 2266, 1488), ("iPad 11 landscape", 2360, 1640),
    ("1:1", 720, 720), ("5:4", 1280, 1024), ("4:3", 960, 720), ("3:2", 960, 640), ("16:10", 1920, 1200),
    ("16:9 1080p", 1920, 1080), ("16:9 720p", 1280, 720), ("20:9", 2400, 1080), ("21:9", 2520, 1080), ("32:9", 3840, 1080),
]

/// The default layout on every shape (`OscGeometryTest`, `OscPlacementTest` of DELOS for Android, docs/gui/SCREEN_SHAPES.md
/// §9.1 and §9.2 there).
@Suite struct OnScreenControlsLayoutTests {
    @Test func theLayoutOf1080pIsAndroidsToThePixel() {
        let m = layout(1920, 1080)
        #expect(m[.dpad] == OscSlot(left: 60, top: 615, width: 450, height: 450))
        #expect(m[.a] == OscSlot(left: 1590, top: 315, width: 150, height: 150))
        #expect(m[.rightStick] == OscSlot(left: 1470, top: 630, width: 390, height: 390))
        #expect(m[.guide] == OscSlot(left: 870, top: 960, width: 180, height: 105))
        #expect(m[.back] == OscSlot(left: 660, top: 960, width: 180, height: 105))
        #expect(m[.start] == OscSlot(left: 1080, top: 960, width: 180, height: 105))
        #expect(m[.touchpad] == OscSlot(left: 810, top: 780, width: 300, height: 150))
        #expect(m[.leftStick] == OscSlot(left: 90, top: 60, width: 390, height: 390))
        #expect(m[.leftTrigger] == OscSlot(left: 15, top: 465, width: 180, height: 135))
        #expect(m[.rightStickButton] == OscSlot(left: 1725, top: 900, width: 180, height: 135))
    }

    @Test func theElementsAreTheSettingsOnesInAndroidsOrder() {
        let all = OscDefaultLayout.compute(OscPanel(width: 1920, height: 1080), onlyL3R3: false, showGuide: true).map(\.id)
        #expect(all == [.dpad, .a, .b, .x, .y, .leftTrigger, .rightTrigger, .leftBumper, .rightBumper, .leftStick, .rightStick,
                        .back, .start, .leftStickButton, .rightStickButton, .touchpad, .guide])
        #expect(OscDefaultLayout.compute(OscPanel(width: 1920, height: 1080), onlyL3R3: true, showGuide: false).map(\.id)
            == [.leftStickButton, .rightStickButton])
        #expect(!layout(1920, 1080, showGuide: false).keys.contains(.guide))
    }

    @Test func squarerThanThreeToTwoShrinksByTheWidth() {
        #expect(abs(OscPanel(width: 720, height: 720).scale - 2 / 3) < 1e-6)
        #expect(abs(OscPanel(width: 960, height: 720).scale - 8 / 9) < 1e-6)
        #expect(OscPanel(width: 960, height: 640).scale == 1)
        #expect(OscPanel(width: 2868, height: 1320).scale == 1, "an iPhone in landscape keeps the classic grid")
        #expect(abs(OscPanel(width: 2752, height: 2064).scale - Float(2 * 2752) / Float(3 * 2064)) < 1e-6, "an iPad shrinks")
    }

    @Test func everyElementIsOnThePanelOnEveryShape() {
        for shape in shapes {
            for (id, r) in layout(shape.width, shape.height) {
                let what = "\(shape.name) \(id) \(r)"
                #expect(r.left >= 0 && r.top >= 0, "\(what)")
                #expect(r.right <= shape.width && r.bottom <= shape.height, "\(what)")
                #expect(r.width > 0 && r.height > 0, "\(what)")
            }
        }
    }

    @Test func theMiddleIsCentredAndSymmetricOnEveryShape() {
        for shape in shapes {
            let m = layout(shape.width, shape.height)
            guard let guide = m[.guide], let pad = m[.touchpad], let back = m[.back], let start = m[.start] else {
                Issue.record("\(shape.name): a middle control is missing")
                continue
            }
            let center = Double(shape.width) / 2
            #expect(abs(Double(guide.left) + Double(guide.width) / 2 - center) <= 1.5, "\(shape.name) Guide")
            #expect(abs(Double(pad.left) + Double(pad.width) / 2 - center) <= 1.5, "\(shape.name) trackpad")
            #expect(abs(back.left - (shape.width - start.right)) <= 2, "\(shape.name) Back and Start mirror each other")
            #expect(back.top == start.top && back.size == start.size, "\(shape.name)")
        }
    }

    @Test func theClustersKeepTheirSidesAndProportionsInLandscape() {
        let design = layout(1920, 1080)
        for shape in shapes where shape.width >= shape.height {
            let m = layout(shape.width, shape.height)
            for (id, d) in design {
                guard let r = m[id] else { continue }
                let ratio = Double(d.width) / Double(d.height)
                #expect(abs(Double(r.width) / Double(r.height) - ratio) <= 0.04 * ratio, "\(shape.name) \(id) keeps its proportions")
            }
            let leftEdge = [m[.dpad]!, m[.leftStick]!, m[.leftBumper]!].map(\.right).max()!
            let rightEdge = [m[.rightStick]!, m[.rightBumper]!, m[.x]!].map(\.left).min()!
            #expect(leftEdge < rightEdge, "\(shape.name) clusters apart")
            #expect(m[.back]!.left >= m[.dpad]!.right - 2 && m[.start]!.right <= m[.rightStick]!.left + 2, "\(shape.name) middle row between")
        }
    }

    @Test func theLeftAndRightClustersMirrorEachOtherAgainstTheirEdges() {
        // The grid is not mirror-symmetric (Android's numbers), but each cluster keeps its distance to its own edge on every
        // shape of 3:2 and wider: what a wider panel adds goes to the middle
        let base = layout(1920, 1080)
        for shape in shapes where 2 * shape.width >= 3 * shape.height {
            let k = Double(shape.height) / 1080
            let m = layout(shape.width, shape.height)
            #expect(abs(Double(m[.dpad]!.left) - Double(base[.dpad]!.left) * k) <= 1.5, "\(shape.name) D-pad from the left")
            #expect(abs(Double(shape.width - m[.a]!.right) - Double(1920 - base[.a]!.right) * k) <= 2, "\(shape.name) A from the right")
        }
    }

    @Test func anchorsFollowTheDefaultSides() {
        #expect(OscDefaultLayout.anchorX(.dpad) == .left && OscDefaultLayout.anchorX(.leftBumper) == .left)
        #expect(OscDefaultLayout.anchorX(.a) == .right && OscDefaultLayout.anchorX(.rightStick) == .right)
        for middle in [OscElementID.back, .guide, .start, .touchpad] {
            #expect(OscDefaultLayout.anchorX(middle) == .center)
            #expect(OscDefaultLayout.anchorY(middle) == .bottom)
        }
        #expect(OscDefaultLayout.anchorY(.y) == .top && OscDefaultLayout.anchorY(.leftTrigger) == .top && OscDefaultLayout.anchorY(.leftStick) == .top)
        #expect(OscDefaultLayout.anchorY(.dpad) == .bottom && OscDefaultLayout.anchorY(.rightStickButton) == .bottom)
    }

    @Test func aPlacementComesBackOnThePanelItWasMadeOn() {
        for shape in shapes {
            let panel = OscPanel(width: shape.width, height: shape.height)
            for (id, slot) in layout(shape.width, shape.height) {
                var r = slot
                // Moved towards the middle (still on the panel) and up
                r.left += r.left + r.width / 2 > shape.width / 2 ? -37 : 37
                r.top = max(0, r.top - 11)
                #expect(OscPlacement(id, slot: r, enabled: true, panel: panel).slot(on: panel) == r, "\(shape.name) \(id)")
            }
        }
    }

    /// Within a pixel or two, as on Android's panels: the grid truncates each size to whole pixels of the panel it was made on,
    /// and that pixel grows by the ratio of the two units on the other panel (a small portrait iPhone's layout on a large iPad).
    @Test func theDefaultMadeOnOnePanelIsTheDefaultOfEveryOther() {
        for from in shapes {
            let a = OscPanel(width: from.width, height: from.height)
            for to in shapes {
                let b = OscPanel(width: to.width, height: to.height)
                let tolerance = max(2, Int((1.5 * (Double(b.unit / a.unit) + 1)).rounded(.up)))
                let there = layout(to.width, to.height)
                for (id, slot) in layout(from.width, from.height) {
                    let mapped = OscPlacement(id, slot: slot, enabled: true, panel: a).slot(on: b)
                    let expected = there[id]!
                    let what = "\(from.name) -> \(to.name) \(id)"
                    #expect(abs(mapped.left - expected.left) <= tolerance && abs(mapped.top - expected.top) <= tolerance, "\(what)")
                    #expect(abs(mapped.width - expected.width) <= tolerance && abs(mapped.height - expected.height) <= tolerance, "\(what)")
                }
            }
        }
    }

    @Test func aMovedControlKeepsItsDistanceFromItsAnchorOnEveryScreen() {
        let odin = OscPanel(width: 1920, height: 1080)
        let slots = layout(1920, 1080)
        var rs = slots[.rightStick]!
        rs.left -= 150
        rs.top -= 60
        let stick = OscPlacement(.rightStick, slot: rs, enabled: true, panel: odin)
        var dpad = slots[.dpad]!
        dpad.left += 40
        let pad = OscPlacement(.dpad, slot: dpad, enabled: true, panel: odin)
        var guide = slots[.guide]!
        guide.left += 90
        let g = OscPlacement(.guide, slot: guide, enabled: true, panel: odin)
        for shape in shapes {
            let b = OscPanel(width: shape.width, height: shape.height)
            let k = Double(b.unit / odin.unit)
            let s = stick.slot(on: b)
            #expect(abs(Double(1920 - rs.right) * k - Double(shape.width - s.right)) <= 1.5, "\(shape.name) right gap")
            #expect(abs(Double(1080 - rs.bottom) * k - Double(shape.height - s.bottom)) <= 1.5, "\(shape.name) bottom gap")
            #expect(abs(Double(rs.width) * k - Double(s.width)) <= 1, "\(shape.name) size")
            #expect(abs(Double(dpad.left) * k - Double(pad.slot(on: b).left)) <= 1, "\(shape.name) left gap")
            let gr = g.slot(on: b)
            #expect(abs((Double(guide.left) + Double(guide.width) / 2 - 960) * k - (Double(gr.left) + Double(gr.width) / 2 - Double(shape.width) / 2)) <= 1.5,
                    "\(shape.name) from the centre")
        }
    }

    @Test func aPlacementIsAlwaysOnThePanel() {
        let far = OscPlacement(anchorX: .right, anchorY: .bottom, x: -50, y: -50, width: 10, height: 10, enabled: true)
        let r = far.slot(on: OscPanel(width: 1280, height: 800))
        #expect(r.left >= 0 && r.top >= 0 && r.right <= 1280 && r.bottom <= 800)
        #expect(OscPanel(width: 100, height: 50).clamp(OscSlot(left: 30, top: 30, width: 300, height: 300)) == OscSlot(left: 0, top: 0, width: 100, height: 50))
    }

    @Test func javaRoundsHalvesUp() {
        #expect(javaRound(2.5) == 3 && javaRound(-2.5) == -2 && javaRound(-2.6) == -3)
    }
}

private extension OscSlot {
    var size: [Int] { [width, height] }
}

/// What the controls send, play, say and store.
@MainActor
private final class Recorder {
    var sent: [ControllerState] = []
    var vibrations: [OscVibration] = []
    var toasts: [String] = []
    var stored: [Int: OscPlacement] = [:]
    var writes = 0

    var output: OscOutput {
        var o = OscOutput()
        o.send = { [unowned self] in sent.append($0) }
        o.vibrate = { [unowned self] in vibrations.append($0) }
        o.announce = { [unowned self] in toasts.append($0) }
        o.readLayout = { [unowned self] in stored }
        o.writeLayout = { [unowned self] in stored = $0; writes += 1 }
        return o
    }
}

/// The controls on a 1080p panel (`VirtualController` and its elements of DELOS for Android): what each touch sends.
@MainActor
@Suite struct OnScreenControlsInputMappingTests {
    private func controls(_ options: OscOptions = OscOptions(), recorder: Recorder, followsGamepad: Bool = false) -> OnScreenControls {
        let c = OnScreenControls(options: options, enabled: true, followsGamepad: followsGamepad, output: recorder.output)
        c.layOut(width: 1920, height: 1080)
        return c
    }

    private func center(_ c: OnScreenControls, _ id: OscElementID) -> (x: Float, y: Float) {
        let s = c.elements.first { $0.id == id }!.slot
        return (Float(s.left) + Float(s.width) / 2, Float(s.top) + Float(s.height) / 2)
    }

    private func tap(_ c: OnScreenControls, _ touch: Int, _ id: OscElementID, _ phase: OnScreenControls.Phase, time: Double = 0) {
        let p = center(c, id)
        c.touch(touch, phase, x: p.x, y: p.y, time: time)
    }

    @Test func eachButtonPressesItsFlag() {
        let expected: [(OscElementID, ControllerButtons)] = [
            (.a, .a), (.b, .b), (.x, .x), (.y, .y), (.leftBumper, .leftShoulder), (.rightBumper, .rightShoulder), (.back, .back),
            (.start, .play), (.leftStickButton, .leftStick), (.rightStickButton, .rightStick), (.touchpad, .touchpad), (.guide, .special),
        ]
        for (id, flag) in expected {
            let recorder = Recorder()
            let c = controls(recorder: recorder)
            tap(c, 1, id, .began)
            #expect(recorder.sent.last == ControllerState(buttons: flag), "\(id)")
            tap(c, 1, id, .ended)
            #expect(recorder.sent.last == ControllerState(), "\(id) released")
        }
    }

    @Test func flippedFaceButtonsSwapTheirLettersAndFlags() {
        let recorder = Recorder()
        let c = controls(OscOptions(flipFaceButtons: true), recorder: recorder)
        #expect(c.elements.first { $0.id == .a }?.label == "B")
        tap(c, 1, .a, .began)
        #expect(recorder.sent.last?.buttons == .b)
        tap(c, 2, .y, .began)
        #expect(recorder.sent.last?.buttons == [.b, .x])
    }

    @Test func triggersAreFullOrNothing() {
        let recorder = Recorder()
        let c = controls(recorder: recorder)
        tap(c, 1, .leftTrigger, .began)
        tap(c, 2, .rightTrigger, .began)
        #expect(recorder.sent.last == ControllerState(leftTrigger: 0xFF, rightTrigger: 0xFF))
        tap(c, 1, .leftTrigger, .ended)
        #expect(recorder.sent.last == ControllerState(rightTrigger: 0xFF))
    }

    @Test func manyFingersPressManyControlsAndASecondFingerOnOneIsIgnored() {
        let recorder = Recorder()
        let c = controls(recorder: recorder)
        tap(c, 1, .a, .began)
        tap(c, 2, .y, .began)
        tap(c, 3, .leftBumper, .began)
        #expect(recorder.sent.last?.buttons == [.a, .y, .leftShoulder])
        // A second finger on A changes nothing, and its lifting does not let go of A
        tap(c, 4, .a, .began)
        tap(c, 4, .a, .ended)
        #expect(recorder.sent.last?.buttons == [.a, .y, .leftShoulder])
        tap(c, 1, .a, .ended)
        #expect(recorder.sent.last?.buttons == [.y, .leftShoulder])
    }

    @Test func aFingerSlidingOverTheButtonsOfItsLayerPressesThem() {
        let recorder = Recorder()
        let c = controls(recorder: recorder)
        tap(c, 1, .a, .began)
        let b = center(c, .b)
        c.touch(1, .moved, x: b.x, y: b.y, time: 10)
        #expect(recorder.sent.last?.buttons == [.a, .b], "A stays down, B joins")
        let x = center(c, .x)
        c.touch(1, .moved, x: x.x, y: x.y, time: 20)
        #expect(recorder.sent.last?.buttons == [.a, .x], "B is left, X joins")
        c.touch(1, .ended, x: x.x, y: x.y, time: 30)
        #expect(recorder.sent.last == ControllerState())
        // Start is a layer of its own: sliding from Back onto it presses nothing
        tap(c, 2, .back, .began)
        let start = center(c, .start)
        c.touch(2, .moved, x: start.x, y: start.y, time: 40)
        #expect(recorder.sent.last?.buttons == .back)
    }

    @Test func theDpadPressesOneOrTwoDirectionsByThirds() {
        let recorder = Recorder()
        let c = controls(recorder: recorder)
        let s = c.elements.first { $0.id == .dpad }!.slot
        c.touch(1, .began, x: Float(s.left) + 10, y: Float(s.top) + 10, time: 0)
        #expect(recorder.sent.last?.buttons == [.left, .up])
        #expect(recorder.vibrations.isEmpty, "no vibration while presses do not vibrate")
        c.touch(1, .moved, x: Float(s.right) - 10, y: Float(s.top) + Float(s.height) / 2, time: 10)
        #expect(recorder.sent.last?.buttons == .right)
        c.touch(1, .moved, x: Float(s.left) + Float(s.width) / 2, y: Float(s.bottom) - 5, time: 20)
        #expect(recorder.sent.last?.buttons == .down)
        c.touch(1, .ended, x: 0, y: 0, time: 30)
        #expect(recorder.sent.last == ControllerState())
    }

    @Test func aFixedStickSendsItsReachAndDoubleTapIsL3() {
        let recorder = Recorder()
        let c = controls(recorder: recorder)
        let p = center(c, .leftStick)
        c.touch(1, .began, x: p.x, y: p.y, time: 0)
        // Far to the right: full right; then up: full up (Android's y grows upwards for the PC)
        c.touch(1, .moved, x: p.x + 300, y: p.y, time: 10)
        #expect(recorder.sent.last?.leftStickX == 32766 && recorder.sent.last?.leftStickY == 0)
        c.touch(1, .moved, x: p.x + 0.001, y: p.y - 300, time: 20)
        #expect(recorder.sent.last?.leftStickY == 32766)
        #expect(abs(Int(recorder.sent.last!.leftStickX)) < 2)
        c.touch(1, .ended, x: p.x, y: p.y - 300, time: 30)
        #expect(recorder.sent.last == ControllerState(), "the stick springs back")
        // Two taps within 350 ms: L3 while the second is held
        c.touch(2, .began, x: p.x, y: p.y, time: 100)
        #expect(recorder.sent.last?.buttons == .leftStick)
        c.touch(2, .ended, x: p.x, y: p.y, time: 150)
        #expect(recorder.sent.last == ControllerState())
    }

    @Test func aFixedStickTakesOnlyTouchesInsideItsRing() {
        let recorder = Recorder()
        let c = controls(recorder: recorder)
        let s = c.elements.first { $0.id == .leftStick }!.slot
        // The corner of its square is outside the ring: the touch is the stream's
        #expect(c.hit(x: Float(s.left) + 2, y: Float(s.top) + 2) == nil)
        #expect(c.hit(x: Float(s.left) + Float(s.width) / 2, y: Float(s.top) + Float(s.height) / 2) == .element(.leftStick))
    }

    @Test func aFreeStickStartsWhereTheFingerLands() {
        let recorder = Recorder()
        let c = controls(OscOptions(freeSticks: true), recorder: recorder)
        let s = c.elements.first { $0.id == .rightStick }!.slot
        let x = Float(s.left) + 20, y = Float(s.top) + 20
        c.touch(1, .began, x: x, y: y, time: 0)
        #expect(c.elements.first { $0.id == .rightStick }?.stick.startX == 20)
        // Inside the dead zone (58.5 px) nothing moves, however long it is held
        c.touch(1, .moved, x: x + 30, y: y, time: 1000)
        #expect(recorder.sent.allSatisfy { $0.rightStickX == 0 })
        c.touch(1, .moved, x: x - 400, y: y, time: 1010)
        #expect(recorder.sent.last?.rightStickX == -32766)
        c.touch(1, .ended, x: x - 400, y: y, time: 1020)
        #expect(recorder.sent.last == ControllerState())
    }

    @Test func pressesVibrateWhenTheProfileAsks() {
        let recorder = Recorder()
        let c = controls(OscOptions(pressHaptics: true), recorder: recorder)
        tap(c, 1, .a, .began)
        tap(c, 1, .a, .ended)
        let s = c.elements.first { $0.id == .dpad }!.slot
        c.touch(2, .began, x: Float(s.left) + 5, y: Float(s.top) + 5, time: 0)
        #expect(recorder.vibrations == [.press, .press, .dpad])
    }

    @Test func theyHideWhileAControllerIsInUseUntilTheMenuShowsThem() {
        let recorder = Recorder()
        let c = controls(recorder: recorder, followsGamepad: true)
        tap(c, 1, .a, .began)
        c.setGamepadInUse(true)
        #expect(!c.visible)
        #expect(recorder.sent.last == ControllerState(), "what was held is let go")
        let a = center(c, .a)
        #expect(c.hit(x: a.x, y: a.y) == nil, "a hidden control takes no touch")
        c.setGamepadInUse(false)
        #expect(c.visible)
        c.setGamepadInUse(true)
        c.toggle()
        #expect(c.visible, "the menu's toggle shows them, a controller or not")
        c.toggle()
        #expect(!c.visible && !c.enabled)
    }

    @Test func theRumbleOfTheControlsPlaysOnTheDeviceUnlessOnlyL3R3Show() {
        let recorder = Recorder()
        #expect(controls(recorder: recorder).rumblesDevice)
        #expect(!controls(OscOptions(onlyL3R3: true), recorder: recorder).rumblesDevice)
        #expect(!controls(OscOptions(deviceRumble: false), recorder: recorder).rumblesDevice)
    }

    @Test func theOpacityIsAndroidsAlpha() {
        let recorder = Recorder()
        let c = controls(OscOptions(opacity: 90), recorder: recorder)
        #expect(c.elementOpacity == Double(229) / 255)
        c.setOpacity(150)
        #expect(c.options.opacity == 100)
    }

    @Test func axesAreJavasShortCast() {
        #expect(OnScreenControls.axis(1) == 32766 && OnScreenControls.axis(-1) == -32766)
        #expect(OnScreenControls.axis(.nan) == 0 && OnScreenControls.axis(0.5) == 16383)
    }
}

/// The editor of the gear in the corner (`VirtualController.ControllerMode`), and what it stores.
@MainActor
@Suite struct OnScreenControlsEditorTests {
    private func gear(_ c: OnScreenControls) {
        let g = c.gearSlot
        let x = Float(g.left + g.width / 2), y = Float(g.top + g.height / 2)
        c.touch(99, .began, x: x, y: y, time: 0)
        c.touch(99, .ended, x: x, y: y, time: 1)
    }

    @Test func theGearGoesThroughTheModesWithTheirToastsAndSaves() throws {
        let recorder = Recorder()
        let c = OnScreenControls(options: OscOptions(), enabled: true, followsGamepad: false, output: recorder.output)
        c.layOut(width: 1920, height: 1080)
        #expect(c.gearSlot == OscSlot(left: 15, top: 15, width: 64, height: 64))
        gear(c)
        #expect(c.mode == .disableEnable)
        // Turn A off
        let a = c.elements.first { $0.id == .a }!.slot
        c.touch(1, .began, x: Float(a.left + 5), y: Float(a.top + 5), time: 0)
        c.touch(1, .ended, x: Float(a.left + 5), y: Float(a.top + 5), time: 1)
        #expect(c.elements.first { $0.id == .a }?.enabled == false)
        #expect(recorder.sent.isEmpty, "the editor sends nothing to the PC")
        gear(c)
        #expect(c.mode == .move)
        #expect(!c.shows(c.elements.first { $0.id == .a }!), "a control turned off is hidden outside its mode")
        // Move the left stick 100 px right and 50 down
        let ls = c.elements.first { $0.id == .leftStick }!.slot
        c.touch(2, .began, x: Float(ls.left + 195), y: Float(ls.top + 195), time: 0)
        c.touch(2, .moved, x: Float(ls.left + 295), y: Float(ls.top + 245), time: 1)
        c.touch(2, .ended, x: Float(ls.left + 295), y: Float(ls.top + 245), time: 2)
        #expect(c.elements.first { $0.id == .leftStick }?.slot == OscSlot(left: ls.left + 100, top: ls.top + 50, width: 390, height: 390))
        gear(c)
        #expect(c.mode == .resize)
        // Grow Guide by 20 x 10
        let guide = c.elements.first { $0.id == .guide }!.slot
        c.touch(3, .began, x: Float(guide.left + 10), y: Float(guide.top + 10), time: 0)
        c.touch(3, .moved, x: Float(guide.left + 30), y: Float(guide.top + 20), time: 1)
        c.touch(3, .ended, x: Float(guide.left + 30), y: Float(guide.top + 20), time: 2)
        #expect(c.elements.first { $0.id == .guide }?.slot.size == [200, 115])
        gear(c)
        #expect(c.mode == .active)
        #expect(recorder.toasts == [
            L("configuration_mode_disable_enable_buttons"), L("configuration_mode_move_buttons"),
            L("configuration_mode_resize_buttons"), L("configuration_mode_exiting"),
        ])
        // Only what changed is stored, each against its anchor in layout units
        #expect(Set(recorder.stored.keys) == [OscElementID.a.rawValue, OscElementID.leftStick.rawValue, OscElementID.guide.rawValue])
        let stick = try #require(recorder.stored[OscElementID.leftStick.rawValue])
        #expect(stick.anchorX == .left && stick.anchorY == .top && stick.x == Float(ls.left + 100) / 15 && stick.enabled)
        let g = try #require(recorder.stored[OscElementID.guide.rawValue])
        #expect(g.anchorX == .center && g.anchorY == .bottom && abs(g.width - 200 / 15) < 1e-5)
        #expect(recorder.stored[OscElementID.a.rawValue]?.enabled == false)
    }

    @Test func aControlPutBackWhereTheDefaultIsIsNoLongerStored() {
        let recorder = Recorder()
        let panel = OscPanel(width: 1920, height: 1080)
        var moved = OscDefaultLayout.slot(.dpad, on: panel)!
        moved.left += 40
        recorder.stored = [OscElementID.dpad.rawValue: OscPlacement(.dpad, slot: moved, enabled: true, panel: panel),
                           OscElementID.leftTrigger.rawValue: OscPlacement(.leftTrigger, slot: OscDefaultLayout.slot(.leftTrigger, on: panel)!, enabled: true, panel: panel)]
        let c = OnScreenControls(options: OscOptions(onlyL3R3: true), enabled: true, followsGamepad: false, output: recorder.output)
        c.layOut(width: 1920, height: 1080)
        // Only L3 and R3 are on screen: the stored D-pad and LT are kept as they are
        #expect(c.placements() == recorder.stored)
        let full = OnScreenControls(options: OscOptions(), enabled: true, followsGamepad: false, output: recorder.output)
        full.layOut(width: 1920, height: 1080)
        #expect(full.elements.first { $0.id == .dpad }?.slot == moved, "the stored change is laid over the default")
        #expect(full.placements().keys.sorted() == [OscElementID.dpad.rawValue], "LT at its default place is dropped")
    }

    @Test func aLayoutMadeOnAnIPhoneLooksTheSameOnAnIPad() {
        let recorder = Recorder()
        let phone = OnScreenControls(options: OscOptions(), enabled: true, followsGamepad: false, output: recorder.output)
        phone.layOut(width: 2868, height: 1320)
        let phonePanel = OscPanel(width: 2868, height: 1320)
        var rs = OscDefaultLayout.slot(.rightStick, on: phonePanel)!
        rs.left -= 200
        recorder.stored = [OscElementID.rightStick.rawValue: OscPlacement(.rightStick, slot: rs, enabled: true, panel: phonePanel)]
        let pad = OnScreenControls(options: OscOptions(), enabled: true, followsGamepad: false, output: recorder.output)
        pad.layOut(width: 2752, height: 2064)
        let padPanel = OscPanel(width: 2752, height: 2064)
        let placed = pad.elements.first { $0.id == .rightStick }!.slot
        let k = Double(padPanel.unit / phonePanel.unit)
        #expect(abs(Double(2868 - rs.right) * k - Double(2752 - placed.right)) <= 1.5, "the gap to the right edge in layout units")
    }
}

/// A stream that is up at once, for the stream menu's rows and the touches.
@MainActor
private final class OscSteps: StreamSteps {
    let pcName = "Gaming-PC"
    let appName = "Desktop"
    let events: AsyncStream<StreamEvent>
    private let continuation: AsyncStream<StreamEvent>.Continuation
    let sink = OscSink()
    var input: (any StreamInputSink)? { sink }

    init() { (events, continuation) = AsyncStream.makeStream(of: StreamEvent.self) }

    func launch(display: DisplayInfo) async throws(LaunchFailure) {}
    func connect() async throws(StreamError) { continuation.yield(.connectionStarted) }
    func stop() async { continuation.finish() }
    func quitApp() async -> Bool { true }
}

private final class OscSink: StreamInputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [(UInt8, UInt16, ControllerState)] = []
    var controllers: [(number: UInt8, mask: UInt16, state: ControllerState)] { lock.withLock { states } }
    private var buttons = 0
    var mouseButtons: Int { lock.withLock { buttons } }

    func sendControllerArrival(
        number: UInt8, activeGamepadMask: UInt16, type: ControllerType, supportedButtons: ControllerButtons,
        capabilities: ControllerCapabilities
    ) throws(InputError) {}
    func sendController(number: UInt8, activeGamepadMask: UInt16, state: ControllerState) throws(InputError) {
        lock.withLock { states.append((number, activeGamepadMask, state)) }
    }
    func sendMouseMove(deltaX: Int16, deltaY: Int16) throws(InputError) {}
    func sendControllerMotion(number: UInt8, sensor: MotionSensor, x: Float, y: Float, z: Float) throws(InputError) {}
    func sendControllerBattery(number: UInt8, state: BatteryState, percentage: UInt8) throws(InputError) {}
    func sendControllerTouch(
        number: UInt8, _ type: TouchEventType, pointerID: UInt32, x: Float, y: Float, pressure: Float) throws(InputError) {}
    func sendScroll(clicks: Int8) throws(InputError) {}
    func sendHorizontalScroll(clicks: Int8) throws(InputError) {}
    func sendMouseButton(_ button: MouseButton, pressed: Bool) throws(InputError) { lock.withLock { buttons += 1 } }
    func sendKey(code: Int16, pressed: Bool, modifiers: KeyModifiers, nonNormalized: Bool) throws(InputError) {}
    func sendText(_ text: String) throws(InputError) {}
    func sendServerCommand(_ id: UInt8) throws(InputError) {}
    func sendHighResolutionScroll(amount: Int16) throws(InputError) {}
    func sendHighResolutionHorizontalScroll(amount: Int16) throws(InputError) {}
}

/// The controls in a stream: the touches of the video surface, controller 0 at the PC, the More page's rows.
@MainActor
@Suite struct OnScreenControlsStreamTests {
    private func streaming(enabled: Bool = true) async -> (StreamController, OscSteps, OnScreenControls) {
        let steps = OscSteps()
        let controls = OnScreenControls(options: OscOptions(), enabled: enabled, followsGamepad: false)
        controls.layOut(width: 1920, height: 1080)
        let controller = StreamController(onScreenControls: controls) { steps }
        controller.start(display: DisplayInfo(pixelWidth: 1920, pixelHeight: 1080, maxFramesPerSecond: 60))
        for _ in 0..<500 where controller.phase != .streaming { try? await Task.sleep(for: .milliseconds(2)) }
        controller.loaderEnded()
        return (controller, steps, controls)
    }

    @Test func aTouchOnAControlIsControllerZeroAndNeverTheTrackpad() async {
        let (controller, steps, controls) = await streaming()
        let a = controls.elements.first { $0.id == .a }!.slot
        // The video surface reports the touch in its own pixels: here twice the panel's
        let area = StreamController.TouchArea(width: 3840, height: 2160)
        let point = CGPoint(x: Double(a.left + 75) * 2, y: Double(a.top + 75) * 2)
        controller.touch(1, .began, at: point, area: area, time: 0)
        let last = steps.sink.controllers.last
        #expect(last?.number == 0 && last?.mask == 1 && last?.state.buttons == .a)
        controller.touch(1, .ended, at: point, area: area, time: 0.05)
        #expect(steps.sink.controllers.last?.state == ControllerState())
    }

    @Test func theMorePageTogglesTheControlsAndSetsTheirOpacity() async throws {
        let (controller, steps, controls) = await streaming()
        var kept: [Int] = []
        controller.onScreenOpacityChosen = { kept.append($0) }
        guard case let .rows(rows) = controller.menuContent(.more) else { Issue.record("More has rows"); return }
        let toggle = try #require(rows.first { $0.id == MenuRowID.onScreenControls.rawValue })
        guard case .toggle(true) = toggle.value else { Issue.record("on"); return }
        let opacity = try #require(rows.first { $0.id == MenuRowID.onScreenOpacity.rawValue })
        guard case .slider(90, 0...100, 5, " %", 1, nil) = opacity.value else { Issue.record("90 % in steps of 5"); return }
        opacity.set?(45)
        #expect(controls.options.opacity == 45 && kept == [45])
        toggle.activate()
        #expect(!controls.visible)
        #expect(steps.sink.controllers.last?.mask == 0, "controller 0 left the PC's mask")
        guard case let .rows(after) = controller.menuContent(.more), case .toggle(false) = after.first(where: { $0.id == MenuRowID.onScreenControls.rawValue })?.value
        else { Issue.record("off"); return }
    }

    @Test func withoutControlsTheMorePageHasNoRowsForThem() async {
        let steps = OscSteps()
        let controller = StreamController { steps }
        guard case let .rows(rows) = controller.menuContent(.more) else { return }
        #expect(!rows.contains { $0.id == MenuRowID.onScreenControls.rawValue })
    }

    @Test func movingTheControlsKeepsTheStreamsTouchesAway() async {
        let (controller, steps, controls) = await streaming()
        controls.cycleMode()
        controls.cycleMode()
        #expect(controls.mode == .move)
        let count = steps.sink.controllers.count
        // A tap away from the controls: the trackpad's click, but not while they are moved
        controller.touch(5, .began, at: CGPoint(x: 960, y: 300), area: .init(width: 1920, height: 1080), time: 0)
        controller.touch(5, .ended, at: CGPoint(x: 960, y: 300), area: .init(width: 1920, height: 1080), time: 0.05)
        #expect(steps.sink.controllers.count == count && steps.sink.mouseButtons == 0)
        controls.cycleMode()
        controls.cycleMode()
        #expect(controls.mode == .active)
        controller.touch(6, .began, at: CGPoint(x: 960, y: 300), area: .init(width: 1920, height: 1080), time: 1)
        controller.touch(6, .ended, at: CGPoint(x: 960, y: 300), area: .init(width: 1920, height: 1080), time: 1.05)
        #expect(steps.sink.mouseButtons == 2, "back in play the tap clicks")
    }
}
