import Foundation
import GameController

/// Forwards Bluetooth / MFi / USB game controllers (Xbox, PlayStation, Switch Pro, MFi) to the computer,
/// where they appear as virtual Xbox 360 controllers. Main-thread only.
final class GamepadCapture {
    private let client: StreamClient
    private var slots: [ObjectIdentifier: Int] = [:]
    private var pads: [Int: GCController] = [:]
    private var lastSent: [Int: TimeInterval] = [:]
    private var pending: Set<Int> = []
    private var pauseUntil: [Int: Date] = [:]
    private var refresh: Timer?
    private var observers: [NSObjectProtocol] = []
    private var running = false

    init(client: StreamClient) { self.client = client }

    func start() {
        guard !running else { return }
        running = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.add(c) }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.remove(c) }
        })
        for c in GCController.controllers() { add(c) }
        GCController.startWirelessControllerDiscovery(completionHandler: {})
        // UDP can lose a state packet; re-sending the full state a few times a second makes that harmless.
        refresh = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            for i in Array(self.pads.keys) { self.send(i) }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        GCController.stopWirelessControllerDiscovery()
        refresh?.invalidate(); refresh = nil
        for i in pads.keys { client.sendInput(.gamepadPresence(index: UInt8(i), present: false)) }
        pads.removeAll(); slots.removeAll()
    }

    private func add(_ c: GCController) {
        guard slots[ObjectIdentifier(c)] == nil, let pad = c.extendedGamepad else { return }
        guard let slot = (0..<4).first(where: { pads[$0] == nil }) else { return }
        slots[ObjectIdentifier(c)] = slot
        pads[slot] = c
        c.playerIndex = GCControllerPlayerIndex(rawValue: slot) ?? .indexUnset
        client.sendInput(.gamepadPresence(index: UInt8(slot), present: true))
        pad.valueChangedHandler = { [weak self] _, _ in self?.changed(slot) }
        if #available(iOS 13.0, *) {
            // Menu is a normal button there and reported through valueChangedHandler.
        } else {
            // iOS 12: only a pause event; send Start as a short press.
            c.controllerPausedHandler = { [weak self] _ in
                guard let self = self else { return }
                self.pauseUntil[slot] = Date().addingTimeInterval(0.12)
                self.send(slot)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { self.send(slot) }
            }
        }
        send(slot)
        DispatchQueue.main.async { self.client.toast = "Controller connected: \(c.vendorName ?? "gamepad")" }
    }

    private func remove(_ c: GCController) {
        guard let slot = slots.removeValue(forKey: ObjectIdentifier(c)) else { return }
        pads[slot] = nil
        client.sendInput(.gamepadPresence(index: UInt8(slot), present: false))
    }

    private func changed(_ slot: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - (lastSent[slot] ?? 0) >= 0.006 { send(slot); return }
        guard !pending.contains(slot) else { return }
        pending.insert(slot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.006) { [weak self] in
            self?.pending.remove(slot)
            self?.send(slot)
        }
    }

    private func send(_ slot: Int) {
        guard UserDefaults.standard.object(forKey: "controllersOn") as? Bool ?? true,
              let pad = pads[slot]?.extendedGamepad else { return }
        lastSent[slot] = ProcessInfo.processInfo.systemUptime
        var b: UInt16 = 0
        func set(_ on: Bool, _ bit: UInt16) { if on { b |= bit } }
        set(pad.dpad.up.isPressed, 0x0001); set(pad.dpad.down.isPressed, 0x0002)
        set(pad.dpad.left.isPressed, 0x0004); set(pad.dpad.right.isPressed, 0x0008)
        // Menu / Options / Home / stick clicks exist only on newer iOS; iOS 12 has just the pause handler (a momentary Start).
        if #available(iOS 13.0, *) {
            set(pad.buttonMenu.isPressed, 0x0010)
            set(pad.buttonOptions?.isPressed ?? false, 0x0020)
        } else {
            set(Date() < (pauseUntil[slot] ?? Date.distantPast), 0x0010)
        }
        if #available(iOS 12.1, *) {
            set(pad.leftThumbstickButton?.isPressed ?? false, 0x0040)
            set(pad.rightThumbstickButton?.isPressed ?? false, 0x0080)
        }
        set(pad.leftShoulder.isPressed, 0x0100); set(pad.rightShoulder.isPressed, 0x0200)
        if #available(iOS 14.0, *) { set(pad.buttonHome?.isPressed ?? false, 0x0400) }
        set(pad.buttonA.isPressed, 0x1000); set(pad.buttonB.isPressed, 0x2000)
        set(pad.buttonX.isPressed, 0x4000); set(pad.buttonY.isPressed, 0x8000)
        func axis(_ v: Float) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }
        func trig(_ v: Float) -> UInt8 { UInt8(max(0, min(1, v)) * 255) }
        client.sendInput(.gamepad(index: UInt8(slot), buttons: b,
                                  lt: trig(pad.leftTrigger.value), rt: trig(pad.rightTrigger.value),
                                  lx: axis(pad.leftThumbstick.xAxis.value), ly: axis(pad.leftThumbstick.yAxis.value),
                                  rx: axis(pad.rightThumbstick.xAxis.value), ry: axis(pad.rightThumbstick.yAxis.value)))
    }
}
