import DelosCore
import Foundation

// The touch contexts of DELOS for Android (binding/input/touch): one per finger of the first two, each turning its
// finger into the PC's mouse in the way of the touch mode. Coordinates are whole pixels of the picture, times
// milliseconds, as on Android.

/// Work a touch context runs later (Android's `Handler.postDelayed`).
@MainActor public protocol TouchScheduler: AnyObject {
    func schedule(after milliseconds: Int, _ work: @escaping @MainActor () -> Void) -> any TouchScheduled
}

/// Work a ``TouchScheduler`` will run, until it is cancelled.
@MainActor public protocol TouchScheduled: AnyObject {
    func cancel()
}

/// The scheduler of a running stream: a task that sleeps.
@MainActor public final class TaskTouchScheduler: TouchScheduler {
    public init() {}

    private final class Scheduled: TouchScheduled {
        var task: Task<Void, Never>?
        func cancel() { task?.cancel() }
    }

    public func schedule(after milliseconds: Int, _ work: @escaping @MainActor () -> Void) -> any TouchScheduled {
        let scheduled = Scheduled()
        scheduled.task = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }
            work()
        }
        return scheduled
    }
}

/// The pending work of one context by its name: posting a name again replaces it (the contexts always remove a runnable
/// before they post it again), ``cancelAll()`` is `removeCallbacksAndMessages(null)`.
@MainActor final class TouchTimers<Key: Hashable> {
    private let scheduler: any TouchScheduler
    private var pending: [Key: any TouchScheduled] = [:]

    init(_ scheduler: any TouchScheduler) { self.scheduler = scheduler }

    func post(_ key: Key, after milliseconds: Int = 0, _ work: @escaping @MainActor () -> Void) {
        pending.removeValue(forKey: key)?.cancel()
        pending[key] = scheduler.schedule(after: milliseconds) { [weak self] in
            self?.pending[key] = nil
            work()
        }
    }

    func cancel(_ key: Key) { pending.removeValue(forKey: key)?.cancel() }

    func cancelAll() {
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
    }
}

/// The size of the picture in pixels (Android's stream view), which absolute positions are relative to.
public struct TouchViewSize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// One finger's context (`TouchContext`).
@MainActor public protocol TouchContext: AnyObject {
    /// Which finger of the gesture it follows: 0 the first, 1 the second.
    var actionIndex: Int { get }
    func setPointerCount(_ pointerCount: Int)
    func touchDown(x: Int, y: Int, time: Int64, isNewFinger: Bool)
    func touchMove(x: Int, y: Int, time: Int64)
    func touchUp(x: Int, y: Int, time: Int64)
    func cancelTouch()
    var isCancelled: Bool { get }
}

private func distanceExceeds(_ dx: Int, _ dy: Int, _ limit: Double) -> Bool {
    (Double(dx * dx) + Double(dy * dy)).squareRoot() > limit
}

private func press(_ sink: any StreamInputSink, _ button: MouseButton, _ pressed: Bool) {
    try? sink.sendMouseButton(button, pressed: pressed)
}

// MARK: - Absolute (the mouse modes)

/// The finger is the pointer where it touches (`AbsoluteTouchContext`, the Mouse and Mouse with swapped buttons modes):
/// a tap clicks the primary button there, a hold of 650 ms the secondary one, a move drags; the second finger scrolls.
@MainActor public final class AbsoluteTouchContext: TouchContext {
    static let scrollSpeedFactor = 3
    static let longPressTime = 650
    static let longPressDistance = 30.0
    static let doubleTapTime: Int64 = 250
    static let doubleTapDistance = 60.0
    static let touchDownDeadZoneTime = 100
    static let touchDownDeadZoneDistance = 20.0

    private enum Timer { case longPress, tapDown, buttonUp }

    public let actionIndex: Int
    private let sink: any StreamInputSink
    private let view: @MainActor () -> TouchViewSize
    private let timers: TouchTimers<Timer>
    private let buttonPrimary: MouseButton
    private let buttonSecondary: MouseButton

