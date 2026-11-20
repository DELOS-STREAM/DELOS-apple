import DelosData
import Foundation
import SwiftUI
#if !os(tvOS)
import WebKit
#endif

/// The overview's videos YouTube does not let play in the app, for the whole process: the oEmbed pre-check
/// (``YouTubeEmbed``) and the player's own errors 100, 101 and 150 add to it. The carousel leaves them out.
@MainActor
@Observable
final class OverviewVideos {
    static let shared = OverviewVideos()

    private(set) var unplayable: Set<String> = []
    /// The ids asked about (or being asked about) in this process.
    @ObservationIgnored private var checked: Set<String> = []

    func markUnplayable(_ id: String) {
        if !unplayable.contains(id) { unplayable.insert(id) }
    }

    /// Asks YouTube about every id not asked about yet, all at once. An id without an answer is kept and asked about again
    /// the next time.
    func check(_ ids: [String]) async {
        #if os(tvOS)
        return
        #else
        #if DEBUG
        // The demo's videos are invented
        if DemoHarness.on { return }
        #endif
        let new = ids.filter { checked.insert($0).inserted }
        guard !new.isEmpty else { return }
        await withTaskGroup(of: (String, Bool?).self) { group in
            for id in new { group.addTask { (id, await YouTubeEmbed.embeddable(id)) } }
            for await (id, embeddable) in group {
                switch embeddable {
                case false?: markUnplayable(id)
                case true?: break
                case nil: checked.remove(id)
                }
            }
        }
        #endif
    }
}

/// The viewer's in-app YouTube player as DELOS sees it: the shown video's state as the player reports it (every 500 ms
/// and on each change) and the commands DELOS's controls send to it.
@MainActor
@Observable
final class OverviewVideo {
    /// The video the player plays; nil: no player.
    private(set) var videoID: String?
    /// YouTube's state: -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued.
    private(set) var state = -1
    private(set) var time = 0.0
    private(set) var duration = 0.0
    private(set) var muted = false
    /// The player has played once: the web view shows instead of the thumbnail.
    private(set) var started = false
    /// The player's error code (-1: it did not load).
    private(set) var error: Int?
    /// A status has come since the player was made.
    @ObservationIgnored private(set) var reported = false
    /// Runs JavaScript in the player's page; nil while there is no player.
    @ObservationIgnored var run: (@MainActor (String) -> Void)?

    var playing: Bool { state == 1 || state == 3 }

    /// The player's codes that mean the video can never play here: 100 (gone or private), 101 and 150 (its owner does
    /// not allow other apps).
    nonisolated static func unplayable(code: Int) -> Bool { [100, 101, 150].contains(code) }
    /// The codes the error explains as its owner's choice.
    nonisolated static func blocked(code: Int) -> Bool { [101, 150].contains(code) }

    /// `m:ss`, `h:mm:ss` from an hour.
    nonisolated static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds : 0))
        let h = s / 3600, m = s / 60 % 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// A fresh state for the player of [videoID] (nil: the player goes away).
    func reset(_ videoID: String?) {
        self.videoID = videoID
        state = -1
        time = 0
        duration = 0
        muted = false
        started = false
        error = nil
        reported = false
        run = nil
    }

    private struct Message: Decodable {
        let type: String
        var state: Int?
        var time: Double?
        var duration: Double?
        var muted: Bool?
        var code: Int?
    }

    /// A message of the player's page (`{type: 'status' | 'error', …}` as JSON).
    func receive(_ json: String) {
        guard videoID != nil, let message = try? JSONDecoder().decode(Message.self, from: Data(json.utf8)) else { return }
        switch message.type {
        case "status":
            reported = true
            if let value = message.state, value != state { state = value }
            if let value = message.time, value != time { time = value }
            if let value = message.duration, value != duration { duration = value }
            if let value = message.muted, value != muted { muted = value }
            if playing, !started { started = true }
        case "error":
            fail(message.code ?? -1)
        default: break
        }
    }

    /// The player cannot play the video: the error shows instead of it; a video that never can is left out from now on.
    func fail(_ code: Int) {
        guard error == nil, let videoID else { return }
        error = code
        run = nil
        if Self.unplayable(code: code) { OverviewVideos.shared.markUnplayable(videoID) }
    }

    /// A: play or pause; at the end, from the start again.
    func toggle() {
        if state == 0 { send("player.seekTo(0,true);player.playVideo()") } else if playing { send("player.pauseVideo()") } else { send("player.playVideo()") }
    }

    func pause() { send("player.pauseVideo()") }

    func seek(by seconds: Double) { send("player.seekTo(Math.max(0,player.getCurrentTime()+\(seconds)),true)") }

    func seek(to fraction: Double) { send("player.seekTo(\(min(max(fraction, 0), 1))*player.getDuration(),true)") }

    func toggleMute() { send(muted ? "player.unMute()" : "player.mute()") }

    private func send(_ command: String) {
        guard error == nil else { return }
        run?("if(player&&player.getPlayerState){\(command);status();}")
    }
}

