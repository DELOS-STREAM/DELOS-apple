import CoreGraphics
import Testing
@testable import DelosUI

/// docs/ENGINEERING_RULES.md, "A new row starts at its first item".
@MainActor
@Suite struct FocusRowStartTests {
    /// A pill row on top (three pills), a card row under it (four cards).
    private func screen(_ model: FocusModel) {
        for (i, x) in [100.0, 400.0, 700.0].enumerated() {
            model.register("pill-\(i)", frame: CGRect(x: x, y: 100, width: 250, height: 76)) {}
        }
        for i in 0..<4 {
            model.register("card-\(i)", frame: CGRect(x: 100 + Double(i) * 300, y: 300, width: 260, height: 390)) {}
        }
    }

    @Test func downLandsOnTheFirstItemOfTheRowBelow() {
        let model = FocusModel(initial: AnyHashable("pill-2"))
        screen(model)
        #expect(model.handle(.down))
        #expect(model.focused == AnyHashable("card-0"))
    }

    @Test func upLandsOnTheFirstItemOfTheRowAbove() {
        let model = FocusModel(initial: AnyHashable("card-3"))
        screen(model)
        #expect(model.handle(.up))
        #expect(model.focused == AnyHashable("pill-0"))
    }

    @Test func leftAndRightStillGoToTheNeighbour() {
        let model = FocusModel(initial: AnyHashable("card-1"))
        screen(model)
        #expect(model.handle(.right))
        #expect(model.focused == AnyHashable("card-2"))
    }

    @Test func aRowScrolledSidewaysStartsAtItsFirstItemOnScreen() {
        let next = FocusGeometry.next(from: CGRect(x: 600, y: 100, width: 250, height: 76), direction: .down, candidates: [
            "gone": CGRect(x: -400, y: 300, width: 520, height: 292),
            "peek": CGRect(x: -20, y: 300, width: 520, height: 292),
            "first": CGRect(x: 548, y: 300, width: 520, height: 292),
            "next": CGRect(x: 1116, y: 300, width: 520, height: 292),
        ])
        #expect(next == "first")
    }

    @Test func anItemBesideTheCurrentOneIsNoRowBelow() {
        // A tall card to the left reaches into the current row's height: Down must not land on it sideways
        let next = FocusGeometry.next(from: CGRect(x: 700, y: 100, width: 200, height: 60), direction: .down, candidates: [
            "tall": CGRect(x: 100, y: 80, width: 400, height: 400),
            "below": CGRect(x: 700, y: 300, width: 200, height: 60),
        ])
        #expect(next == "below")
    }

    @Test func aGridKeepsTheColumn() {
        let model = FocusModel(initial: AnyHashable("tile-2"))
        var ids: [AnyHashable] = []
        for row in 0..<2 {
            for column in 0..<3 {
                let id = "tile-\(row * 3 + column)"
                ids.append(AnyHashable(id))
                model.register(id, frame: CGRect(x: 100 + Double(column) * 300, y: 100 + Double(row) * 300, width: 260, height: 260)) {}
            }
        }
        model.keepColumn(in: "grid", items: ids)
        #expect(model.handle(.down))
        #expect(model.focused == AnyHashable("tile-5"))
        #expect(model.handle(.up))
        #expect(model.focused == AnyHashable("tile-2"))
    }

    @Test func returningToARestoringRowLandsWhereTheFocusLeftIt() {
        let model = FocusModel(initial: AnyHashable("card-2"))
        screen(model)
        model.restoreFocus(in: "cards", items: (0..<4).map { AnyHashable("card-\($0)") })
        #expect(model.handle(.up))
        #expect(model.focused == AnyHashable("pill-0"))
        #expect(model.handle(.down))
        #expect(model.focused == AnyHashable("card-2"))
    }
}
