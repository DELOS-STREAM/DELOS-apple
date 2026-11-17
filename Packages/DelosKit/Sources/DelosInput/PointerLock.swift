import CoreGraphics

/// What locking the pointer does on a platform (the Mac: ``AppKitPointerBackend``; tests: a fake).
@MainActor
public protocol PointerLockBackend: AnyObject {
    /// Hides the pointer and detaches it from the mouse, so the mouse's motion only reaches the stream.
    func lock()
    /// Shows the pointer again and attaches it to the mouse.
    func unlock()
}

/// Decides when the system pointer is locked to a stream: while a stream wants the mouse (it runs, and neither its menu,
/// the loader nor the result overlay is shown) and the app can have it (the Mac: it is the active app and the video's
/// window is the key window; iPad: the scene is in the foreground and active). Any other time the pointer is free, so the
/// menu, another app and the window's buttons can be clicked. iPadOS may refuse the lock (a window that is not full
/// screen: Slide Over, Stage Manager); then the pointer is hidden over the video by its style instead (``hidesPointer``).
@MainActor
public final class PointerLock {
    private let backend: any PointerLockBackend
    /// A stream wants the mouse.
    public private(set) var wanted = false
    /// The app can have the pointer: active, and the video's window is the key one.
    public private(set) var eligible = false
    /// The pointer is locked now (asked for, on iPad).
    public private(set) var isLocked = false
    /// The system holds the lock (iPadOS: the scene's `pointerLockState`; the Mac's lock is not refused).
    public private(set) var granted = false

    /// The pointer has to be hidden over the video by its style: the lock is asked for and the system has not granted it.
    public var hidesPointer: Bool { isLocked && !granted }

    public init(backend: any PointerLockBackend) {
        self.backend = backend
    }

    public func setWanted(_ value: Bool) {
        wanted = value
        apply()
    }

    public func setEligible(_ value: Bool) {
        eligible = value
        apply()
    }

    /// The system granted the lock, or took it back.
    public func setGranted(_ value: Bool) {
        granted = value
    }

    /// The stream is over or its view is gone: nothing wants the mouse any more.
    public func release() {
        wanted = false
        apply()
    }

    private func apply() {
        let should = wanted && eligible
        guard should != isLocked else { return }
        isLocked = should
        if should { backend.lock() } else { backend.unlock() }
    }
}

/// Where the pointer is parked when it is locked: the middle of the video, so a click that still reaches the app lands
/// on the video and not on the title bar or another window.
public enum PointerLockGeometry {
    /// Cocoa's global coordinates (origin at the bottom left of the main screen) as Core Graphics' (origin at the top
    /// left of the main screen), which the cursor functions take.
    public static func displayPoint(fromCocoa point: CGPoint, mainScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainScreenHeight - point.y)
    }

    /// The middle of `frame` (Cocoa coordinates) in Core Graphics' display coordinates.
    public static func parkingPoint(windowFrame frame: CGRect, mainScreenHeight: CGFloat) -> CGPoint {
        displayPoint(fromCocoa: CGPoint(x: frame.midX, y: frame.midY), mainScreenHeight: mainScreenHeight)
    }
}

#if os(macOS)
import AppKit

/// Locks the Mac's pointer the way games do: warps it to `anchor`, detaches it from the mouse
/// (`CGAssociateMouseAndMouseCursorPosition`) and hides it. The mouse's relative motion still reaches `GCMouse`, which
/// ``GameInput`` sends to the PC. The calls are balanced: the pointer is hidden and shown once each.
@MainActor
public final class AppKitPointerBackend: PointerLockBackend {
    private var hidden = false
    private let anchor: @MainActor () -> CGPoint?

    /// - Parameter anchor: where to park the pointer in Core Graphics' display coordinates, nil to leave it.
    public init(anchor: @escaping @MainActor () -> CGPoint?) {
        self.anchor = anchor
    }

    public func lock() {
        if let point = anchor() { CGWarpMouseCursorPosition(point) }
        CGAssociateMouseAndMouseCursorPosition(0)
        if !hidden {
            NSCursor.hide()
            hidden = true
        }
    }

    public func unlock() {
        CGAssociateMouseAndMouseCursorPosition(1)
        if hidden {
            NSCursor.unhide()
            hidden = false
        }
    }
}
#endif