    private var lastTouchDownX = 0, lastTouchDownY = 0
    private var lastTouchDownTime: Int64 = 0
    private var lastTouchUpX = 0, lastTouchUpY = 0
    private var lastTouchUpTime: Int64 = 0
    private var lastTouchLocationX = 0, lastTouchLocationY = 0
    public private(set) var isCancelled = false
    private var confirmedLongPress = false
    private var confirmedTap = false

    public init(
        sink: any StreamInputSink, actionIndex: Int, view: @escaping @MainActor () -> TouchViewSize, swapped: Bool,
        scheduler: any TouchScheduler
    ) {
        self.sink = sink
        self.actionIndex = actionIndex
        self.view = view
        timers = TouchTimers(scheduler)
        buttonPrimary = swapped ? .right : .left
        buttonSecondary = swapped ? .left : .right
    }

    public func touchDown(x: Int, y: Int, time: Int64, isNewFinger: Bool) {
        // Finger transitions are not handled in absolute mode
        guard isNewFinger else { return }
        lastTouchLocationX = x
        lastTouchDownX = x
        lastTouchLocationY = y
        lastTouchDownY = y
        lastTouchDownTime = time
        isCancelled = false
        confirmedTap = false
        confirmedLongPress = false
        if actionIndex == 0 {
            timers.post(.tapDown, after: Self.touchDownDeadZoneTime) { [weak self] in self?.tapConfirmed() }
            timers.post(.longPress, after: Self.longPressTime) { [weak self] in self?.longPressed() }
        }
    }

    private func longPressed() {
        timers.cancel(.tapDown)
        // A long press turns the left click into a right click
        confirmedLongPress = true
        if confirmedTap { press(sink, buttonPrimary, false) }
        press(sink, buttonSecondary, true)
    }

    private func updatePosition(_ x: Int, _ y: Int) {
        let size = view()
        let x = min(max(x, 0), size.width), y = min(max(y, 0), size.height)
        try? sink.sendMousePosition(
            x: Int16(clamping: x), y: Int16(clamping: y), referenceWidth: Int16(clamping: size.width),
            referenceHeight: Int16(clamping: size.height))
    }

    public func touchUp(x: Int, y: Int, time: Int64) {
        guard !isCancelled else { return }
        if actionIndex == 0 {
            timers.cancel(.longPress)
            timers.cancel(.tapDown)
            if confirmedLongPress {
                press(sink, buttonSecondary, false)
            } else if confirmedTap {
                press(sink, buttonPrimary, false)
            } else {
                // The tap ended within the dead zone time: down and up at the original position now, the up 100 ms
                // later for games that poll the buttons
                tapConfirmed()
                let button = buttonPrimary
                timers.post(.buttonUp, after: 100) { [sink] in press(sink, button, false) }
            }
        }
        lastTouchLocationX = x
        lastTouchUpX = x
        lastTouchLocationY = y
        lastTouchUpY = y
        lastTouchUpTime = time
    }

    private func tapConfirmed() {
        guard !confirmedTap, !confirmedLongPress else { return }
        confirmedTap = true
        timers.cancel(.tapDown)
        // A finger down near the last tap, soon after it, does not move the pointer: double clicks are easier
        if lastTouchDownTime - lastTouchUpTime > Self.doubleTapTime
            || distanceExceeds(lastTouchDownX - lastTouchUpX, lastTouchDownY - lastTouchUpY, Self.doubleTapDistance)
        {
            updatePosition(lastTouchDownX, lastTouchDownY)
        }
        press(sink, buttonPrimary, true)
    }

    public func touchMove(x: Int, y: Int, time: Int64) {
        guard !isCancelled else { return }
        if actionIndex == 0 {
            if distanceExceeds(x - lastTouchDownX, y - lastTouchDownY, Self.longPressDistance) {
                timers.cancel(.longPress)
            }
            // Motion within the dead zone right after the touch down is ignored
            if confirmedTap || distanceExceeds(x - lastTouchDownX, y - lastTouchDownY, Self.touchDownDeadZoneDistance) {
                tapConfirmed()
                updatePosition(x, y)
            }
        } else if actionIndex == 1 {
            let amount = (y - lastTouchLocationY) * Self.scrollSpeedFactor
            if amount != 0 { try? sink.sendHighResolutionScroll(amount: Int16(clamping: amount)) }
        }
        lastTouchLocationX = x
        lastTouchLocationY = y
    }

