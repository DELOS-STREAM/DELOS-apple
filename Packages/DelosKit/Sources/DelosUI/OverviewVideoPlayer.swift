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

/// The viewer's video player as DELOS sees it, YouTube's in-app player or AVPlayer for a Steam movie: the shown video's
/// state as the player reports it (every 500 ms and on each change) and the commands DELOS's controls send to it.
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
    /// The share of the video the player has loaded (`getVideoLoadedFraction`), 0…1.
    private(set) var loaded = 0.0
    /// The player's volume (`getVolume`), 0…100.
    private(set) var volume = 100.0
    /// The player has played once: the web view shows instead of the thumbnail.
    private(set) var started = false
    /// The player's error code (-1: it did not load).
    private(set) var error: Int?
    /// A status has come since the player was made.
    @ObservationIgnored private(set) var reported = false
    /// Runs JavaScript in the YouTube player's page; nil while there is no such player.
    @ObservationIgnored var run: (@MainActor (String) -> Void)?
    /// The native player of a Steam movie; nil while there is none.
    @ObservationIgnored private(set) var native: OverviewNativePlayback?
    let controls = OverviewViewerControls()
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored private var active = true
    @ObservationIgnored private var wantsPlayback = true

    /// Revokes pending autoplay as well as current playback. Foregrounding alone does not restart a paused trailer.
    func setActive(_ value: Bool) {
        active = value
        if !value {
            wantsPlayback = false
            state = 2
        }
        applyPlayback()
    }

    private func applyPlayback() {
        if let native { native.setPlaying(active && wantsPlayback); return }
        run?("if(window.setPlaybackAllowed){setPlaybackAllowed(\(active),\(wantsPlayback));}")
    }

    /// The native player for the current video is ready: it takes the commands and starts when playback is allowed.
    func attach(_ player: OverviewNativePlayback, generation: Int) {
        guard generation == self.generation, error == nil else { return }
        native = player
        applyPlayback()
    }

    /// The native player [player] went away (its view was dismantled).
    func detach(_ player: OverviewNativePlayback) {
        if native === player { native = nil }
    }

    var playing: Bool { state == 1 || state == 3 }

    /// DEBUG only: `-DelosMuteMedia YES` starts every trailer muted, so a simulator stays silent.
    static var startsMuted: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "DelosMuteMedia")
        #else
        false
        #endif
    }

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
        generation += 1
        self.videoID = videoID
        state = -1
        time = 0
        duration = 0
        muted = false
        loaded = 0
        volume = 100
        started = false
        error = nil
        reported = false
        run = nil
        native?.invalidate()
        native = nil
        wantsPlayback = active
    }

    private struct Message: Decodable {
        let type: String
        var state: Int?
        var time: Double?
        var duration: Double?
        var muted: Bool?
        var loaded: Double?
        var volume: Double?
        var code: Int?
    }

    /// A message of the player's page (`{type: 'status' | 'error', …}` as JSON).
    func receive(_ json: String) {
        guard videoID != nil, let message = try? JSONDecoder().decode(Message.self, from: Data(json.utf8)) else { return }
        switch message.type {
        case "ready":
            if Self.startsMuted { run?("if(window.player&&player.mute){player.mute();}") }
            applyPlayback()
        case "status":
            report(state: message.state, time: message.time, duration: message.duration, muted: message.muted,
                   loaded: message.loaded, volume: message.volume)
        case "error":
            fail(message.code ?? -1)
        default: break
        }
    }

    /// A status of the player, YouTube's page or AVPlayer: the values it has. YouTube's player counts as started once it
    /// plays; the native one once its first frame is on screen (``firstFrame()``).
    func report(state newState: Int?, time newTime: Double?, duration newDuration: Double?, muted newMuted: Bool?,
                loaded newLoaded: Double?, volume newVolume: Double?) {
        reported = true
        if let value = newState, value != state { state = value }
        if !active || !wantsPlayback {
            if state == 1 || state == 3 { applyPlayback() }
            state = 2
        }
        if let value = newTime, value != time { time = value }
        if let value = newDuration, value != duration { duration = value }
        if let value = newMuted, value != muted { muted = value }
        if let value = newLoaded, value != loaded { loaded = min(max(value, 0), 1) }
        if let value = newVolume, value != volume { volume = min(max(value, 0), 100) }
        if state == 1, !started, native == nil { started = true }
    }

    /// The native player shows its first frame: the sharp video replaces the blurred thumbnail.
    func firstFrame() {
        if !started { started = true }
    }

    /// The player cannot play the video: the error shows instead of it; a video that never can is left out from now on.
    func fail(_ code: Int) {
        guard error == nil, let videoID else { return }
        pause()
        error = code
        run = nil
        native?.invalidate()
        native = nil
        if Self.unplayable(code: code) { OverviewVideos.shared.markUnplayable(videoID) }
    }

    /// A: play or pause; at the end, from the start again.
    func toggle() {
        guard active, error == nil else { return }
        wantsPlayback = !playing
        if let native { native.setPlaying(wantsPlayback); return }
        if state == 0 { send("player.seekTo(0,true);player.playVideo()") }
        else if wantsPlayback { send("player.playVideo()") }
        else { send("player.pauseVideo()") }
    }

    func pause() {
        wantsPlayback = false
        state = 2
        applyPlayback()
    }

    func seek(by seconds: Double) {
        if let native, error == nil { native.seek(by: seconds); return }
        send("player.seekTo(Math.max(0,player.getCurrentTime()+\(seconds)),true)")
    }

    func seek(to fraction: Double) {
        let f = min(max(fraction, 0), 1)
        if let native, error == nil { native.seek(to: f * duration); return }
        send("player.seekTo(\(f)*player.getDuration(),true)")
    }

    func toggleMute() {
        if let native, error == nil { native.setMuted(!muted); return }
        send(muted ? "player.unMute()" : "player.mute()")
    }

    /// Sets the volume to [value] (0…100); a volume above 0 turns the sound on.
    func setVolume(_ value: Double) {
        let v = min(max(value.rounded(), 0), 100)
        guard error == nil, run != nil || native != nil else { return }
        volume = v
        if let native { native.setVolume(v / 100); return }
        send("player.setVolume(\(Int(v)))" + (v > 0 ? ";player.unMute()" : ""))
    }

    private func send(_ command: String) {
        guard error == nil else { return }
        run?("if(window.playbackAllowed&&player&&player.getPlayerState){\(command);status();}")
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
    /// The page takes touches and clicks (YouTube's own surface, such as an ad's Skip): only while the viewer's overlay is
    /// hidden. Otherwise the overlay's tap layer takes them.
    var interactive = false
    /// A tap that reached the page (while [interactive]): the viewer shows its overlay; the page still gets the tap.
    var onTap: @MainActor () -> Void = {}

    /// The page's origin: `https://` and the bundle id.
    static var origin: String { "https://" + (Bundle.main.bundleIdentifier ?? "delos").lowercased() }

    static func html(videoID: String, origin: String) -> String {
        """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#p{position:absolute;inset:0;width:100%;height:100%}</style></head>
        <body><div id="p"></div><script>
        var player,timer,ready=false,playbackAllowed=false;
        function post(o){webkit.messageHandlers.delos.postMessage(JSON.stringify(o));}
        function status(){ if(!ready||!player.getPlayerState)return; post({type:'status',state:player.getPlayerState(),time:player.getCurrentTime()||0,duration:player.getDuration()||0,muted:player.isMuted(),loaded:player.getVideoLoadedFraction()||0,volume:player.getVolume()}); }
        function setPlaybackAllowed(allowed,wanted){playbackAllowed=allowed;if(!ready)return;if(allowed&&wanted)player.playVideo();else player.pauseVideo();}
        function onYouTubeIframeAPIReady(){
         player=new YT.Player('p',{host:'https://www.youtube-nocookie.com',videoId:'\(videoID)',
          playerVars:{playsinline:1,rel:0,controls:0,fs:0,disablekb:1,iv_load_policy:3,autoplay:0,enablejsapi:1,origin:'\(origin)'},
          events:{onReady:function(){ready=true;post({type:'ready'});status();timer=setInterval(status,500);},
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
        var onTap: @MainActor () -> Void = {}
        let generation: Int
        private(set) var attached = true
        var firstLoad = true
        var navigation: WKNavigation?
        var watchdog: Task<Void, Never>?

        init(video: OverviewVideo) {
            self.video = video
            generation = video.generation
        }

        var current: Bool { attached && generation == video.generation }

        func receive(_ message: String) {
            guard current else { return }
            video.receive(message)
        }

        func invalidate() {
            attached = false
            watchdog?.cancel()
            if generation == video.generation {
                video.setActive(false)
                video.run = nil
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let main = navigationAction.targetFrame?.isMainFrame
            let allowed = !navigationAction.shouldPerformDownload
                && OverviewVideoPlayer.allows(targetMainFrame: main, url: navigationAction.request.url, firstLoad: firstLoad, origin: OverviewVideoPlayer.origin)
            if allowed, main == true, navigationAction.request.url?.scheme != "about" { firstLoad = false }
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            if current, navigation == self.navigation { video.fail(-1) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            if current, navigation == self.navigation { video.fail(-1) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if current { video.fail(-1) } }

        @objc func tapped() { onTap() }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }

    /// Hands the page's messages on without the web view's content controller keeping the coordinator alive.
    private final class MessageProxy: NSObject, WKScriptMessageHandler {
        weak var coordinator: Coordinator?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? String else { return }
            coordinator?.receive(body)
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
        web.isUserInteractionEnabled = interactive
        web.accessibilityElementsHidden = true
        // Sees the page's taps without taking them from it
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = coordinator
        web.addGestureRecognizer(tap)
        #else
        web.underPageBackgroundColor = .black
        #endif
        video.run = { [weak web, weak coordinator] script in
            guard coordinator?.current == true else { return }
            web?.evaluateJavaScript(script, completionHandler: nil)
        }
        coordinator.navigation = web.loadHTMLString(Self.html(videoID: videoID, origin: Self.origin), baseURL: URL(string: Self.origin))
        // No status within 15 s: the player did not load
        coordinator.watchdog = Task { @MainActor [weak coordinator] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let coordinator, coordinator.current else { return }
            if !coordinator.video.reported { coordinator.video.fail(-1) }
        }
        return web
    }

    private static func dismantle(_ web: WKWebView, _ coordinator: Coordinator) {
        coordinator.invalidate()
        web.evaluateJavaScript("if(window.setPlaybackAllowed){setPlaybackAllowed(false,false)}", completionHandler: nil)
        web.pauseAllMediaPlayback(completionHandler: nil)
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "delos")
    }
}

#if os(iOS)
extension OverviewVideoPlayer: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.onTap = onTap
        return make(context.coordinator)
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onTap = onTap
        if view.isUserInteractionEnabled != interactive { view.isUserInteractionEnabled = interactive }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { dismantle(view, coordinator) }
}

extension OverviewVideoPlayer.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#else
extension OverviewVideoPlayer: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { dismantle(view, coordinator) }
}
#endif
#endif

/// In place of a video that cannot play: the thumbnail dimmed, a warning and why. [steam]: a Steam movie AVPlayer could
/// not load (no owner's choice there).
struct OverviewVideoError: View {
    let code: Int
    var steam = false
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: stage.px(14)) {
                SymbolView(symbol: Symbols.warning, size: 56, color: RGBA(red: 1, green: 1, blue: 1))
                Text(L("overview_video_unavailable")).font(DelosFonts.unbounded(stage.tpx(28), .semibold)).foregroundStyle(.white)
                Text(steam ? L("overview_video_failed_steam") : OverviewVideo.blocked(code: code) ? L("overview_video_blocked") : L("overview_video_failed"))
                    .font(DelosFonts.figtree(stage.tpx(22), .medium)).foregroundStyle(.white.opacity(0.8))
            }
            .multilineTextAlignment(.center)
            .padding(stage.px(60))
        }
    }
}
