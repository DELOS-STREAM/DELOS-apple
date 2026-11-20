import DelosData
import SwiftUI

/// The texts of the streaming-time block in the current language (`PlaytimeTexts`, `PlaytimeFormat.parts`,
/// `LastStreamed.format` of DELOS for Android).
struct PlaytimeTexts: Equatable {
    struct Parts: Equatable {
        /// Big: "20.4", "45".
        let number: String
        /// Small: "hours", "minutes", or "h", "min" in the short form.
        let unit: String
    }

    let eyebrowTime: String
    let eyebrowLast: String
    let full: Parts
    let short: Parts
    let last: String

    init(_ playtime: Playtime, now: Date = Date(), locale: Locale = .current, calendar: Calendar = .current) {
        // Upper-cased in the locale (a Turkish i becomes İ)
        eyebrowTime = L("playtime_eyebrow_time").uppercased(with: locale)
        eyebrowLast = L("playtime_eyebrow_last").uppercased(with: locale)
        let amount = PlaytimeAmount(seconds: playtime.totalSeconds)
        full = Self.parts(amount, short: false, locale: locale)
        short = Self.parts(amount, short: true, locale: locale)
        last = Self.last(LastStreamed(playtime.lastStreamed, now: now, calendar: calendar), locale: locale)
    }

    static func parts(_ amount: PlaytimeAmount, short: Bool, locale: Locale) -> Parts {
        switch amount {
        case .minutes(let count):
            return Parts(number: count.formatted(.number.locale(locale)),
                         unit: short ? L("playtime_unit_minutes_short") : LPlural("playtime_unit_minutes", count))
        case .tenthsOfHours(let tenths):
            let whole = tenths % 10 == 0
            let number = whole
                ? (tenths / 10).formatted(.number.locale(locale))
                : (Double(tenths) / 10).formatted(.number.locale(locale).precision(.fractionLength(1)))
            let unit = short
                ? L("playtime_unit_hours_short")
                : whole ? LPlural("playtime_unit_hours", tenths / 10) : L("playtime_unit_hours_fraction")
            return Parts(number: number, unit: unit)
        }
    }

    static func last(_ relative: LastStreamed, locale: Locale) -> String {
        switch relative {
        case .never: L("playtime_never")
        case .today: L("playtime_last_today")
        case .yesterday: L("playtime_last_yesterday")
        case .days(let count): LPlural("playtime_last_days", count)
        case .weeks(let count): LPlural("playtime_last_weeks", count)
        case .date(let date): date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
        }
    }
}

/// The info row under the title (`InfoBar` of DELOS for Android): the streaming-time block at its start, then 30 px
/// of air and the badges (the facts, a divider and the tags). The block gives up the last-streamed column, then the long
/// unit, when the row is too narrow; the badges scroll in the room it leaves when they do not fit. On a very narrow
/// compact stage ([above], ``HomeCompact/blockAbove(areaWidth:scale:)``) the block stands above the badges instead, and
/// scrolls when not even its short form fits the row.
struct InfoRow<Facts: View, Tags: View>: View {
    let playtime: Playtime
    /// Stage pixels: the row's height; with the block [above] the badges, the gap and the block's own height are in it.
    let height: Double
    let hasFacts: Bool
    let hasTags: Bool
    var above = false
    @ViewBuilder let facts: () -> Facts
    @ViewBuilder let tags: () -> Tags
    @Environment(\.stage) private var stage

    var body: some View {
        let texts = PlaytimeTexts(playtime)
        let block = above ? HomeCompact.blockHeight(stage.textScale) : height
        Group {
            if above {
                VStack(alignment: .leading, spacing: stage.px(HomeCompact.blockAboveGap)) {
                    stat(texts, height: block, scrolls: true)
                    BadgeStrip(hasFacts: hasFacts, hasTags: hasTags, facts: facts, tags: tags)
                }
            } else {
                HStack(spacing: stage.px(HomeCompact.blockGapX)) {
                    stat(texts, height: block, scrolls: false)
                        .layoutPriority(1)
                    BadgeStrip(hasFacts: hasFacts, hasTags: hasTags, facts: facts, tags: tags)
                }
            }
        }
        .frame(height: stage.px(height), alignment: .top)
    }

