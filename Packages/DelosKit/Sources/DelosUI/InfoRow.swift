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
/// of air and the badges. The block gives up the last-streamed column, then the long unit, when the row is too narrow.
struct InfoRow<Badges: View>: View {
    let playtime: Playtime
    /// Stage pixels: the block's height at the interface scale.
    let height: Double
    @ViewBuilder let badges: () -> Badges
    @Environment(\.stage) private var stage

    var body: some View {
        let texts = PlaytimeTexts(playtime)
        HStack(spacing: stage.px(30)) {
            ViewThatFits(in: .horizontal) {
                StatRow(texts: texts, fit: .full, height: height)
                StatRow(texts: texts, fit: .statOnly, height: height)
                StatRow(texts: texts, fit: .short, height: height)
            }
            HStack(spacing: stage.px(12)) { badges() }
                .fixedSize()
        }
        .frame(height: stage.px(height))
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
        .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
    }
}

private struct Eyebrow: View {
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
private struct StatDivider: View {
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
