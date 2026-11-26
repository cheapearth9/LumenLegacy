import UIKit

/// Where the engine sends its results. Implemented by the stream view controller.
protocol TouchEngineDelegate: AnyObject {
    /// A finished input event for the host.
    func engineEmit(_ event: InputEvent)
    /// Relative cursor movement in host pixels (batched and sent by InputCapture).
    func engineMoveCursor(dx: Float, dy: Float)
    /// Maps a point in the touch view to 0...65535 over the video rectangle.
    func engineNormalise(_ point: CGPoint) -> (UInt16, UInt16)
    /// Host pixels per point of the touch view (host display width / displayed video width).
    func engineSourcePixelsPerPoint() -> CGFloat
}

/// Turns raw UIKit touches into Lumen input events. Main thread only.
///
///  - Touchpad: relative cursor with a mild acceleration curve, 1-finger tap = left click, 2-finger tap = right click,
///    2-finger drag = natural scroll, tap then touch down quickly and drag = left-button drag.
///  - Touchscreen + host with native touch: real multi-touch is forwarded; touches that begin together are buffered
///    briefly so a two-finger tap can become a right click instead of two touches.
///  - Touchscreen + host without native touch: emulation (tap = click, 1-finger drag = scroll,
///    long press then drag = left-button drag, 2-finger tap = right click).
final class TouchEngine {
    enum Mode: String { case touchpad, touchscreen }

    private enum Route { case pad, native, emulated }
    private enum NativePhase { case idle, buffering, candidate, passthrough }

    private struct Track {
        var slot: Int
        var start: CGPoint
        var location: CGPoint
        var lastTime: TimeInterval
        var speed: CGFloat = 0          // smoothed points / second
        var moved = false               // travelled further than `slop` from its start
    }

    // Tuning
    private static let slop: CGFloat = 10
    private static let tapMax: TimeInterval = 0.3
    private static let twoTapMax: TimeInterval = 0.4
    private static let tapDragWindow: TimeInterval = 0.3
    private static let bufferWindow: TimeInterval = 0.12
    private static let candidateWindow: TimeInterval = 0.25
    private static let longPress: TimeInterval = 0.35
    private static let lockedGain: CGFloat = 1.6

    weak var delegate: TouchEngineDelegate?

    var mode: Mode = .touchscreen { didSet { if mode != oldValue { cancelAll() } } }
    var hostHasNativeTouch = false { didSet { if hostHasNativeTouch != oldValue { cancelAll() } } }
    /// Game mode (pointer lock): touch behaves like a plain touchpad with a fixed gain.
    var pointerLocked = false { didSet { if pointerLocked != oldValue { cancelAll() } } }

    private var tracks: [ObjectIdentifier: Track] = [:]
    private var usedSlots = 0
    private var route: Route = .emulated

    // Per-gesture state (a gesture lasts from the first finger down to the last finger up)
    private var gestureStart: TimeInterval = 0
    private var gestureMax = 0
    private var gestureMoved = false
    private var gestureMid = CGPoint.zero
    private var scrolling = false
    private var scrollRemX: CGFloat = 0
    private var scrollRemY: CGFloat = 0
    private var buttonHeld = false
    private var lastTapEnd: TimeInterval = -100
    private var longPressWork: DispatchWorkItem?

    private var nativePhase = NativePhase.idle
    private var buffer = [InputEvent]()
    private var nativeWork: DispatchWorkItem?

    private static func isFinger(_ t: UITouch) -> Bool { t.type == .direct || t.type == .pencil }

    // MARK: Entry points (called by the touch view)

    func touchesBegan(_ touches: Set<UITouch>, in view: UIView) {
        for t in touches where TouchEngine.isFinger(t) {
            let key = ObjectIdentifier(t)
            if tracks[key] != nil { continue }
            guard let slot = allocSlot() else { continue }
            let p = t.location(in: view)
            if tracks.isEmpty { beginGesture(timestamp: t.timestamp) }
            tracks[key] = Track(slot: slot, start: p, location: p, lastTime: t.timestamp)
            gestureMax = max(gestureMax, tracks.count)
            if tracks.count == 2 {
                let pts = tracks.values.map { $0.location }
                gestureMid = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
            }
            switch route {
            case .pad: padDown()
            case .native: nativeDown(key)
            case .emulated: emuDown()
            }
        }
    }

    func touchesMoved(_ touches: Set<UITouch>, in view: UIView) {
        for t in touches where TouchEngine.isFinger(t) {
            let key = ObjectIdentifier(t)
            guard var tr = tracks[key] else { continue }
            let p = t.location(in: view)
            let prev = t.previousLocation(in: view)
            let dx = p.x - prev.x, dy = p.y - prev.y
            let dt = max(0.004, t.timestamp - tr.lastTime)
            tr.speed = tr.speed * 0.6 + (hypot(dx, dy) / CGFloat(dt)) * 0.4
            tr.lastTime = t.timestamp
            tr.location = p
            if !tr.moved && hypot(p.x - tr.start.x, p.y - tr.start.y) > TouchEngine.slop {
                tr.moved = true
                gestureMoved = true
            }
            tracks[key] = tr
            switch route {
            case .pad: padMove(tr, dx: dx, dy: dy)
            case .native: nativeMove(tr)
            case .emulated: emuMove(tr, dx: dx, dy: dy)
            }
        }
    }