    public func cancelTouch() {
        isCancelled = true
        timers.cancel(.longPress)
        timers.cancel(.tapDown)
        if confirmedLongPress {
            press(sink, buttonSecondary, false)
        } else if confirmedTap {
            press(sink, buttonPrimary, false)
        }
    }

    public func setPointerCount(_ pointerCount: Int) {
        if actionIndex == 0, pointerCount > 1 { cancelTouch() }
    }
}

// MARK: - Relative (Trackpad gaming)

/// The finger moves the pointer by its motion scaled to a 1280 × 720 reference (`RelativeTouchContext`, the Trackpad
/// gaming mode): a tap clicks (left, the second finger's right), a hold of 650 ms drags, two fingers scroll.
@MainActor public final class RelativeTouchContext: TouchContext {
    static let tapMovement = 20
    static let tapDistance = 25.0
    static let tapTime: Int64 = 250
    static let dragTime = 650
    static let scrollSpeedFactor = 5

    private enum Timer: Hashable { case drag, buttonUp(MouseButton) }

    public let actionIndex: Int
    private let sink: any StreamInputSink
    private let referenceWidth: Int
    private let referenceHeight: Int
    private let view: @MainActor () -> TouchViewSize
    private let absoluteMouseMode: Bool
    private let sensitivityX: Int
    private let sensitivityY: Int
    private let timers: TouchTimers<Timer>

    private var lastTouchX = 0, lastTouchY = 0
    private var originalTouchX = 0, originalTouchY = 0
    private var originalTouchTime: Int64 = 0
    public private(set) var isCancelled = false
    private var confirmedMove = false
    private var confirmedDrag = false
    private var confirmedScroll = false
    private var distanceMoved = 0.0
    private var xFactor = 0.0, yFactor = 0.0
    private var pointerCount = 0
    private var maxPointerCountInGesture = 0

    /// `sensitivityX`/`Y`: percent (`seekbar_touchpad_sensitivity_opacity`, `_y_opacity`).
    public init(
        sink: any StreamInputSink, actionIndex: Int, referenceWidth: Int, referenceHeight: Int,
        view: @escaping @MainActor () -> TouchViewSize, absoluteMouseMode: Bool, sensitivityX: Int, sensitivityY: Int,
        scheduler: any TouchScheduler
    ) {
        self.sink = sink
        self.actionIndex = actionIndex
        self.referenceWidth = referenceWidth
        self.referenceHeight = referenceHeight
        self.view = view
        self.absoluteMouseMode = absoluteMouseMode
        self.sensitivityX = sensitivityX
        self.sensitivityY = sensitivityY
        timers = TouchTimers(scheduler)
    }

    private func isWithinTapBounds(_ x: Int, _ y: Int) -> Bool {
        abs(x - originalTouchX) <= Self.tapMovement && abs(y - originalTouchY) <= Self.tapMovement
    }

    private func isTap(_ time: Int64) -> Bool {
        if confirmedDrag || confirmedMove || confirmedScroll { return false }
        // Only the last finger down reports the tap of a multi-finger tap
        if actionIndex + 1 != maxPointerCountInGesture { return false }
        return isWithinTapBounds(lastTouchX, lastTouchY) && time - originalTouchTime <= Self.tapTime
    }

    private var mouseButton: MouseButton { actionIndex == 1 ? .right : .left }

    public func touchDown(x: Int, y: Int, time: Int64, isNewFinger: Bool) {
        let size = view()
        xFactor = Double(referenceWidth) / Double(max(size.width, 1))
        yFactor = Double(referenceHeight) / Double(max(size.height, 1))
        originalTouchX = x
        lastTouchX = x
        originalTouchY = y
        lastTouchY = y
        if isNewFinger {
            maxPointerCountInGesture = pointerCount
            originalTouchTime = time
            isCancelled = false
            confirmedDrag = false
            confirmedMove = false
            confirmedScroll = false
            distanceMoved = 0
            if actionIndex == 0 {
                timers.post(.drag, after: Self.dragTime) { [weak self] in self?.dragTimerFired() }
            }
        }
    }

