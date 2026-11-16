import AVFoundation
import SwiftUI

/// The video of a stream: hosts the renderer's `AVSampleBufferDisplayLayer` full size, aspect fit on black. Reports
/// the display it is shown on (once it is in a window) and, on iPhone and iPad, the touches on it in pixels.
struct VideoSurface {
    let layer: AVSampleBufferDisplayLayer
    let onDisplay: @MainActor (DisplayInfo) -> Void
    var onTouch: @MainActor (_ id: Int, _ phase: StreamController.TouchPhase, _ point: CGPoint, _ height: CGFloat, _ time: TimeInterval) -> Void = { _, _, _, _, _ in }
    /// Whether a touch of the system pointer (a mouse or trackpad) is ignored: the mouse's own input already moves the
    /// PC's pointer.
    var ignoresPointer: @MainActor () -> Bool = { false }
}

#if canImport(UIKit)
import UIKit

extension VideoSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> VideoHostView {
        let view = VideoHostView(video: layer)
        update(view)
        return view
    }

    func updateUIView(_ view: VideoHostView, context: Context) {
        update(view)
    }

    @MainActor private func update(_ view: VideoHostView) {
        view.onDisplay = onDisplay
        view.onTouch = onTouch
        view.ignoresPointer = ignoresPointer
    }
}

/// The thin UIKit host of the video layer (the one UIKit view of the app, docs/ENGINEERING_RULES.md).
final class VideoHostView: UIView {
    private let video: AVSampleBufferDisplayLayer
    var onDisplay: @MainActor (DisplayInfo) -> Void = { _ in }
    var onTouch: @MainActor (Int, StreamController.TouchPhase, CGPoint, CGFloat, TimeInterval) -> Void = { _, _, _, _, _ in }
    var ignoresPointer: @MainActor () -> Bool = { false }

    init(video: AVSampleBufferDisplayLayer) {
        self.video = video
        super.init(frame: .zero)
        backgroundColor = .black
        #if os(iOS)
        isMultipleTouchEnabled = true
        #endif
        video.videoGravity = .resizeAspect
        layer.addSublayer(video)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let screen = window?.windowScene?.screen else { return }
        let size = screen.nativeBounds.size
        let info = DisplayInfo(pixelWidth: Int(size.width), pixelHeight: Int(size.height), maxFramesPerSecond: screen.maximumFramesPerSecond)
        // Not inside the view update that added this view
        Task { @MainActor [onDisplay] in onDisplay(info) }
    }

    // MARK: Touches, in pixels of the screen

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .began) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .moved) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .ended) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .cancelled) }

    private func report(_ touches: Set<UITouch>, _ phase: StreamController.TouchPhase) {
        let scale = window?.windowScene?.screen.nativeScale ?? contentScaleFactor
        for touch in touches {
            if touch.type == .indirectPointer, ignoresPointer() { continue }
            let point = touch.location(in: self)
            onTouch(
                ObjectIdentifier(touch).hashValue, phase, CGPoint(x: point.x * scale, y: point.y * scale),
                bounds.height * scale, touch.timestamp)
        }
    }
}
#elseif canImport(AppKit)
import AppKit

extension VideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> VideoHostView {
        let view = VideoHostView(video: layer)
        view.onDisplay = onDisplay
        return view
    }

    func updateNSView(_ view: VideoHostView, context: Context) {
        view.onDisplay = onDisplay
    }
}

/// The AppKit host of the video layer on the Mac.
final class VideoHostView: NSView {
    private let video: AVSampleBufferDisplayLayer
    var onDisplay: @MainActor (DisplayInfo) -> Void = { _ in }

    init(video: AVSampleBufferDisplayLayer) {
        self.video = video
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        video.videoGravity = .resizeAspect
        layer?.addSublayer(video)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let screen = window?.screen else { return }
        let size = screen.convertRectToBacking(screen.frame).size
        let info = DisplayInfo(pixelWidth: Int(size.width), pixelHeight: Int(size.height), maxFramesPerSecond: screen.maximumFramesPerSecond)
        Task { @MainActor [onDisplay] in onDisplay(info) }
    }
}
#endif
