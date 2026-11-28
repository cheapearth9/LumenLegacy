import Foundation
import Network
import CoreMedia
import UIKit

/// One computer in the "Computers on your network" list (Bonjour and/or unicast scan, merged).
struct DiscoveredHost {
    let id: String
    let name: String
    let platform: UInt8        // 0 unknown (Bonjour only), 1 mac, 2 windows, 3 linux
    let address: String?       // dotted IPv4 when known

    var platformLabel: String {
        switch platform {
        case 1: return "Mac"
        case 2: return "Windows"
        case 3: return "Linux"
        default: return ""
        }
    }
}

/// Networking + encryption + reassembly + hand-off to the display layers. All mutable state lives on `queue`.
/// Observers (UIKit view controllers) listen for `StreamClient.didChange` on the main thread and read the public properties.
/// Two transports share one protocol:
///  - Wi-Fi / Ethernet: UDP datagrams to the host (found over Bonjour / subnet scan, or typed IP).
///  - Cable: the app listens on a TCP port; the host reaches it through usbmuxd over USB.
final class StreamClient {
    enum State: Equatable {
        case idle, connecting, streaming
        case failed(String)
    }

    /// Posted on the main thread whenever a public property changed. userInfo["field"] names it.
    static let didChange = Notification.Name("LumenStreamClientChanged")

    private struct Target {
        var name: String
        var address: String?
        var key: String        // keychain account (the pairing secret is stored per host)
    }

    private func changed(_ field: String) {
        NotificationCenter.default.post(name: StreamClient.didChange, object: self, userInfo: ["field": field])
    }

    // Public state: written on the main thread only.
    var state: State = .idle { didSet { changed("state") } }
    var hosts: [DiscoveredHost] = [] { didSet { changed("hosts") } }
    var statsText = "" { didSet { changed("stats") } }
    var videoSize = CGSize(width: 16, height: 9) { didSet { changed("videoSize") } }
    var cablePaused = false { didSet { changed("cablePaused") } }
    var hostCaps: UInt8 = 0 { didSet { changed("hostCaps") } }
    var hostSourceSize = CGSize.zero
    var hostMode: UInt8 = 0 { didSet { changed("hostMode") } }           // 0 mirror, 1 extend (what the host really does)
    var toast: String? { didSet { changed("toast") } }

    var hostSupportsNativeTouch: Bool { hostCaps & WelcomeInfo.capNativeTouch != 0 }
    var hostSupportsAudio: Bool { hostCaps & WelcomeInfo.capAudio != 0 }
    var hostModeText: String { hostMode == 1 ? "Extended display" : "Mirroring" }

    /// Supplies the resolution/fps/bitrate to request. Called off the main thread; hops to main internally.
    var helloProvider: (() -> HelloInfo)?

    private let queue = DispatchQueue(label: "lumen.client", qos: .userInteractive)
    private let bonjourBrowser = BonjourBrowser()
    private var bonjourStarted = false
    private var cableListener: NWListener?
    private var conn: NWConnection?
    private var connReady = false
    private var isCable = false
    private var suppressCable = false
    private var timer: DispatchSourceTimer?
    private var deframer = Deframer()
    private var epoch = 0

    // Discovery
    private var bonjour: [String: BonjourEntry] = [:]
    private var scanned: [String: (result: ScanResult, seen: Date)] = [:]
    private let scanner = SubnetScanner()
    private var scanning = false
    private var scanWaiters = [() -> Void]()
    private var scanTimer: DispatchSourceTimer?

    // Session
    private var target = Target(name: "", address: nil, key: "")
    private var pairingKey: Data?
    private var session: SecureSession?
    private var handshakeDone = false
    private var handshakeSentAt = Date.distantPast
    private var handshakeRetried = false
    private var replyAt: Date?
    private var sealedOK = false
    // Pairing (while active the watchdog is paused; the host waits for the user to type the code)
    private var pairingActive = false
    private var pairing: PairingClient?
    private var pairTries = 0
    private var pairStep1At = Date.distantPast
    private var pairStep3: Data?
    private var pairStep3At = Date.distantPast
    private var pairStep3SentAt = Date.distantPast