    private func dragTimerFired() {
        guard !confirmedMove else { return }
        // Only the primary finger drags
        guard actionIndex == maxPointerCountInGesture - 1 else { return }
        confirmedDrag = true
        press(sink, mouseButton, true)
    }

    public func touchUp(x: Int, y: Int, time: Int64) {
        guard !isCancelled else { return }
        timers.cancel(.drag)
        let button = mouseButton
        if confirmedDrag {
            press(sink, button, false)
        } else if isTap(time) {
            press(sink, button, true)
            // Up 100 ms later for games that poll the buttons
            timers.post(.buttonUp(button), after: 100) { [sink] in press(sink, button, false) }
        }
    }

    private func checkForConfirmedMove(_ x: Int, _ y: Int) {
        if confirmedMove || confirmedDrag { return }
        // Leaving the tap bounds before the drag time is a move
        if !isWithinTapBounds(x, y) {
            confirmedMove = true
            timers.cancel(.drag)
            return
        }
        distanceMoved += (Double((x - lastTouchX) * (x - lastTouchX)) + Double((y - lastTouchY) * (y - lastTouchY))).squareRoot()
        if distanceMoved >= Self.tapDistance {
            confirmedMove = true
            timers.cancel(.drag)
        }
    }

    public func touchMove(x: Int, y: Int, time: Int64) {
        guard !isCancelled, x != lastTouchX || y != lastTouchY else { return }
        checkForConfirmedMove(x, y)
        // Two fingers on the screen that left the tap zone scroll
        confirmedScroll = actionIndex == 0 && pointerCount == 2 && confirmedMove
        guard actionIndex == 0 else {
            lastTouchX = x
            lastTouchY = y
            return
        }
        var deltaX = Int((Double(abs(x - lastTouchX)) * xFactor + 0.5).rounded(.down))
        var deltaY = Int((Double(abs(y - lastTouchY)) * yFactor + 0.5).rounded(.down))
        if x < lastTouchX { deltaX = -deltaX }
        if y < lastTouchY { deltaY = -deltaY }
        if pointerCount == 2 {
            if confirmedScroll, deltaY != 0 {
                try? sink.sendHighResolutionScroll(amount: Int16(clamping: deltaY * Self.scrollSpeedFactor))
            }
        } else if absoluteMouseMode {
            let size = view()
            try? sink.sendMouseMoveAsMousePosition(
                deltaX: Int16(clamping: deltaX), deltaY: Int16(clamping: deltaY), referenceWidth: Int16(clamping: size.width),
                referenceHeight: Int16(clamping: size.height))
        } else {
            let dx = Int16(clamping: Int((Double(deltaX) * Double(sensitivityX) * 0.01).rounded(.towardZero)))
            let dy = Int16(clamping: Int((Double(deltaY) * Double(sensitivityY) * 0.01).rounded(.towardZero)))
            try? sink.sendMouseMove(deltaX: dx, deltaY: dy)
        }
        // Deltas the scaling rounded to zero wait until they are not, so frequent small reports still move
        if deltaX != 0 { lastTouchX = x }
        if deltaY != 0 { lastTouchY = y }
    }

    public func cancelTouch() {
        isCancelled = true
        timers.cancel(.drag)
        if confirmedDrag { press(sink, mouseButton, false) }
    }

    public func setPointerCount(_ pointerCount: Int) {
        self.pointerCount = pointerCount
        maxPointerCountInGesture = max(maxPointerCountInGesture, pointerCount)
    }
}

// MARK: - Trackpad (Trackpad natural)

/// The screen is a laptop's trackpad (`TrackpadContext`, the Trackpad natural mode): the finger moves the pointer with
/// acceleration and a flick glides on, a tap clicks (two fingers right, three middle), a double tap held drags, two
/// fingers scroll both ways with momentum.
@MainActor public final class TrackpadContext: TouchContext {
    static let tapMovement = 30
    static let tapTime: Int64 = 230
    static let clickReleaseDelay = Int(tapTime)
    static let scrollSpeedFactorX = 2.0
    static let scrollSpeedFactorY = 3.0
    static let accelerationThreshold = 8.0
    static let flickFriction = 0.93
    /// Pixels per millisecond.
    static let flickThreshold = 0.8
    static let momentumFrameInterval = 10
    static let flickVelocityDecayTimeout = 50.0
    static let scrollTransitionTimeout = 200

