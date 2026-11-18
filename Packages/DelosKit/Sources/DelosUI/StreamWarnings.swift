import DelosCore
import DelosData
import DelosHost
import Foundation
import Network
import SwiftUI

/// The notice of a poor connection over the running stream (`notificationOverlay` of DELOS for Android, activity_game.xml:39-51):
/// right-aligned text on half-transparent black in the top right corner, 10 dp from the edges, Android's large text (22 sp,
/// about 40 stage pixels on a phone). It takes no touches.
struct StreamConnectionNotice: View {
    let text: String
    @Environment(\.stage) private var stage

    var body: some View {
        Text(text)
            .font(DelosFonts.figtree(stage.tpx(40)))
            .foregroundStyle(.white)
            .multilineTextAlignment(.trailing)
            .background(Color.black.opacity(0.5))
            .padding(.top, stage.px(22 + stage.safe.top))
            .padding(.trailing, stage.px(22 + stage.safe.trailing))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .allowsHitTesting(false)
    }
}

/// The warnings a stream shows as it starts (DelosStreamActivity.java:474-479,515-540,596-609), in Android's order: a metered
/// network (unless the profile turned warnings off, `checkbox_disable_warnings`), HDR the display or the decoder cannot show,
/// and a codec chosen that this device cannot decode (PyroWave included: no Apple device decodes it).
enum StreamWarnings {
    static func of(settings: StreamSettings, decodable: VideoFormats, displaySupportsHDR: Bool, metered: Bool) -> [String] {
        var warnings: [String] = []
        if metered, !settings.bool(.disableWarnings) { warnings.append(L("conn_metered")) }
        if settings.hdr, !displaySupportsHDR { warnings.append(L("stream_warn_display_no_hdr10")) }
        if settings.codec == .pyroWave { warnings.append(L("stream_warn_pyrowave_unavailable")) }
        if settings.hdr, displaySupportsHDR, settings.codec != .pyroWave, decodable.isDisjoint(with: [.hevcMain10, .av1Main10]) {
            warnings.append(L("stream_warn_decoder_no_hdr10"))
        }
        if settings.codec == .hevc, !decodable.contains(.hevc) { warnings.append(L("stream_warn_no_hevc_decoder")) }
        if settings.codec == .av1, !decodable.contains(.av1Main8) { warnings.append(L("stream_warn_no_av1_decoder")) }
        return warnings
    }

    /// The notice over a running stream while the core judges the connection poor (`connectionStatusUpdate`,
    /// DelosStreamActivity.java:1731-1752): "slow" above 5 Mbps, where a lower bitrate helps, else "poor". Nil when okay or
    /// when the profile turned warnings off.
    static func connection(_ status: ConnectionStatus, bitrateKbps: Int, disabled: Bool) -> String? {
        guard status == .poor, !disabled else { return nil }
        return bitrateKbps > 5000 ? L("slow_connection_msg") : L("poor_connection_msg")
    }
}

/// Whether the network in use costs by the byte (`ConnectivityManager.isActiveNetworkMetered` of Android): an expensive
/// path (cellular, a personal hotspot) or one in Low Data Mode.
enum NetworkPath {
    static func isMetered() async -> Bool {
        let monitor = NWPathMonitor()
        let metered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OnceFlag()
            monitor.pathUpdateHandler = { path in
                if once.take() { continuation.resume(returning: path.isExpensive || path.isConstrained) }
            }
            monitor.start(queue: DispatchQueue(label: "io.github.meitoncz.delos.metered"))
        }
        monitor.cancel()
        return metered
    }
}

/// Lets one of several callbacks through.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.withLock {
            defer { taken = true }
            return !taken
        }
    }
}

/// What a launch that the PC did not answer does next (NvConnection.java:413-458 with `stageFailed`,
/// DelosStreamActivity.java:1657-1664): the first two times, unless the connection test found the PC's ports blocked, it waits
/// ``pause`` and asks again (the loader tells the "unlocking" lines); the third is a time-out.
enum LaunchRetry {
    static let pause = Duration.seconds(2)

    /// No answer at all (Android's IOException and XmlPullParserException): a PC that is waking up, unlocking or starting
    /// its server. A host that answered with a status is no such case.
    static func isUnanswered(_ error: any Error) -> Bool {
        switch error {
        case HostError.unreachable, HostError.timedOut, HostError.refused, HostError.malformedResponse: true
        default: false
        }
    }

    /// The failure after attempt [attempt] (from 0) went unanswered and the launch ports tested [test]; nil: ask again.
    static func after(attempt: Int, test: PortTest.Result) -> LaunchFailure? {
        let errorCode: Int32 = attempt < 2 ? 0 : -408
        if errorCode == 0, !test.blocked { return nil }
        return .unreachable(errorCode: errorCode, ports: PortTest.describe(PortTest.launchPorts), blocked: test.blocked)
    }
}