    private var reassembler = Reassembler()
    private var formatDesc: CMVideoFormatDescription?
    private var lastSets = [Data]()
    private var needKey = true
    private var lastKeyRequest = Date.distantPast
    private var hello: HelloInfo?
    private var gotWelcome = false
    private var gotFirstFrame = false
    private var connectedAt = Date()
    private var welcomeAt = Date()
    private var lastRx = Date()
    private var tick = 0
    private var inputSeq: UInt32 = 0

    private let audio = AudioPlayer()
    private var audioRunning = false

    private var statFrames = 0, statBytes = 0, rttMs = 0
    private var toastSerial = 0

    // MARK: Start (idempotent; call again when the app becomes active)

    func start() {
        startBrowsing()
        queue.async { self.startCableListener() }
    }

    // MARK: Discovery

    private func startBrowsing() {
        DispatchQueue.main.async {
            guard !self.bonjourStarted else { return }
            self.bonjourStarted = true
            self.bonjourBrowser.onUpdate = { [weak self] entries in
                guard let self = self else { return }
                self.queue.async {
                    var next: [String: BonjourEntry] = [:]
                    for e in entries { next[e.name] = e }
                    self.bonjour = next
                    self.publishHosts()
                }
            }
            self.bonjourBrowser.start()
        }
    }

    private func publishHosts() {
        var byId: [String: DiscoveredHost] = [:]
        var usedScan = Set<String>()
        for b in bonjour.values {
            var match: ScanResult?
            if let a = b.address, let s = scanned[a] {
                match = s.result
            } else {
                match = scanned.values.first { $0.result.name.caseInsensitiveCompare(b.name) == .orderedSame }?.result
            }
            if let m = match {
                usedScan.insert(m.address)
                byId[m.address] = DiscoveredHost(id: m.address, name: m.name, platform: m.platform, address: m.address)
            } else {
                let id = b.address ?? ("bonjour:" + b.name)
                byId[id] = DiscoveredHost(id: id, name: b.name, platform: 0, address: b.address)
            }
        }
        for s in scanned.values where !usedScan.contains(s.result.address) {
            byId[s.result.address] = DiscoveredHost(id: s.result.address, name: s.result.name, platform: s.result.platform,
                                                    address: s.result.address)
        }
        let list = byId.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async { self.hosts = list }
    }

    /// Runs one unicast subnet scan. `completion` is called (on the client queue) when it finished.
    func rescan(completion: (() -> Void)? = nil) {
        queue.async {
            if let completion = completion { self.scanWaiters.append(completion) }
            guard !self.scanning else { return }
            self.scanning = true
            self.scanner.scan(onResult: { [weak self] r in
                self?.queue.async {
                    self?.scanned[r.address] = (r, Date())
                    self?.publishHosts()
                }
            }, completion: { [weak self] in
                self?.queue.async {
                    guard let self = self else { return }
                    self.scanning = false
                    let cutoff = Date().addingTimeInterval(-12)
                    self.scanned = self.scanned.filter { $0.value.seen > cutoff }
                    self.publishHosts()
                    let waiters = self.scanWaiters
                    self.scanWaiters.removeAll()
                    waiters.forEach { $0() }
                }
            })
        }
    }