    /// The widest form of the block that fits; with [scrolls], the short one scrolling when none does (`StreamingTimeBlock`,
    /// PlaytimeBlock.kt:146-150), otherwise the short one whatever its width (InfoBar.kt:84-87).
    @ViewBuilder private func stat(_ texts: PlaytimeTexts, height: Double, scrolls: Bool) -> some View {
        if scrolls {
            ViewThatFits(in: .horizontal) {
                StatRow(texts: texts, fit: .full, height: height)
                StatRow(texts: texts, fit: .statOnly, height: height)
                StatRow(texts: texts, fit: .short, height: height)
                MarqueeContent(key: texts) { StatRow(texts: texts, fit: .short, height: height) }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                StatRow(texts: texts, fit: .full, height: height)
                StatRow(texts: texts, fit: .statOnly, height: height)
                StatRow(texts: texts, fit: .short, height: height)
            }
        }
    }
}

/// How much of the stat block is shown (`PlaytimeFit`).
enum PlaytimeFit {
    /// Streaming time, divider and last streamed.
    case full
    /// Streaming time with the full unit alone.
    case statOnly
    /// Streaming time with the short unit alone.
    case short
}

/// The streaming-time block (`StatRow`): the small-caps eyebrow STREAMING TIME in the main color over the amount (big
/// number, smaller unit), a thin divider, then LAST STREAMED over its day. Not focusable. Shown for an app never
/// streamed too ("0 hours", "Never").
private struct StatRow: View {
    let texts: PlaytimeTexts
    let fit: PlaytimeFit
    let height: Double
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        let parts = fit == .short ? texts.short : texts.full
        HStack(spacing: stage.px(22)) {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: texts.eyebrowTime, color: colors.accent)
                HStack(alignment: .firstTextBaseline, spacing: stage.px(8)) {
                    Text(parts.number)
                        .font(DelosFonts.figtree(stage.tpx(30), .bold).monospacedDigit())
                        .foregroundStyle(colors.text.color)
                    Text(parts.unit)
                        .font(DelosFonts.figtree(stage.tpx(20), .semibold))
                        .foregroundStyle(colors.text2.color)
                }
                .frame(height: stage.tpx(30))
            }
            if fit == .full {
                StatDivider()
                VStack(alignment: .leading, spacing: 0) {
                    Eyebrow(text: texts.eyebrowLast, color: colors.text3)
                    Text(texts.last)
                        .font(DelosFonts.figtree(stage.tpx(23), .semibold).monospacedDigit())
                        .foregroundStyle(colors.text2.color)
                        .frame(height: stage.tpx(30))
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
        .frame(height: stage.px(height))
        // A soft dark shadow: all the readability the texts get, no plate behind them
        .shadow(color: .black.opacity(0.6), radius: 4.5, y: 2)
    }
}

/// The small-caps label over a stat (STREAMING TIME, LAST STREAMED): 13 px bold, tracked 0.16 em.
struct Eyebrow: View {
    let text: String
    let color: RGBA
    @Environment(\.stage) private var stage

    var body: some View {
        Text(text)
            .font(DelosFonts.figtree(stage.tpx(13), .bold))
            .tracking(stage.tpx(13) * 0.16)
            .foregroundStyle(color.color)
            .frame(height: stage.tpx(14))
    }
}

/// The bar between the block's columns: 2 px wide, 38 px high at the interface scale, the main color at 70 % fading out
/// over 22 % at both ends.
struct StatDivider: View {
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        let solid = colors.accent.opacity(0.7).color
        Capsule()
            .fill(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: solid, location: 0.22),
                                         .init(color: solid, location: 0.78), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: stage.px(2), height: stage.tpx(38))
    }
}
