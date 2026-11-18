/// Every number of the link test and the link guidance, in one place (`LinkPolicy` of DELOS for Android, LinkPolicy.kt).
/// The probe and wire-budget values are the host's protocol (Vibepollo `docs/pyrowave-protocol.md`, "FEC-inclusive
/// recommendations and UDP calibration"); the pass thresholds are the reference client's (Nonary/moonlight-qt
/// `pyrowavelinkpolicy.h`); the hint values are DELOS's own.
public enum LinkPolicy {
    // MARK: Probe protocol

    /// One probe sends for two seconds, paced in 1 ms groups.
    public static let probeDurationMs = 2000
    public static let windowMs = 100
    public static let windowCount = probeDurationMs / windowMs

    /// The host accepts 5000...3000000 kbps and the search ends at this precision.
    public static let minKbps = 5000
    public static let maxKbps = 3_000_000
    public static let stepKbps = 5000

    /// The host accepts 256...1392 byte packets; 1392 is the streaming packet size.
    public static let minPacketSize = 256
    public static let maxPacketSize = 1392
    public static let defaultPacketSize = maxPacketSize

    /// The UDP payload is `packetsize + 48`: ASCII token (32), big-endian sequence (4), filler.
    public static let payloadExtraBytes = 48
    public static let tokenLength = 32
    public static let sequenceOffset = 32

    /// Each probe packet is charged `packetsize + 134` wire bytes (IPv6, encryption, Ethernet overhead).
    public static let wireOverheadBytes = 134

    /// The client repeats its token this often until the first measured packet arrives.
    public static let handshakeRetryMs = 100

    /// Late packets of the last group still count; the delay is charged against the send schedule.
    public static let drainMs = 100

    /// Whole probe request: handshake (1.5 s) + send (2 s) + margin.
    public static let requestTimeoutMs = 6000
    public static let receiveBufferBytes = 8 * 1024 * 1024

    // MARK: A probe passes when (the reference client's rules)

    /// Aggregate loss must stay below this (`lossLimitPercent = 2.0`, compared with `<`).
    public static let maxLossPercent = 2.0
    /// Loss in any 100 ms window must stay below this (`windowLossLimitPercent = 5.0`, `<`).
    public static let maxWindowLossPercent = 5.0
    /// The host must have sent at least this share of the planned packets (`minimumSentShare = 0.98`).
    public static let minSentShare = 0.98
    /// Delay growth, last window less first, must stay at or below this.
    public static let maxDelayGrowthMs = 2.0
    /// p99 transit variation above this is only a warning ("a little jitter").
    public static let jitterWarningP99Ms = 4.0
    /// The host's sending duration may differ from ``probeDurationMs`` by this share.
    public static let durationTolerance = 0.02

    // MARK: Our own receiver

    /// A loss with this much time between a datagram arriving and the loop being done with it points at our receiver.
    public static let receiverStallMs = 5.0
    /// A receive buffer the OS granted below this cannot hold even a short stall at several hundred Mbps.
    public static let minGoodReceiveBufferBytes = 2 * 1024 * 1024

    // MARK: Search

    public static let growthFactor = 1.25
    public static let confirmMargin = 0.95
    public static let confirmBackoff = 0.8
    public static let confirmRuns = 2
    public static let maxSearchProbes = 40
    public static let maxConfirmAttempts = 32

    // MARK: Wire budget

    /// Eight high-quality audio channels, audio parity and control traffic, reserved from every wire budget.
    public static let audioControlKbps = 3572.0
    public static let frameHeaderBytes = 8
    public static let maxFECBlockShards = 255

    // MARK: Ordinary codecs (H.264, HEVC, AV1)

    /// An ordinary codec is recommended at most this share of the tested wire budget: a live stream also carries FEC,
    /// audio and control, and its rate control overshoots on scene cuts and keyframes. PyroWave is exempt.
    public static let ordinaryBudgetShare = 0.65
    /// The useful maximum is the app's default bitrate for the resolution and rate times this factor.
    public static let h264CapFactor = 3.0
    public static let hevcCapFactor = 2.0
    public static let av1CapFactor = 2.0
    /// No ordinary codec is recommended more than this; hardware decoders top out near it.
    public static let ordinaryMaxKbps = 150_000

    // MARK: Passive hint

    /// The rolling window of the in-stream verdict, in seconds.
    public static let hintWindowSeconds: Float = 5
    /// The verdict needs at least this many seconds of samples at the current bitrate.
    public static let hintMinSeconds: Float = 3
    /// Partial plus lost frames, as a share of the window's frames, above which the link counts as dropping.
    public static let hintDropShare = 0.02
    /// The suggested bitrate is the target less this times the drop share, within the two bounds.
    public static let hintCutPerShare = 4.0
    public static let hintMinCut = 0.10
    public static let hintMaxCut = 0.40

    /// Milliseconds per day, for the age text.
    public static let msPerDay: Int64 = 86_400_000
}