    private enum Timer { case scrollTransition, momentum, scrollMomentum, clickRelease }

    public let actionIndex: Int
    private let sink: any StreamInputSink
    private let timers: TouchTimers<Timer>
    private let swapAxis: Bool
    private let sensitivityX: Double
    private let sensitivityY: Double

    private var pendingDeltaX = 0.0, pendingDeltaY = 0.0
    private var lastTouchX = 0, lastTouchY = 0
    private var originalTouchX = 0, originalTouchY = 0
    private var originalTouchTime: Int64 = 0
    public private(set) var isCancelled = false
    private var confirmedMove = false
    private var confirmedDrag = false
    private var confirmedScroll = false
    private var distanceMoved = 0.0
    private var pointerCount = 0
    private var clickedMiddle = false
    private var maxPointerCountInGesture = 0
    private var isClickPending = false
    private var isDblClickPending = false
    private var isFlicking = false
    private var velocityX = 0.0, velocityY = 0.0
    private var lastMoveTime: Int64 = 0
    private var isScrollTransitioning = false

    /// `sensitivityX`/`Y` in percent (−200…200); the touch screen's own contexts use 100 and no swap.
    public init(
        sink: any StreamInputSink, actionIndex: Int, swapAxis: Bool = false, sensitivityX: Int = 100, sensitivityY: Int = 100,
        scheduler: any TouchScheduler
    ) {
        self.sink = sink
        self.actionIndex = actionIndex
        self.swapAxis = swapAxis
        self.sensitivityX = Double(sensitivityX) / 100
        self.sensitivityY = Double(sensitivityY) / 100
        timers = TouchTimers(scheduler)
    }

    private var speed: Double { (velocityX * velocityX + velocityY * velocityY).squareRoot() }

    private func momentumFrame() {
        guard isFlicking else { return }
        pendingDeltaX += velocityX * Double(Self.momentumFrameInterval)
        pendingDeltaY += velocityY * Double(Self.momentumFrameInterval)
        let dx = Int16(clamping: Int(pendingDeltaX.rounded(.towardZero)))
        let dy = Int16(clamping: Int(pendingDeltaY.rounded(.towardZero)))
        if dx != 0 || dy != 0 {
            try? sink.sendMouseMove(deltaX: dx, deltaY: dy)
            pendingDeltaX -= Double(dx)
            pendingDeltaY -= Double(dy)
        }
        velocityX *= Self.flickFriction
        velocityY *= Self.flickFriction
        if speed * Double(Self.momentumFrameInterval) < 0.5 {
            isFlicking = false
            if confirmedDrag {
                press(sink, mouseButton, false)
                confirmedDrag = false
            }
        }
        if isFlicking { timers.post(.momentum, after: Self.momentumFrameInterval) { [weak self] in self?.momentumFrame() } }
    }

    private func scrollMomentumFrame() {
        guard isFlicking else { return }
        let frameX = velocityX * Double(Self.momentumFrameInterval)
        let frameY = velocityY * Double(Self.momentumFrameInterval)
        scroll(x: frameX, y: frameY, absX: abs(frameX), absY: abs(frameY))
        velocityX *= Self.flickFriction
        velocityY *= Self.flickFriction
        if speed * Double(Self.momentumFrameInterval) < 0.5 { isFlicking = false }
        if isFlicking {
            timers.post(.scrollMomentum, after: Self.momentumFrameInterval) { [weak self] in self?.scrollMomentumFrame() }
        }
    }

    /// Both ways along the main axis; across it too when nearly as much.
    private func scroll(x: Double, y: Double, absX: Double, absY: Double) {
        let horizontal = { [sink] in
            try? sink.sendHighResolutionHorizontalScroll(amount: Int16(clamping: Int((-x * Self.scrollSpeedFactorX).rounded(.towardZero))))
        }
        let vertical = { [sink] in
            try? sink.sendHighResolutionScroll(amount: Int16(clamping: Int((y * Self.scrollSpeedFactorY).rounded(.towardZero))))
        }
        if absX > absY {
            horizontal()
            if absY * 1.05 > absX { vertical() }
        } else {
            vertical()
            if absX * 1.05 >= absY { horizontal() }
        }
    }

