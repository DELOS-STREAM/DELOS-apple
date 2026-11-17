import DelosInput

/// How much of a hint a compact hint bar shows: only its button, its short label, or its full label. Ordered by width
/// (`HintDetail` of DELOS for Android's `shell/ui/HintFit.kt`).
enum HintDetail: Int, CaseIterable, Sendable { case bare, short, full }

/// One hint as the fit sees it: how important it is (`rank`, 0 most) and how wide it is at each detail. `short` is nil when
/// the hint has no shorter label (or the shorter one is not narrower). Hints with the same non-nil `group` always get the
/// same detail (the two tab hints are either both worded or both buttons).
struct HintFitItem: Sendable {
    var rank: Int
    var bare: Double
    var short: Double?
    var full: Double
    var group: Int?

    func width(_ detail: HintDetail) -> Double {
        switch detail {
        case .bare: bare
        case .short: short ?? full
        case .full: full
        }
    }
}

/// Which note variant is drawn (`note` is an index into the offered widths, nil for no note) and each hint's detail.
struct HintBarFit: Equatable, Sendable {
    var note: Int?
    var details: [HintDetail]
}

enum HintFit {
    /// How important a hint is, judged by its button: the primary action (south) first, then back (east), then the
    /// screen's own actions (west, north, adjust), then the tab hints (shoulders), then the menu buttons. Lower is
    /// more important (`hintRank`).
    static func rank(_ button: HintButton) -> Int {
        switch button {
        case .pad(.south): 0
        case .pad(.east): 1
        case .pad(.leftShoulder), .pad(.rightShoulder): 3
        case .pad(.menuLeft), .pad(.menuRight): 4
        default: 2
        }
    }

    /// The tab hints belong together, every other hint stands alone.
    static func group(_ button: HintButton) -> Int? {
        switch button {
        case .pad(.leftShoulder), .pad(.rightShoulder): rank(button)
        default: nil
        }
    }

    /// Chooses how much of each hint fits in `available` pixels, `gap` apart. The most important hint gets the most text:
    /// in order of rank (the list order breaks ties) every hint (or group of hints) takes the fullest label that still fits
    /// when all the hints after it are only buttons (`fitHints`).
    static func fitHints(_ items: [HintFitItem], gap: Double, available: Double) -> [HintDetail] {
        var details = [HintDetail](repeating: .bare, count: items.count)
        func total() -> Double {
            items.indices.reduce(0) { $0 + items[$1].width(details[$1]) } + gap * Double(max(items.count - 1, 0))
        }
        let byImportance = items.indices.sorted { (items[$0].rank, $0) < (items[$1].rank, $1) }
        var done = Set<Int>()
        for i in byImportance where !done.contains(i) {
            let members = items.indices.filter { $0 == i || (items[i].group != nil && items[$0].group == items[i].group) }
            done.formUnion(members)
            for detail in [HintDetail.full, .short] {
                if detail == .short, members.allSatisfy({ items[$0].short == nil }) { continue }
                for m in members { details[m] = detail }
                if total() <= available { break }
                for m in members { details[m] = .bare }
            }
        }
        return details
    }

    /// The whole bar: a note (`noteWidths`, widest, fullest variant first) at the left of the hints. A note is kept only
    /// while every hint keeps a label next to its button; otherwise the next variant is tried and finally the hints get
    /// the whole width (`fitHintBar`).
    static func fitBar(noteWidths: [Double], noteGap: Double, items: [HintFitItem], hintGap: Double, available: Double) -> HintBarFit {
        for (i, width) in noteWidths.enumerated() {
            let room = available - width - (items.isEmpty ? 0 : noteGap)
            let details = fitHints(items, gap: hintGap, available: room)
            if room >= 0, !details.contains(.bare) { return HintBarFit(note: i, details: details) }
        }
        return HintBarFit(note: nil, details: fitHints(items, gap: hintGap, available: available))
    }
}