    func touchesEnded(_ touches: Set<UITouch>, in view: UIView) { finish(touches, cancelled: false, in: view) }
    func touchesCancelled(_ touches: Set<UITouch>, in view: UIView) { finish(touches, cancelled: true, in: view) }

    /// Releases everything that is held and forgets all touches (mode change, view going away).
    func cancelAll() {
        cancelLongPress()
        nativeWork?.cancel(); nativeWork = nil
        if buttonHeld {
            buttonHeld = false
            delegate?.engineEmit(.button(0, down: false))
        }
        if route == .native && nativePhase == .passthrough {
            for tr in tracks.values { delegate?.engineEmit(touchEvent(tr, phase: 3)) }
        }
        tracks.removeAll()
        usedSlots = 0
        nativePhase = .idle
        buffer.removeAll(keepingCapacity: true)
    }

    // MARK: Common

    private func finish(_ touches: Set<UITouch>, cancelled: Bool, in view: UIView) {
        for t in touches where TouchEngine.isFinger(t) {
            let key = ObjectIdentifier(t)
            guard var tr = tracks[key] else { continue }
            tr.location = t.location(in: view)
            tracks[key] = tr
            let last = tracks.count == 1
            switch route {
            case .pad: padEnd(last: last, ts: t.timestamp, cancelled: cancelled)
            case .native: nativeEnd(tr, last: last, cancelled: cancelled)
            case .emulated: emuEnd(tr, last: last, ts: t.timestamp, cancelled: cancelled)
            }
            tracks[key] = nil
            usedSlots &= ~(1 << tr.slot)
            if tracks.isEmpty { endGesture() }
        }
    }

    private func allocSlot() -> Int? {
        for i in 0..<10 where usedSlots & (1 << i) == 0 {
            usedSlots |= (1 << i)
            return i
        }
        return nil
    }

    private func beginGesture(timestamp: TimeInterval) {
        if pointerLocked || mode == .touchpad { route = .pad }
        else { route = hostHasNativeTouch ? .native : .emulated }
        gestureStart = timestamp
        gestureMax = 0
        gestureMoved = false
        scrolling = false
        scrollRemX = 0; scrollRemY = 0
        nativePhase = .idle
        buffer.removeAll(keepingCapacity: true)
    }

    private func endGesture() {
        cancelLongPress()
        nativeWork?.cancel(); nativeWork = nil
        nativePhase = .idle
        buffer.removeAll(keepingCapacity: true)
        if buttonHeld {
            buttonHeld = false
            delegate?.engineEmit(.button(0, down: false))
        }
    }

    private func click(_ button: UInt8) {
        delegate?.engineEmit(.button(button, down: true))
        delegate?.engineEmit(.button(button, down: false))
    }

    private func sendAbs(_ p: CGPoint) {
        guard let d = delegate else { return }
        let (x, y) = d.engineNormalise(p)
        d.engineEmit(.mouseAbs(x: x, y: y))
    }

    private func scrollBy(_ dx: CGFloat, _ dy: CGFloat) {
        if !scrolling {
            guard gestureMoved else { return }
            scrolling = true
        }
        scrollRemX += dx; scrollRemY += dy
        let ix = scrollRemX.rounded(.towardZero), iy = scrollRemY.rounded(.towardZero)
        scrollRemX -= ix; scrollRemY -= iy
        if ix != 0 || iy != 0 {
            delegate?.engineEmit(.scroll(dx: TouchEngine.clamp16(ix), dy: TouchEngine.clamp16(iy)))
        }
    }

    private static func clamp16(_ v: CGFloat) -> Int16 { Int16(max(-32000, min(32000, v))) }

    private func releaseButton() {
        if buttonHeld {
            buttonHeld = false
            delegate?.engineEmit(.button(0, down: false))
        }
    }

    // MARK: Touchpad

    private func padDown() {
        if tracks.count == 1 {
            // Tap, then touch down again quickly: hold the left button while dragging.
            if gestureStart - lastTapEnd < TouchEngine.tapDragWindow {
                buttonHeld = true
                delegate?.engineEmit(.button(0, down: true))
            }
        } else {
            releaseButton()
        }
    }