    private func isWithinTapBounds(_ x: Int, _ y: Int) -> Bool {
        abs(x - originalTouchX) <= Self.tapMovement && abs(y - originalTouchY) <= Self.tapMovement
    }

    private func isTap(_ time: Int64) -> Bool {
        if confirmedDrag || confirmedMove || confirmedScroll { return false }
        if actionIndex + 1 != maxPointerCountInGesture { return false }
        return isWithinTapBounds(lastTouchX, lastTouchY) && time - originalTouchTime <= Self.tapTime
    }

    private var mouseButton: MouseButton {
        switch pointerCount {
        case 2: return .right
        case 3:
            clickedMiddle = true
            return .middle
        default: return .left
        }
    }

    public func touchDown(x: Int, y: Int, time: Int64, isNewFinger: Bool) {
        if isFlicking {
            isFlicking = false
            timers.cancelAll()
        }
        if isNewFinger {
            // A new gesture: a pending change from scrolling back to moving is over
            clickedMiddle = false
            timers.cancel(.scrollTransition)
            isScrollTransitioning = false
            maxPointerCountInGesture = pointerCount
            originalTouchTime = time
            isCancelled = false
            confirmedMove = false
            confirmedScroll = false
            distanceMoved = 0
            velocityX = 0
            velocityY = 0
            lastMoveTime = time
            if isClickPending {
                isClickPending = false
                isDblClickPending = true
                confirmedDrag = true
            }
        } else if pointerCount == 2, !confirmedMove {
            press(sink, .middle, true)
            press(sink, .middle, false)
            isClickPending = false
            isDblClickPending = false
            confirmedDrag = false
            clickedMiddle = true
        } else if pointerCount == 1, !confirmedMove, !clickedMiddle {
            // The second finger went up: a right click at once
            press(sink, .right, true)
            press(sink, .right, false)
            isClickPending = false
            isDblClickPending = false
            confirmedDrag = false
        }
        originalTouchX = x
        lastTouchX = x
        originalTouchY = y
        lastTouchY = y
        pendingDeltaX = 0
        pendingDeltaY = 0
    }

    public func touchUp(x: Int, y: Int, time: Int64) {
        guard !isCancelled else { return }
        // A pause before lifting the finger is no flick
        let sinceLastMove = time - lastMoveTime
        if sinceLastMove > 0 {
            let decay = max(0, 1 - Double(sinceLastMove) / Self.flickVelocityDecayTimeout)
            velocityX *= decay
            velocityY *= decay
        }
        let button = mouseButton
        if isDblClickPending {
            timers.cancelAll()
            press(sink, button, false)
            press(sink, button, true)
            press(sink, button, false)
            isClickPending = false
            confirmedDrag = false
        } else if confirmedDrag {
            timers.cancelAll()
            if speed > Self.flickThreshold {
                isFlicking = true
                timers.post(.momentum) { [weak self] in self?.momentumFrame() }
            } else {
                press(sink, button, false)
                confirmedDrag = false
            }
        } else if isTap(time) {
            press(sink, button, true)
            isClickPending = true
            timers.cancelAll()
            timers.post(.clickRelease, after: Self.clickReleaseDelay) { [weak self] in
                guard let self else { return }
                if self.isClickPending {
                    press(self.sink, button, false)
                    self.isClickPending = false
                }
                self.isDblClickPending = false
            }
        } else if confirmedMove, speed > Self.flickThreshold {
            // A move or scroll that was no drag or tap flicks
            if confirmedScroll {
                isFlicking = true
                timers.post(.scrollMomentum) { [weak self] in self?.scrollMomentumFrame() }
            } else if maxPointerCountInGesture == 1 {
                // Only a one-finger move glides on
                isFlicking = true
                timers.post(.momentum) { [weak self] in self?.momentumFrame() }
            }
        }
    }