#if !os(tvOS)
/// The embedded YouTube IFrame player (privacy-enhanced mode, youtube-nocookie.com) in a web view that cannot leave its
/// page: every navigation of the page but its first load is cancelled, new windows are never made, so nothing opens
/// outside the app. It loads with the app's identity as its origin (the Referer YouTube asks for), autoplays once shown and
/// reports to ``OverviewVideo``.
@MainActor
struct OverviewVideoPlayer {
    let videoID: String
    let video: OverviewVideo

    /// The page's origin: `https://` and the bundle id.
    static var origin: String { "https://" + (Bundle.main.bundleIdentifier ?? "delos").lowercased() }

    static func html(videoID: String, origin: String) -> String {
        """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#p{position:absolute;inset:0;width:100%;height:100%}</style></head>
        <body><div id="p"></div><script>
        var player,timer;
        function post(o){webkit.messageHandlers.delos.postMessage(JSON.stringify(o));}
        function status(){ if(!player||!player.getPlayerState)return; post({type:'status',state:player.getPlayerState(),time:player.getCurrentTime()||0,duration:player.getDuration()||0,muted:player.isMuted()}); }
        function onYouTubeIframeAPIReady(){
         player=new YT.Player('p',{host:'https://www.youtube-nocookie.com',videoId:'\(videoID)',
          playerVars:{playsinline:1,rel:0,controls:0,fs:0,disablekb:1,iv_load_policy:3,autoplay:1,enablejsapi:1,origin:'\(origin)'},
          events:{onReady:function(){player.playVideo();status();timer=setInterval(status,500);},
                  onStateChange:function(){status();},
                  onError:function(e){post({type:'error',code:e.data});}}});
        }
        </script><script src="https://www.youtube.com/iframe_api" onerror="post({type:'error',code:-1})"></script></body></html>
        """
    }

    /// Whether the web view may go where [targetMainFrame] (nil: a new window) and [url] say: the page's own first load and
    /// `about:` pages in the main frame, anything inside the player's frame, never a new window.
    nonisolated static func allows(targetMainFrame: Bool?, url: URL?, firstLoad: Bool, origin: String) -> Bool {
        guard let targetMainFrame else { return false }
        if !targetMainFrame { return true }
        if url?.scheme == "about" { return true }
        guard firstLoad, let url, let host = URL(string: origin)?.host else { return false }
        return url.scheme == "https" && url.host == host
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let video: OverviewVideo
        var firstLoad = true
        var navigation: WKNavigation?
        var watchdog: Task<Void, Never>?

        init(video: OverviewVideo) { self.video = video }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let main = navigationAction.targetFrame?.isMainFrame
            let allowed = !navigationAction.shouldPerformDownload
                && OverviewVideoPlayer.allows(targetMainFrame: main, url: navigationAction.request.url, firstLoad: firstLoad, origin: OverviewVideoPlayer.origin)
            if allowed, main == true, navigationAction.request.url?.scheme != "about" { firstLoad = false }
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            if navigation == self.navigation { video.fail(-1) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            if navigation == self.navigation { video.fail(-1) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { video.fail(-1) }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }

    /// Hands the page's messages on without the web view's content controller keeping the coordinator alive.
    private final class MessageProxy: NSObject, WKScriptMessageHandler {
        weak var coordinator: Coordinator?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? String else { return }
            coordinator?.video.receive(body)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(video: video) }

    private func make(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = false
        #endif
        let proxy = MessageProxy()
        proxy.coordinator = coordinator
        configuration.userContentController.add(proxy, name: "delos")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = coordinator
        web.uiDelegate = coordinator
        web.allowsLinkPreview = false
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        #else
        web.underPageBackgroundColor = .black
        #endif
        video.run = { [weak web] script in web?.evaluateJavaScript(script, completionHandler: nil) }
        coordinator.navigation = web.loadHTMLString(Self.html(videoID: videoID, origin: Self.origin), baseURL: URL(string: Self.origin))
        // No status within 15 s: the player did not load
        coordinator.watchdog = Task { @MainActor [video] in
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled, !video.reported { video.fail(-1) }
        }
        return web
    }

    private static func dismantle(_ web: WKWebView, _ coordinator: Coordinator) {
        coordinator.watchdog?.cancel()
        web.pauseAllMediaPlayback(completionHandler: nil)
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "delos")
    }
}

#if os(iOS)
extension OverviewVideoPlayer: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { dismantle(view, coordinator) }
}
#else
extension OverviewVideoPlayer: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { dismantle(view, coordinator) }
}
#endif