    private func padMove(_ tr: Track, dx: CGFloat, dy: CGFloat) {
        if gestureMax >= 3 { return }                 // no 3-finger gestures
        let n = tracks.count
        if n == 1 && gestureMax == 1 {
            var gain = TouchEngine.lockedGain
            if !pointerLocked {
                let ppp = delegate?.engineSourcePixelsPerPoint() ?? 1
                let base = min(3, max(0.5, ppp * 0.6))
                let accel = 1 + min(1.2, tr.speed / 2200)
                gain = base * accel
            }
            delegate?.engineMoveCursor(dx: Float(dx * gain), dy: Float(dy * gain))
        } else if n == 2 && gestureMax == 2 {
            scrollBy(dx * 0.5, dy * 0.5)               // two fingers: the average of both is the scroll delta
        }
    }

    private func padEnd(last: Bool, ts: TimeInterval, cancelled: Bool) {
        guard last else { return }
        if buttonHeld {
            buttonHeld = false
            delegate?.engineEmit(.button(0, down: false))
            lastTapEnd = (gestureMoved || cancelled) ? -100 : ts
            return
        }
        guard !cancelled, !gestureMoved, !longPressDone else { return }
        let dur = ts - gestureStart
        if gestureMax == 1 && dur < TouchEngine.tapMax {
            click(0)
            lastTapEnd = ts
        } else if gestureMax == 2 && dur < TouchEngine.twoTapMax {
            click(1)
        }
    }

    // MARK: Touchscreen, emulated (host without native touch)

    private var longPressDone = false

    private func emuDown() {
        longPressDone = false
        if tracks.count == 1 {
            scheduleLongPress()
        } else {
            cancelLongPress()
            releaseButton()
        }
    }

    private func emuMove(_ tr: Track, dx: CGFloat, dy: CGFloat) {
        if buttonHeld {
            if tracks.count == 1 { sendAbs(tr.location) }
            return
        }
        if tr.moved { cancelLongPress() }
        if gestureMax >= 3 { return }
        let n = tracks.count
        if n == gestureMax {
            let f = 1 / CGFloat(n)
            scrollBy(dx * f, dy * f)                   // natural scrolling
        }
    }

    private func emuEnd(_ tr: Track, last: Bool, ts: TimeInterval, cancelled: Bool) {
        guard last else { return }
        cancelLongPress()
        if buttonHeld {
            buttonHeld = false
            sendAbs(tr.location)
            delegate?.engineEmit(.button(0, down: false))
            return
        }
        guard !cancelled, !gestureMoved else { return }
        let dur = ts - gestureStart
        if gestureMax == 1 && dur < TouchEngine.tapMax {
            sendAbs(tr.start)
            click(0)
        }
    }

    private func scheduleLongPress() {
        cancelLongPress()
        let w = DispatchWorkItem { [weak self] in self?.longPressFired() }
        longPressWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + TouchEngine.longPress, execute: w)
    }

    private func cancelLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
    }

    private func longPressFired() {
        longPressWork = nil
        guard route == .emulated, tracks.count == 1, gestureMax == 1, !gestureMoved, !buttonHeld,
              let tr = tracks.values.first else { return }
        sendAbs(tr.location)
        click(1)                                       // touch and hold = right click
        longPressDone = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: Touchscreen, native multi-touch

    private func touchEvent(_ tr: Track, phase: UInt8) -> InputEvent {
        let (x, y) = delegate?.engineNormalise(tr.location) ?? (0, 0)
        return .touch(id: UInt8(tr.slot), phase: phase, x: x, y: y)
    }

    // One finger = a real touch (the computer shows its touch feedback); holding still = the computer's own
    // touch-and-hold, which opens the right-click menu. Everything goes straight through.
    private func nativeDown(_ key: ObjectIdentifier) {
        guard let tr = tracks[key] else { return }
        nativePhase = .passthrough
        delegate?.engineEmit(touchEvent(tr, phase: 0))
    }

    private func nativeMove(_ tr: Track) {
        delegate?.engineEmit(touchEvent(tr, phase: 1))
    }

    private func nativeEnd(_ tr: Track, last: Bool, cancelled: Bool) {
        delegate?.engineEmit(touchEvent(tr, phase: cancelled ? 3 : 2))
    }

    private func scheduleNativeFlush(after delay: TimeInterval) {
        nativeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.nativeFlush() }
        nativeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Sends the buffered touches as real touch events and passes everything else straight through.
    private func nativeFlush() {
        nativeWork?.cancel(); nativeWork = nil
        guard nativePhase == .buffering || nativePhase == .candidate else { return }
        nativePhase = .passthrough
        let events = buffer
        buffer.removeAll(keepingCapacity: true)
        for e in events { delegate?.engineEmit(e) }
    }
}

/// Plain view that forwards raw touches to a TouchEngine.
final class TouchSurfaceView: UIView {
    var engine: TouchEngine?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .black
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { engine?.touchesBegan(touches, in: self) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { engine?.touchesMoved(touches, in: self) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { engine?.touchesEnded(touches, in: self) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { engine?.touchesCancelled(touches, in: self) }
}
