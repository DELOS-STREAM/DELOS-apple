import DelosData
import DelosInput
import DelosMedia
import Foundation

extension PictureFit {
    /// The Display settings' scale mode.
    init(_ mode: VideoScaleMode) {
        self = switch mode {
        case .fit: .fit
        case .fill: .fill
        case .stretch: .stretch
        }
    }
}

/// How the picture is zoomed and panned on the surface (``PanZoom``): a point p of the unzoomed surface shows at
/// `p * scale + (tx, ty)`, in pixels.
struct VideoZoom: Equatable {
    var scale = 1.0
    var tx = 0.0
    var ty = 0.0
}

/// The picture the stream shows: its size and how the surface places it (the Display settings' scale mode and
/// `checkbox_enable_view_top_center`).
struct TouchPicture: Equatable {
    var width: Int
    var height: Int
    var fit: PictureFit
    var topAligned = false
}

/// The touch screen, the pencil and the pointer of the stream (``TouchScreen``), and what the stream menu's Mouse page
/// and touch rows use (`StreamMenuHost` of DELOS for Android: `mouseMode`, `setMouseMode`, `localMouseCursorVisible`,
/// `zoomOn`, `touchSensitivityOn`).
extension StreamController {
    /// UIKit's touch times (seconds since the start) in the milliseconds of the touch contexts.
    static func milliseconds(_ time: TimeInterval) -> Int64 { Int64((time * 1000).rounded()) }

    /// The input runs: the touch screen starts in the profile's mode with the remembered zoom, the local pointer as the
    /// profile wants it.
    func startTouch(sink: any StreamInputSink, input: GameInput) {
        let options = touchOptions
        let screen = TouchScreen(sink: sink, options: options, externalDisplay: touchOnExternalDisplay)
        screen.host = StreamTouchHost(self)
        screen.capturing = { [weak self] in self?.input?.inputGrabbed ?? false }
        screen.onModeSaved = { [weak self] mode in self?.touchModeChosen?(mode) }
        screen.onZoomChanged = { [weak self] in self?.syncZoom() }
        if options.rememberZoomPan, let saved = zoomStore?.load() { screen.restoreZoom(scale: saved.scale, x: saved.x, y: saved.y) }
        touchScreen = screen
        touchMode = screen.mode
        zoomOn = screen.zoomMode
        touchSensitivityOn = screen.touchSensitivityOn
        input.trackpadSwapAxis = options.trackpadSwapAxis
        input.trackpadSensitivity = (options.trackpadSensitivityX, options.trackpadSensitivityY)
        setLocalCursor(options.localCursor)
        if let area = touchArea { surfaceLaidOut(area) }
    }

    /// The input stops: what the fingers hold comes up, and the zoom is kept when the profile remembers it
    /// (`saveZoomAndPan`).
    func stopTouch() {
        guard let screen = touchScreen else { return }
        if touchOptions.rememberZoomPan, screen.surface != nil {
            zoomStore?.save(ZoomPanStore.Saved(scale: screen.zoom.scale, x: screen.zoom.x, y: screen.zoom.y))
        }
        screen.stop()
        touchScreen = nil
    }

    /// The surface laid out at [area]: touches, the local pointer and the absolute mouse are measured against the picture
    /// on it.
    func surfaceLaidOut(_ area: TouchArea) {
        touchArea = area
        guard area.width > 0, area.height > 0 else { return }
        let picture = touchPicture
        let surface = TouchSurface(
            width: area.width, height: area.height, videoWidth: picture?.width ?? 0, videoHeight: picture?.height ?? 0,
            fit: picture?.fit ?? .stretch, topAligned: picture?.topAligned ?? false)
        touchScreen?.touchSlop = 8 * area.scale
        touchScreen?.setSurface(surface)
        input?.absoluteMouseArea = touchOptions.absoluteMouseMode ? surface.pictureSize : nil
    }

