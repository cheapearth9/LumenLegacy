import Foundation
import UIKit
import GameController

/// Hardware mouse + keyboard capture.
///  - iOS 14+: GameController (GCMouse / GCKeyboard) gives raw deltas, buttons, scroll and key up/down.
///  - iOS 13.4: keyboard through UIPress.key (see StreamViewController); iOS 12 / 13.0-13.3: UIKeyCommand taps.
/// Raw mouse deltas are batched at 250 Hz so we don't flood the network.
final class InputCapture {
    private let client: StreamClient
    private let lock = NSLock()
    private var accDX: Float = 0
    private var accDY: Float = 0
    private var timer: DispatchSourceTimer?
    private var observers = [NSObjectProtocol]()
    private var held = Set<Int>()            // HID usages currently down

    /// When true, mouse movement is sent as raw deltas (pointer is locked / game mode).
    var relativeMode = false
    /// Ctrl+Option+L toggles pointer lock.
    var onToggleLock: (() -> Void)?

    /// GameController reports Y with "up is positive"; flip so it matches screen coordinates.
    private let invertY: Float = -1
    private let scrollScale: Float = 14

    init(client: StreamClient) { self.client = client }

    func start() {
        if #available(iOS 14.0, *) { startGameController() }

        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.flushMouse() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel(); timer = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if #available(iOS 14.0, *) { stopGameController() }
        // Release anything still held so the computer never gets stuck keys.
        for hid in held { if let mac = KeyMap.hidToMac[hid] { client.sendInput(.key(mac, down: false)) } }
        held.removeAll()
    }

    /// Feed raw deltas from touch (trackpad-style) when no hardware mouse is used.
    func addRelative(dx: Float, dy: Float) {
        lock.lock(); accDX += dx; accDY += dy; lock.unlock()
    }

    private func flushMouse() {
        lock.lock()
        let dx = accDX, dy = accDY
        // keep sub-pixel remainder so slow movement isn't lost
        let sx = dx.rounded(.towardZero), sy = dy.rounded(.towardZero)
        accDX = dx - sx; accDY = dy - sy
        lock.unlock()
        if sx != 0 || sy != 0 {
            client.sendInput(.mouseRel(dx: Int16(max(-32000, min(32000, sx))),
                                       dy: Int16(max(-32000, min(32000, sy)))))
        }
    }

    // MARK: Keyboard (shared by every path)

    /// A key went down / up. `hid` is the USB HID usage. Called on the main thread.
    func key(hid: Int, pressed: Bool) {
        if pressed { held.insert(hid) } else { held.remove(hid) }

        // Local hotkey: Ctrl + Option + L releases / captures the mouse.
        let ctrl = held.contains(KeyMap.leftControl) || held.contains(KeyMap.rightControl)
        let alt = held.contains(KeyMap.leftAlt) || held.contains(KeyMap.rightAlt)
        if hid == KeyMap.keyL && ctrl && alt {
            if pressed { onToggleLock?() }
            return
        }
        if let mac = KeyMap.hidToMac[hid] { client.sendInput(.key(mac, down: pressed)) }
    }

    /// Complete key stroke (used by the UIKeyCommand fallback, which has no key-up events).
    func tap(hid: Int, shift: Bool, control: Bool, alt: Bool, command: Bool) {
        guard let mac = KeyMap.hidToMac[hid] else { return }
        var mods = [UInt16]()
        if control { mods.append(59) }
        if alt { mods.append(58) }
        if shift { mods.append(56) }
        if command { mods.append(55) }
        for m in mods { client.sendInput(.key(m, down: true)) }
        client.sendInput(.key(mac, down: true))
        client.sendInput(.key(mac, down: false))
        for m in mods.reversed() { client.sendInput(.key(m, down: false)) }
    }

    // MARK: GameController (iOS 14+)

    @available(iOS 14.0, *)
    private func startGameController() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] n in
            if let m = n.object as? GCMouse { self?.bind(mouse: m) }
        })
        observers.append(nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] n in
            if let k = n.object as? GCKeyboard { self?.bind(keyboard: k) }
        })
        for m in GCMouse.mice() { bind(mouse: m) }
        if let k = GCKeyboard.coalesced { bind(keyboard: k) }
    }

    @available(iOS 14.0, *)
    private func stopGameController() {
        for m in GCMouse.mice() {
            m.mouseInput?.mouseMovedHandler = nil
            m.mouseInput?.leftButton.pressedChangedHandler = nil
            m.mouseInput?.rightButton?.pressedChangedHandler = nil
            m.mouseInput?.middleButton?.pressedChangedHandler = nil
            m.mouseInput?.scroll.valueChangedHandler = nil
        }
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
    }

    @available(iOS 14.0, *)
    private func bind(mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = { [weak self] _, dx, dy in
            guard let self = self, self.relativeMode else { return }
            self.addRelative(dx: dx, dy: dy * self.invertY)
        }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, p in self?.client.sendInput(.button(0, down: p)) }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, p in self?.client.sendInput(.button(1, down: p)) }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, p in self?.client.sendInput(.button(2, down: p)) }
        input.scroll.valueChangedHandler = { [weak self] _, x, y in
            guard let self = self else { return }
            let dx = Int16(max(-2000, min(2000, x * self.scrollScale)))
            let dy = Int16(max(-2000, min(2000, y * self.scrollScale)))
            if dx != 0 || dy != 0 { self.client.sendInput(.scroll(dx: dx, dy: dy)) }
        }
    }

    @available(iOS 14.0, *)
    private func bind(keyboard: GCKeyboard) {
        keyboard.keyboardInput?.keyChangedHandler = { [weak self] _, _, code, pressed in
            let hid = Int(code.rawValue)
            if Thread.isMainThread { self?.key(hid: hid, pressed: pressed) }
            else { DispatchQueue.main.async { self?.key(hid: hid, pressed: pressed) } }
        }
    }
}
