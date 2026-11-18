/// The codec a stream is asked for; the link guidance treats PyroWave and the ordinary codecs differently (LinkFormats.kt).
public enum LinkCodec: Equatable, Sendable {
    case pyroWave, h264, hevc, av1
    /// "Automatic": the codec is chosen when the stream starts, so the cautious middle of the ordinary codecs is assumed.
    case automatic

    /// The codec's name inside the format label ("1080p60 HEVC"); empty for Automatic. Product names, not translated.
    public var label: String {
        switch self {
        case .pyroWave: "PyroWave"
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .av1: "AV1"
        case .automatic: ""
        }
    }
}

/// What the recommended bitrate rests on (LinkRecommendation.kt).
public enum LinkReason: Equatable, Sendable {
    /// Only the format's own guide; the link was never tested.
    case untested
    /// The tested link carries what the format wants.
    case testedOK
    /// The tested link carries less than the format wants.
    case testedLimited
    /// The PC's own network link (`PyroWaveHostLinkMbps`) is below what the format wants.
    case hostLinkLimited
    /// The running stream drops frames at its bitrate.
    case dropping
}

/// [kbps] is the bitrate to offer, [reason] says why. [wantedKbps] is what the format would use if the link allowed
/// (PyroWave's guide, or an ordinary codec's useful maximum). [pictureKbps] is what a tested PyroWave budget leaves for
/// the image after FEC and overhead, or -1. [testedKbps] is the raw tested ceiling the reason names, or 0.
/// [hostLinkKbps] is the PC's own link when known, [droppedAtKbps] the bitrate a running stream drops frames at.
public struct LinkRecommendation: Equatable, Sendable {
    public var kbps: Int
    public var reason: LinkReason
    public var pictureKbps = -1
    public var wantedKbps = 0
    public var testedKbps = 0
    public var hostLinkKbps = 0
    public var droppedAtKbps = 0

    public init(
        kbps: Int, reason: LinkReason, pictureKbps: Int = -1, wantedKbps: Int = 0, testedKbps: Int = 0, hostLinkKbps: Int = 0,
        droppedAtKbps: Int = 0
    ) {
        self.kbps = kbps
        self.reason = reason
        self.pictureKbps = pictureKbps
        self.wantedKbps = wantedKbps
        self.testedKbps = testedKbps
        self.hostLinkKbps = hostLinkKbps
        self.droppedAtKbps = droppedAtKbps
    }
}

/// The most an ordinary codec is worth at [defaultKbps] (the app's default for the size and rate): a multiple, capped.
public func ordinaryWantedKbps(_ codec: LinkCodec, defaultKbps: Int) -> Int {
    let factor = switch codec {
    case .h264: LinkPolicy.h264CapFactor
    case .hevc: LinkPolicy.hevcCapFactor
    default: LinkPolicy.av1CapFactor
    }
    let scaled = Int(Double(defaultKbps) * factor / Double(LinkPolicy.stepKbps)) * LinkPolicy.stepKbps
    return min(LinkPolicy.ordinaryMaxKbps, max(defaultKbps, scaled))
}

/// The recommended bitrate: what the format wants ([staticKbps]), held to what the link carries. The bitrate setting is
/// a total wire allowance, like the probe's rate, so they compare directly, after [share] (1 for PyroWave;
/// ``LinkPolicy/ordinaryBudgetShare`` for the codecs with FEC and bursty rate control).
///
/// - [testedWireKbps]: the last confirmed link test, if any.
/// - [hostLinkKbps]: the PC's routed wired link speed, 0 or less when unknown. A ceiling only.
/// - [untestedKbps]: what is offered while nothing was tested (defaults to [staticKbps]).
/// - [live]: the running stream's drop hint; it can only lower the offer.
/// - [fps] and [transport]: with them a tested PyroWave budget also reports the picture bitrate it carries.
///
/// Never above what is wanted and never under the probe's 5 Mbps floor.
public func recommend(
    staticKbps: Int,
    testedWireKbps: Int? = nil,
    hostLinkKbps: Int = 0,
    live: LinkReading? = nil,
    fps: Int = 0,
    transport: WireTransport? = nil,
    share: Double = 1,
    untestedKbps: Int? = nil
) -> LinkRecommendation {
    let step = LinkPolicy.stepKbps
    let tested = testedWireKbps.flatMap { $0 > 0 ? $0 : nil }
    let ceiling = hostLinkKbps > 0 ? hostLinkKbps : nil
    let testedBudget = tested.map { Int(Double($0) * share) }
    let ceilingBudget = ceiling.map { Int(Double($0) * share) }
    let budget = [testedBudget, ceilingBudget].compactMap { $0 }.min()
    let base = tested != nil ? staticKbps : (untestedKbps ?? staticKbps)
    var kbps = budget.map { min(base, $0) } ?? base
    kbps = min(max(LinkPolicy.minKbps, kbps / step * step), max(base, LinkPolicy.minKbps))

    let picture = if let tested, fps > 0, let transport, share == 1 {
        Int(WireBudget.imageKbps(Double(tested), fps: fps, transport))
    } else {
        -1
    }
    func make(_ reason: LinkReason) -> LinkRecommendation {
        LinkRecommendation(
            kbps: kbps, reason: reason, pictureKbps: picture, wantedKbps: staticKbps, testedKbps: tested ?? 0,
            hostLinkKbps: ceiling ?? 0)
    }
    var result: LinkRecommendation
    if budget == nil || (tested == nil && budget! >= base) {
        result = make(.untested)
    } else if let testedBudget, testedBudget >= staticKbps, ceilingBudget.map({ $0 >= staticKbps }) ?? true {
        result = make(.testedOK)
    } else if let testedBudget, ceilingBudget.map({ testedBudget <= $0 }) ?? true {
        result = make(.testedLimited)
    } else {
        result = make(.hostLinkLimited)
    }
    if let live, live.verdict == .dropping, live.suggestedKbps < result.kbps {
        result.kbps = max(LinkPolicy.minKbps, live.suggestedKbps)
        result.reason = .dropping
        result.droppedAtKbps = live.targetKbps
    }
    return result
}