    /// Scans immediately and then every ~5 s while the connect screen is visible.
    func setDiscoveryActive(_ on: Bool) {
        queue.async {
            self.scanTimer?.cancel()
            self.scanTimer = nil
            guard on else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 5.0, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in
                guard let self = self, self.conn == nil else { return }
                self.rescan()
            }
            t.resume()
            self.scanTimer = t
        }
    }

    // MARK: Cable listener

    private func startCableListener() {
        guard cableListener == nil,
              let port = NWEndpoint.Port(rawValue: lumenCablePort) else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: port) else { return }
        l.newConnectionHandler = { [weak self] c in self?.cableAccepted(c) }
        l.stateUpdateHandler = { [weak self, weak l] st in
            switch st {
            case .failed, .cancelled:
                l?.cancel()
                self?.queue.async { if self?.cableListener === l { self?.cableListener = nil } }
            default: break
            }
        }
        l.start(queue: queue)
        cableListener = l
    }

    /// The host connected through the USB tunnel. Auto-connect only when we are idle.
    private func cableAccepted(_ c: NWConnection) {
        guard conn == nil, !suppressCable, let provider = helloProvider else { c.cancel(); return }
        let h = DispatchQueue.main.sync { provider() }
        begin(c, cable: true, hello: h, target: Target(name: "USB cable", address: nil, key: "usb-cable"))
    }

    /// Resume auto-connect after the user disconnected from a cable session.
    func resumeCable() {
        queue.async { self.suppressCable = false }
        DispatchQueue.main.async { self.cablePaused = false }
    }

    // MARK: Wi-Fi connect

    func connect(host: DiscoveredHost, hello: HelloInfo) {
        if let a = host.address {
            connect(address: a, name: host.name, key: host.name, hello: hello)
        }
    }

    func connect(recent: RecentHost, hello: HelloInfo) {
        connect(address: recent.address, name: recent.name, key: recent.key, hello: hello)
    }

    /// Manual IP entry: the pairing secret is stored under the typed address.
    func connect(host: String, hello: HelloInfo) {
        let a = host.trimmingCharacters(in: .whitespaces)
        connect(address: a, name: a, key: a, hello: hello)
    }

    private func connect(address: String, name: String, key: String, hello: HelloInfo) {
        guard let port = NWEndpoint.Port(rawValue: lumenPort) else { return }
        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(address), port: port)
        queue.async {
            self.beginUDP(ep, hello: hello, target: Target(name: name, address: address, key: key))
        }
    }

    private func beginUDP(_ endpoint: NWEndpoint, hello: HelloInfo, target: Target) {
        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo
        begin(NWConnection(to: endpoint, using: params), cable: false, hello: hello, target: target)
    }

    /// The app left the foreground: end the session so the computer goes back to its normal displays.
    func disconnectForBackground() {
        queue.async {
            guard self.handshakeDone else { return }
            self.send(.bye)
            self.teardown(notify: true)
        }
    }

    func disconnect() {
        queue.async {
            self.send(.bye)
            if self.isCable {
                self.suppressCable = true
                DispatchQueue.main.async { self.cablePaused = true }
            }
            self.teardown(notify: true)
        }
    }

    // MARK: Live settings (stream menu)

    /// Mute / unmute. Unmuting a stream that was started without audio asks the host for it with a new hello.
    func setAudio(_ on: Bool) {
        LumenSettings.audioOn = on
        queue.async {
            self.audio.muted = !on
            guard on, var h = self.hello, self.handshakeDone, !h.wantsAudio else { return }
            h.flags |= HelloInfo.flagAudio
            self.switchHello(h)
        }
    }

    /// Mirror / Extend while streaming: a new hello with the new flag (the host restarts the session).
    func setExtend(_ on: Bool) {
        LumenSettings.extend = on
        queue.async {
            guard var h = self.hello, self.handshakeDone, h.wantsExtend != on else { return }
            if on { h.flags |= HelloInfo.flagExtend } else { h.flags &= ~HelloInfo.flagExtend }
            if LumenSettings.audioOn { h.flags |= HelloInfo.flagAudio } else { h.flags &= ~HelloInfo.flagAudio }
            self.switchHello(h)
        }
    }

    /// A monitor was plugged in / switched on or off while streaming: ask the computer for the new size (no-op if unchanged).
    func reconnectForResolution() {
        let (w, h) = ResolutionSetting.requested()
        queue.async {
            guard var hello = self.hello, self.handshakeDone, Int(hello.width) != w || Int(hello.height) != h else { return }
            hello.width = UInt16(w); hello.height = UInt16(h)
            self.switchHello(hello)
        }
    }

    private func switchHello(_ h: HelloInfo) {
        hello = h
        gotWelcome = false
        gotFirstFrame = false
        needKey = true
        formatDesc = nil
        lastSets = []
        reassembler.reset()
        welcomeAt = Date()
        lastRx = Date()
    }

    // MARK: Session lifecycle (queue)

    private func begin(_ c: NWConnection, cable: Bool, hello: HelloInfo, target: Target) {
        Crumb.add("begin \(cable ? "cable" : "udp") \(target.key)")
        teardown(notify: false)
        epoch += 1
        var hello = hello
        // Separate bitrate settings for the USB cable and for Wi-Fi/Ethernet.
        let chosen: Float = cable ? LumenSettings.cableMbps : LumenSettings.wifiMbps
        hello.bitrateMbps = UInt16(chosen.rounded())
        self.hello = hello
        self.target = target
        pairingKey = nil
        session = nil
        handshakeDone = false
        handshakeRetried = false
        replyAt = nil
        sealedOK = false
        pairingActive = false
        pairing = nil
        pairStep3 = nil
        gotWelcome = false
        gotFirstFrame = false
        needKey = true
        formatDesc = nil
        lastSets = []
        reassembler.reset()
        deframer = Deframer()
        connectedAt = Date()
        lastRx = Date()
        tick = 0
        isCable = cable
        connReady = false
        audio.muted = !LumenSettings.audioOn
        setState(.connecting)
        DispatchQueue.main.async { self.toast = nil }

        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self = self, let c = c, self.conn === c else { return }
            switch st {
            case .ready:
                self.connReady = true
                Crumb.add("connection ready")
                if cable { self.receiveStream(c) } else { self.receiveDatagram(c) }
                self.beginHandshake()
            case .failed(let e):
                self.fail("Connection failed: \(e.localizedDescription)")
            default: break
            }
        }
        conn = c
        c.start(queue: queue)
        startTimer()

        if let k = PairingKeychain.load(host: target.key) {
            pairingKey = k
        } else {
            startPairing()
        }
    }

    private func teardown(notify: Bool) {
        timer?.cancel(); timer = nil
        conn?.cancel(); conn = nil
        connReady = false
        session = nil
        handshakeDone = false
        if pairingActive { dismissPrompt() }
        pairingActive = false
        pairing = nil
        pairStep3 = nil
        gotWelcome = false
        hello = nil
        isCable = false
        epoch += 1
        if audioRunning { audio.stop(); audioRunning = false }
        if notify { setState(.idle) }
        DispatchQueue.main.async { VideoRenderer.shared.clear() }
    }

    private func fail(_ msg: String) {
        teardown(notify: false)
        setState(.failed(msg))
    }

    private func setState(_ s: State) { DispatchQueue.main.async { self.state = s } }

    private func showToast(_ text: String) {
        DispatchQueue.main.async {
            self.toastSerial += 1
            let serial = self.toastSerial
            self.toast = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if self.toastSerial == serial { self.toast = nil }
            }
        }
    }

    // MARK: Pairing / handshake

    private func dismissPrompt() {
        DispatchQueue.main.async { PairingPrompt.dismiss() }
    }

    /// Enters pairing mode: no sealed session, the host shows nothing; we send step 1 once the connection is ready.
    private func startPairing() {
        Crumb.add("start pairing")
        pairingActive = true
        pairingKey = nil
        session = nil
        handshakeDone = false
        replyAt = nil
        sealedOK = false
        pairing = nil
        pairTries = 0
        pairStep3 = nil
        lastRx = Date()
        connectedAt = Date()
        setState(.connecting)
        sendPairStep1()
    }

    private func sendPair(_ payload: Data) {
        rawSend(Wire.encode(PacketHeader(type: .pair), payload: payload))
    }

    private func sendPairStep1() {
        guard connReady, pairingActive else { return }
        let p = PairingClient()
        pairing = p
        pairTries += 1
        pairStep1At = Date()
        sendPair(p.start(deviceName: UIDevice.current.name))
    }

    private func failPairing(_ msg: String) {
        dismissPrompt()
        pairingActive = false
        pairing = nil
        pairStep3 = nil
        if isCable { suppressCable = true; DispatchQueue.main.async { self.cablePaused = true } }
        fail(msg)
    }

    private func cancelPairing() {
        dismissPrompt()
        pairingActive = false
        send(.bye)
        if isCable { suppressCable = true; DispatchQueue.main.async { self.cablePaused = true } }
        teardown(notify: true)
    }

    private func handlePair(_ payload: Data) {
        guard pairingActive, let p = pairing, let step = payload.first else { return }
        switch step {
        case 2:
            guard pairStep3 == nil, let s3 = p.handleStep2(payload), let code = p.code else { return }
            Crumb.add("pairing step 2, showing code")
            pairStep3 = s3
            pairStep3At = Date()
            pairStep3SentAt = Date()
            sendPair(s3)
            let myEpoch = epoch
            let name = target.name
            DispatchQueue.main.async {
                PairingPrompt.show(host: name, code: code) { [weak self] in
                    self?.queue.async {
                        guard let self = self, self.epoch == myEpoch, self.conn != nil else { return }
                        self.cancelPairing()
                    }
                }
            }
        case 4:
            guard pairStep3 != nil, payload.count >= 2 else { return }
            switch payload[payload.startIndex + 1] {
            case 0:
                guard let secret = p.secret else { return }
                PairingKeychain.save(secret, host: target.key)
                dismissPrompt()
                pairingActive = false
                pairing = nil
                pairStep3 = nil
                pairingKey = secret
                session = nil
                handshakeDone = false
                handshakeRetried = false
                replyAt = nil
                sealedOK = false
                connectedAt = Date()
                lastRx = Date()
                setState(.connecting)
                beginHandshake()
            case 1: failPairing("Wrong code. Try pairing again.")
            case 2: failPairing("Host is busy or temporarily locked, try again in a minute")
            default: failPairing("Pairing failed")
            }
        default:
            break
        }
    }

    /// The stored secret did not work (host forgot this device or was reset): pair again.
    private func restartPairing() {
        PairingKeychain.delete(host: target.key)
        startPairing()
    }

    /// Starts (or restarts, with fresh keys) the key exchange. Idempotent while a session already exists.
    private func beginHandshake() {
        guard connReady, !pairingActive, session == nil, let key = pairingKey else { return }
        let (s, clientHello) = SecureSession.client(pairingKey: key)
        session = s
        handshakeDone = false
        handshakeSentAt = Date()
        rawSend(Wire.encode(PacketHeader(type: .handshake), payload: clientHello))
    }

    private func handleHandshake(_ payload: Data) {
        guard let s = session, !handshakeDone, !s.isReady else { return }
        if s.finish(serverReply: payload) {
            Crumb.add("handshake done")
            handshakeDone = true
            replyAt = Date()
            lastRx = Date()
        }
    }

    // MARK: Timer (handshake / hello retries, pings, stats, watchdog)

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.onTick() }
        t.resume()
        timer = t
    }

    private func onTick() {
        guard conn != nil else { return }
        let now = Date()
        if pairingActive && connReady {
            lastRx = now
            connectedAt = now
            if pairStep3 == nil {
                if pairing == nil {
                    sendPairStep1()
                } else if now.timeIntervalSince(pairStep1At) > 4.0 {
                    if pairTries >= 3 { failPairing("Could not reach the host") } else { sendPairStep1() }
                }
            } else if let s3 = pairStep3 {
                if now.timeIntervalSince(pairStep3At) > 125 {
                    failPairing("Pairing timed out")
                } else if !isCable && now.timeIntervalSince(pairStep3SentAt) > 1.0 {
                    pairStep3SentAt = now
                    sendPair(s3)
                }
            }
            return
        }
        tick += 1

        if connReady && pairingKey != nil {
            if !handshakeDone {
                if session == nil {
                    beginHandshake()
                } else if !isCable && now.timeIntervalSince(handshakeSentAt) > 1.0 {
                    session = nil
                    beginHandshake()
                }
            } else if !gotWelcome, let h = hello {
                send(.hello, payload: h.encode())
                if !sealedOK, let r = replyAt {
                    let waited = now.timeIntervalSince(r)
                    if !handshakeRetried && waited > 2.0 {
                        // One fresh handshake in case a stale reply gave us mismatching keys.
                        handshakeRetried = true
                        session = nil
                        handshakeDone = false
                        beginHandshake()
                        return
                    }
                    if waited > 4.0 {
                        restartPairing()
                        return
                    }
                }
            } else if tick % 4 == 0 {
                let ms = UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
                send(.ping, id: ms)
                let fps = statFrames, mbps = Double(statBytes) * 8 / 1e6
                statFrames = 0; statBytes = 0
                let text = String(format: "%@ · %d fps · %.1f Mbps · %d ms", isCable ? "Cable" : "Wi-Fi", fps, mbps, rttMs)
                DispatchQueue.main.async { self.statsText = text }
            }
        }

        // Watchdog: hosts may spend ~10 s probing encoders before the first frame; once streaming be quick.
        if !gotWelcome {
            let since = now.timeIntervalSince(handshakeDone ? max(lastRx, connectedAt) : connectedAt)
            if since > 15 { fail(handshakeDone ? "The host did not answer" : "Could not reach the host") }
        } else if !gotFirstFrame {
            if now.timeIntervalSince(welcomeAt) > 15 { fail("The host did not start streaming") }
        } else if now.timeIntervalSince(lastRx) > 4 {
            fail("Lost connection to the host")
        }
    }

    // MARK: Send

    private func rawSend(_ pkt: Data) {
        guard let c = conn else { return }
        if isCable {
            c.send(content: Deframer.frame(pkt), completion: .contentProcessed({ _ in }))
        } else {
            c.send(content: pkt, completion: .idempotent)
        }
    }

    /// Seals and sends. Dropped silently until the handshake finished.
    private func send(_ type: PacketType, id: UInt32 = 0, payload: Data = Data()) {
        guard let s = session, s.isReady else { return }
        let plain = Wire.encode(PacketHeader(type: type, id: id), payload: payload)
        if let sealed = s.seal(plain) { rawSend(sealed) }
    }

    func sendInput(_ e: InputEvent) {
        queue.async {
            guard self.gotWelcome, let s = self.session, s.isReady else { return }
            self.inputSeq &+= 1
            let plain = Wire.encode(PacketHeader(type: .input, id: self.inputSeq), payload: e.encode())
            guard let first = s.seal(plain) else { return }
            self.rawSend(first)
            if e.isDiscrete && !self.isCable {
                // Over Wi-Fi, key / button events are sent twice (sealed separately) so one lost datagram can't cause a stuck key.
                self.queue.asyncAfter(deadline: .now() + 0.006) {
                    if let again = s.seal(plain) { self.rawSend(again) }
                }
            }
        }
    }

    // MARK: Receive

    private func receiveDatagram(_ c: NWConnection) {
        c.receiveMessage { [weak self, weak c] data, _, _, error in
            guard let self = self, let c = c, self.conn === c else { return }
            if let data = data { self.process(data) }
            if error == nil { self.receiveDatagram(c) } else { self.fail("Connection closed") }
        }
    }

    private func receiveStream(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak c] data, _, isComplete, error in
            guard let self = self, let c = c, self.conn === c else { return }
            if let data = data, !data.isEmpty {
                for pkt in self.deframer.push(data) { self.process(pkt) }
            }
            if error != nil || isComplete { self.fail("Cable disconnected"); return }
            self.receiveStream(c)
        }
    }

    /// One datagram / one deframed packet. Only sealed packets that authenticate are trusted;
    /// the plain handshake reply is the single other thing we act on.
    private func process(_ raw: Data) {
        if SecureSession.isSealed(raw) {
            guard let s = session, s.isReady, let plain = s.open(raw), let (h, payload) = Wire.decode(plain) else { return }
            sealedOK = true
            lastRx = Date()
            handle(h, payload)
        } else if let (h, payload) = Wire.decode(raw) {
            if h.type == .handshake {
                if session != nil, !handshakeDone, !pairingActive, SecureSession.isPairingRequired(payload) {
                    restartPairing()
                } else {
                    handleHandshake(payload)
                }
            } else if h.type == .pair {
                handlePair(payload)
            }
        }
    }

    private func handle(_ h: PacketHeader, _ payload: Data) {
        switch h.type {
        case .welcome:
            guard let w = WelcomeInfo.decode(payload), !gotWelcome else { return }
            Crumb.add("welcome \(w.width)x\(w.height)")
            gotWelcome = true
            gotFirstFrame = false
            welcomeAt = Date()
            needKey = true
            formatDesc = nil
            lastSets = []
            reassembler.reset()

            let wantAudio = (w.caps & WelcomeInfo.capAudio) != 0 && (hello?.wantsAudio ?? false)
            if wantAudio {
                audio.muted = !LumenSettings.audioOn
                if !audioRunning { audio.start(); audioRunning = true }
            } else if audioRunning {
                audio.stop(); audioRunning = false
            }

            let t = target
            if let a = t.address, !a.isEmpty {
                let rec = RecentHost(name: t.name, address: a, key: t.key)
                DispatchQueue.main.async { RecentHosts.add(rec) }
            }
            DispatchQueue.main.async {
                self.videoSize = CGSize(width: Int(w.width), height: Int(w.height))
                self.hostCaps = w.caps
                self.hostSourceSize = CGSize(width: Int(w.sourceWidth), height: Int(w.sourceHeight))
                self.hostMode = w.mode
                self.state = .streaming
            }
        case .video:
            guard gotWelcome, let frame = reassembler.add(h, payload) else { return }
            handleVideo(frame)
        case .audio:
            if audioRunning { audio.push(payload) }
        case .status:
            guard let level = payload.first else { return }
            let text = String(decoding: payload.dropFirst(), as: UTF8.self)
            if level >= 1 {
                if isCable {
                    suppressCable = true
                    DispatchQueue.main.async { self.cablePaused = true }
                }
                fail(text.isEmpty ? "The host reported an error" : text)
            } else if !text.isEmpty {
                showToast(text)
            }
        case .ping:
            let now = UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
            rttMs = Int(now &- h.id)
        default:
            break
        }
    }

    private func handleVideo(_ f: Reassembler.Frame) {
        let isKey = (f.flags & 1) != 0
        if f.gap { needKey = true }

        var r = ByteReader(f.data)
        if isKey {
            var sets = [Data]()
            let n = Int(r.u8() ?? 0)
            for _ in 0..<n {
                guard let l = r.u16(), let s = r.take(Int(l)) else { return }
                sets.append(s)
            }
            if sets != lastSets || formatDesc == nil {
                Crumb.add("video format, \(sets.count) parameter sets")
                guard let fd = SampleFactory.formatDescription(parameterSets: sets) else { Crumb.add("format description failed"); return }
                formatDesc = fd
                lastSets = sets
            }
            needKey = false
        }

        if needKey { requestKeyframe(); return }
        guard let fd = formatDesc, let sb = SampleFactory.sampleBuffer(avcc: r.rest(), format: fd) else { return }
        if !gotFirstFrame { Crumb.add("first frame") }
        gotFirstFrame = true
        statFrames += 1
        statBytes += f.data.count
        VideoRenderer.shared.enqueue(sb)
    }

    private func requestKeyframe() {
        guard Date().timeIntervalSince(lastKeyRequest) > 0.1 else { return }
        lastKeyRequest = Date()
        send(.keyframeRequest)
    }
}