    public func touchMove(x: Int, y: Int, time: Int64) {
        guard !isCancelled, x != lastTouchX || y != lastTouchY else { return }
        let deltaTime = time - lastMoveTime
        checkForConfirmedMove(x, y)
        if isDblClickPending {
            isDblClickPending = false
            confirmedDrag = true
        }
        let rawDeltaX = x - lastTouchX, rawDeltaY = y - lastTouchY
        let magnitude = (Double(rawDeltaX * rawDeltaX) + Double(rawDeltaY * rawDeltaY)).squareRoot()
        let precision = Foundation.cbrt(magnitude / Self.accelerationThreshold)
        var deltaX = Double(swapAxis ? rawDeltaY : rawDeltaX)
        var deltaY = Double(swapAxis ? rawDeltaX : rawDeltaY)
        let absDeltaX = abs(swapAxis ? rawDeltaY : rawDeltaX)
        let absDeltaY = abs(swapAxis ? rawDeltaX : rawDeltaY)
        deltaX = Double(Float(deltaX * precision) * Float(sensitivityX))
        deltaY = Double(Float(deltaY * precision) * Float(sensitivityY))
        // The velocity of a flick, smoothed
        if deltaTime > 0, confirmedMove || confirmedDrag {
            let currentX = deltaX / Double(deltaTime), currentY = deltaY / Double(deltaTime)
            if velocityX == 0, velocityY == 0 {
                velocityX = currentX
                velocityY = currentY
            } else {
                velocityX = velocityX * 0.8 + currentX * 0.2
                velocityY = velocityY * 0.8 + currentY * 0.2
            }
        }
        lastMoveTime = time
        pendingDeltaX += deltaX
        pendingDeltaY += deltaY
        lastTouchX = x
        lastTouchY = y
        let sendX = Int16(clamping: Int(pendingDeltaX.rounded(.towardZero)))
        let sendY = Int16(clamping: Int(pendingDeltaY.rounded(.towardZero)))
        if pointerCount == 1 {
            // No motion right after a scroll
            if !isScrollTransitioning, sendX != 0 || sendY != 0 { try? sink.sendMouseMove(deltaX: sendX, deltaY: sendY) }
        } else if actionIndex == 1 {
            if confirmedDrag {
                if sendX != 0 || sendY != 0 { try? sink.sendMouseMove(deltaX: sendX, deltaY: sendY) }
            } else if pointerCount == 2 {
                confirmedScroll = actionIndex == 1 && pointerCount == 2 && confirmedMove
                if confirmedScroll {
                    scroll(x: Double(sendX), y: Double(sendY), absX: Double(absDeltaX), absY: Double(absDeltaY))
                }
            }
        }
        pendingDeltaX -= Double(sendX)
        pendingDeltaY -= Double(sendY)
    }

    public func cancelTouch() {
        isCancelled = true
        if isFlicking {
            isFlicking = false
            timers.cancelAll()
        }
        if confirmedDrag { press(sink, mouseButton, false) }
    }

    public func setPointerCount(_ pointerCount: Int) {
        if self.pointerCount == 2, pointerCount == 1 {
            // A two-finger scroll just ended: the finger left behind does not move the pointer for a moment
            isScrollTransitioning = true
            timers.post(.scrollTransition, after: Self.scrollTransitionTimeout) { [weak self] in self?.isScrollTransitioning = false }
        } else if self.pointerCount == 1, pointerCount == 2 {
            timers.cancel(.scrollTransition)
            isScrollTransitioning = false
        }
        if pointerCount < self.pointerCount, confirmedDrag, !isFlicking {
            press(sink, mouseButton, false)
            confirmedDrag = false
            confirmedMove = false
            confirmedScroll = false
            isClickPending = false
            isDblClickPending = false
        }
        self.pointerCount = pointerCount
        maxPointerCountInGesture = max(maxPointerCountInGesture, pointerCount)
    }

    private func checkForConfirmedMove(_ x: Int, _ y: Int) {
        if confirmedMove || confirmedDrag { return }
        if !isWithinTapBounds(x, y) {
            confirmedMove = true
            return
        }
        distanceMoved += (Double((x - lastTouchX) * (x - lastTouchX)) + Double((y - lastTouchY) * (y - lastTouchY))).squareRoot()
        if distanceMoved >= Double(Self.tapMovement) { confirmedMove = true }
    }
}