    func syncZoom() {
        guard let screen = touchScreen, let surface = screen.surface else { return }
        let transform = screen.zoom.transform(on: surface)
        let zoom = VideoZoom(scale: transform.scale, tx: transform.tx, ty: transform.ty)
        if videoZoom != zoom { videoZoom = zoom }
    }

    /// A pencil hovering over the surface (nil: it left), `distance` 0…1.
    func penHover(at point: CGPoint?, distance: Double, azimuth: Double?, altitude: Double?, area: TouchArea, time: TimeInterval) {
        guard phase == .streaming, !menuOpen, !loader.cancellable, let touchScreen else { return }
        surfaceLaidOut(area)
        let sample = point.map {
            TouchSample(id: 0, x: $0.x, y: $0.y, tool: .pencil, pressure: distance, azimuth: azimuth, altitude: altitude)
        }
        touchScreen.penHover(sample, time: Self.milliseconds(time))
    }

    /// The system pointer moved over the surface to [point]: with the local pointer shown, the PC's pointer follows it.
    func pointerMoved(to point: CGPoint, area: TouchArea) {
        guard localCursorVisible, phase == .streaming, !menuOpen, let touchScreen else { return }
        if area != touchArea { surfaceLaidOut(area) }
        touchScreen.pointerMoved(x: point.x, y: point.y)
    }

    /// The Mac's scroll wheel or trackpad over the stream (``GameInput/scrollWheel(dx:dy:precise:)``).
    func scrollWheel(dx: Double, dy: Double, precise: Bool) {
        input?.scrollWheel(dx: dx, dy: dy, precise: precise)
    }

    // MARK: Hooks of the stream menu (`StreamTouchModes`)

    /// Whether the Mouse page offers the mode. DELOS for Android forces the trackpad for its remote-input stream; Apple
    /// streams have none, so the choice is always offered.
    var allowsTouchModeChange: Bool { true }

    /// The Mouse page's Touchscreen mode choices in the order of the setting: the `mouse_mode_list` value, the name
    /// (`mouse_mode_names`) and the help of each (`help_mouse_mode_list_N`).
    var touchModeOptionValues: [(value: Int, labelKey: String, helpKey: String)] {
        TouchMode.allCases.map { ($0.rawValue, $0.nameKey, "help_mouse_mode_list_\($0.rawValue)") }
    }

    /// The running mode's `mouse_mode_list` value.
    var selectedTouchMode: Int { touchMode.rawValue }

    /// Whether a mode chosen in the menu is saved (the Mouse page's help: `stream_menu_mouse_applies_saved` or `_stream`).
    var rememberMouseMode: Bool { touchOptions.rememberMode }

    /// The Mouse page's choice (`setStreamMouseMode`): applies at once, and is saved when the profile remembers it.
    func setTouchMode(_ value: Int) {
        guard let touchScreen, let mode = TouchMode(rawValue: value) else { return }
        touchScreen.setMode(mode)
        touchMode = touchScreen.mode
        zoomOn = touchScreen.zoomMode
    }

    /// The More page's Zoom (`toggleZoomMode`): the fingers pan and zoom the picture; a notice says which.
    func toggleZoom() {
        guard let touchScreen else { return }
        zoomOn = touchScreen.toggleZoomMode()
        zoomNotice?(zoomOn)
    }

    /// The More page's Touch sensitivity (`switchTouchSensitivity`), for this stream.
    func toggleTouchSensitivity() {
        guard let touchScreen else { return }
        touchScreen.toggleTouchSensitivity()
        touchSensitivityOn = touchScreen.touchSensitivityOn
    }

}

/// What the multi-finger taps open (`StreamPointerHandler.Host`): three fingers the system keyboard, four the full keyboard
/// through ``StreamController/fullKeyboardToggle``, five the stream menu.
@MainActor final class StreamTouchHost: TouchScreenHost {
    weak var controller: StreamController?

    init(_ controller: StreamController) { self.controller = controller }

    func toggleKeyboard() { controller?.toggleSystemKeyboard() }
    func toggleFullKeyboard() { controller?.fullKeyboardToggle?() }
    func showMenu() { controller?.openMenu() }
}