/// The player's controls, a glass pill under the video (nothing of DELOS lies over the player): back 10 s, play or pause,
/// forward 10 s, the elapsed time, the progress (a click or a tap on it seeks there), the duration and the sound.
struct OverviewVideoBar: View {
    let video: OverviewVideo
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        HStack(spacing: stage.px(14)) {
            button(Symbols.playerBack, label: L("overview_video_back")) { video.seek(by: -10) }
            Button { video.toggle() } label: {
                SymbolView(symbol: video.playing ? Symbols.playerPause : Symbols.playerPlay, size: 30, color: colors.onAccent, filled: true)
                    .frame(width: stage.px(56), height: stage.px(56))
                    .background(Circle().fill(colors.accent.color))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(video.playing ? L("overview_hint_pause") : L("overview_hint_play"))
            button(Symbols.playerForward, label: L("overview_video_forward")) { video.seek(by: 10) }
            Text(OverviewVideo.clock(video.time)).font(DelosFonts.figtree(stage.tpx(20), .bold)).foregroundStyle(colors.text.color)
                .padding(.leading, stage.px(6))
            GeometryReader { proxy in
                let fraction = video.duration > 0 ? min(max(video.time / video.duration, 0), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(colors.text.color.opacity(0.18))
                    Capsule().fill(colors.accent.color).frame(width: proxy.size.width * fraction)
                }
                .frame(height: stage.px(6))
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { point in
                    if proxy.size.width > 0 { video.seek(to: point.x / proxy.size.width) }
                }
            }
            Text(OverviewVideo.clock(video.duration)).font(DelosFonts.figtree(stage.tpx(20), .bold)).foregroundStyle(colors.text2.color)
            button(video.muted ? Symbols.playerMuted : Symbols.playerSound, label: video.muted ? L("overview_hint_unmute") : L("overview_hint_mute")) {
                video.toggleMute()
            }
        }
        .monospacedDigit()
        .padding(.horizontal, stage.px(10))
        .frame(height: stage.px(72))
        .background(GlassShape(Capsule(), tint: colors.surface))
    }

    private func button(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SymbolView(symbol: icon, size: 28, color: colors.text)
                .frame(width: stage.px(52), height: stage.px(52))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
#endif

/// In place of a video that cannot play: the thumbnail dimmed, a warning and why.
struct OverviewVideoError: View {
    let code: Int
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: stage.px(14)) {
                SymbolView(symbol: Symbols.warning, size: 56, color: RGBA(red: 1, green: 1, blue: 1))
                Text(L("overview_video_unavailable")).font(DelosFonts.unbounded(stage.tpx(28), .semibold)).foregroundStyle(.white)
                Text(OverviewVideo.blocked(code: code) ? L("overview_video_blocked") : L("overview_video_failed"))
                    .font(DelosFonts.figtree(stage.tpx(22), .medium)).foregroundStyle(.white.opacity(0.8))
            }
            .multilineTextAlignment(.center)
            .padding(stage.px(60))
        }
    }
}
