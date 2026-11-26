import UIKit
import AVKit

/// Full-screen stream view: shows video, owns input capture (touch engine, hardware mouse / keyboard),
/// pointer lock (iOS 14+) and the small overlay menu.
final class StreamViewController: UIViewController, TouchEngineDelegate {
    private let client: StreamClient
    private let input: InputCapture
    private lazy var gamepads = GamepadCapture(client: client)
    private let softKeyboard = SoftKeyboardView()
    private let routePicker: AVRoutePickerView = {
        let r = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        r.alpha = 0.01
        return r
    }()
    private let engine = TouchEngine()
    private let touchView = TouchSurfaceView()
    private let videoView = VideoView()
    private let statsLabel = UILabel()
    private let toastLabel = UILabel()
    private let menuButton = UIButton(type: .system)
    private var toastText: String?

    private var locked = false {
        didSet {
            input.relativeMode = locked
            engine.pointerLocked = locked
            if #available(iOS 14.0, *) { setNeedsUpdateOfPrefersPointerLocked() }
        }
    }

    init(client: StreamClient) {
        self.client = client
        self.input = InputCapture(client: client)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @available(iOS 14.0, *)
    override var prefersPointerLocked: Bool { return locked }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }
    override var prefersStatusBarHidden: Bool { return true }
    override var canBecomeFirstResponder: Bool { return true }

    // MARK: Hardware keyboard

    // Swallow hardware key presses so UIKit doesn't also act on them. iOS 14+ forwards them through GameController,
    // iOS 13.4 reads them here, older systems use the UIKeyCommand fallback below.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) { forward(presses, down: true) }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) { forward(presses, down: false) }
    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { forward(presses, down: false) }

    private func forward(_ presses: Set<UIPress>, down: Bool) {
        if #available(iOS 14.0, *) { return }
        if #available(iOS 13.4, *) {
            for p in presses {
                if let k = p.key { input.key(hid: Int(k.keyCode.rawValue), pressed: down) }
            }
        }
    }

    private lazy var fallbackCommands: [UIKeyCommand] = LegacyKeyCommands.make(action: #selector(hardwareKey(_:)))

    override var keyCommands: [UIKeyCommand]? {
        if #available(iOS 13.4, *) { return nil }
        return fallbackCommands
    }

    @objc private func hardwareKey(_ cmd: UIKeyCommand) {
        guard let hid = LegacyKeyCommands.hid(forInput: cmd.input ?? "") else { return }
        let f = cmd.modifierFlags
        input.tap(hid: hid, shift: f.contains(.shift), control: f.contains(.control),
                  alt: f.contains(.alternate), command: f.contains(.command))
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        engine.delegate = self
        engine.mode = LumenSettings.touchMode
        engine.hostHasNativeTouch = client.hostSupportsNativeTouch
        touchView.engine = engine
        touchView.frame = view.bounds
        touchView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(touchView)

        videoView.frame = touchView.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoView.isUserInteractionEnabled = false
        touchView.addSubview(videoView)

        statsLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statsLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statsLabel)

        toastLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        toastLabel.textColor = .white
        toastLabel.textAlignment = .center
        toastLabel.numberOfLines = 0
        toastLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        toastLabel.layer.cornerRadius = 10
        toastLabel.layer.masksToBounds = true
        toastLabel.alpha = 0
        toastLabel.isUserInteractionEnabled = false
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toastLabel)

        menuButton.setTitle("•••", for: .normal)
        menuButton.setTitleColor(.white, for: .normal)
        menuButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        menuButton.layer.cornerRadius = 16
        menuButton.addTarget(self, action: #selector(showMenu), for: .touchUpInside)
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(menuButton)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            statsLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            statsLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            menuButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            menuButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            menuButton.widthAnchor.constraint(equalToConstant: 56),
            menuButton.heightAnchor.constraint(equalToConstant: 32),
            toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastLabel.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -24),
            toastLabel.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 24),
            toastLabel.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -24)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(clientChanged(_:)), name: StreamClient.didChange, object: client)
        statsLabel.text = client.statsText

        if #available(iOS 13.0, *) {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
            touchView.addGestureRecognizer(hover)
        }

        input.onToggleLock = { [weak self] in self?.toggleLock() }
        input.start()
        if LumenSettings.controllersOn { gamepads.start() }
        softKeyboard.send = { [weak self] e in self?.client.sendInput(e) }
        softKeyboard.onHidden = { [weak self] in
            // Give the first responder back to this controller so hardware keys keep working.
            DispatchQueue.main.async { _ = self?.becomeFirstResponder() }
        }
        view.addSubview(softKeyboard)
        view.addSubview(routePicker)
        if LumenSettings.keyboardAuto { DispatchQueue.main.async { _ = self.softKeyboard.becomeFirstResponder() } }
        // With a monitor attached the stream plays there fullscreen and this screen is the touch surface.
        NotificationCenter.default.addObserver(self, selector: #selector(externalChanged), name: ExternalDisplay.changed, object: nil)
        videoView.isHidden = ExternalDisplay.isActive
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !softKeyboard.isFirstResponder { _ = becomeFirstResponder() }
    }

    @objc private func externalChanged() {
        videoView.isHidden = ExternalDisplay.isActive
        client.reconnectForResolution()
    }

    @objc private func clientChanged(_ n: Notification) {
        guard let field = n.userInfo?["field"] as? String else { return }
        switch field {
        case "stats": statsLabel.text = client.statsText
        case "toast": showToast(client.toast)
        case "hostCaps": engine.hostHasNativeTouch = client.hostSupportsNativeTouch
        default: break
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        gamepads.stop()
        engine.cancelAll()
        input.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Toast

    private func showToast(_ text: String?) {
        if let text = text, !text.isEmpty {
            toastLabel.text = "  " + text + "  "
            UIView.animate(withDuration: 0.2) { self.toastLabel.alpha = 1 }
        } else {
            UIView.animate(withDuration: 0.3) { self.toastLabel.alpha = 0 }
        }
    }

    // MARK: Menu (an action sheet: UIMenu needs iOS 14)

    private func toggleLock() { locked = !locked }

    private var pointerLockAvailable: Bool {
        if #available(iOS 14.0, *) { return true }
        return false
    }

    private func check(_ title: String, _ on: Bool) -> String { return on ? "✓ " + title : title }

    @objc private func showMenu() {
        let sheet = UIAlertController(title: "Host: \(client.hostModeText)", message: nil, preferredStyle: .actionSheet)
        let extend = LumenSettings.extend
        sheet.addAction(UIAlertAction(title: check("Mirror", !extend), style: .default) { [weak self] _ in self?.client.setExtend(false) })
        sheet.addAction(UIAlertAction(title: check("Extend", extend), style: .default) { [weak self] _ in self?.client.setExtend(true) })

        if client.hostSupportsAudio {
            let on = LumenSettings.audioOn
            sheet.addAction(UIAlertAction(title: on ? "Sound: On (tap to mute)" : "Sound: Off (tap to unmute)", style: .default) { [weak self] _ in
                self?.client.setAudio(!LumenSettings.audioOn)
            })
        }

        let tm = LumenSettings.touchMode
        sheet.addAction(UIAlertAction(title: check("Touchpad", tm == .touchpad), style: .default) { [weak self] _ in
            LumenSettings.touchMode = .touchpad; self?.engine.mode = .touchpad
        })
        sheet.addAction(UIAlertAction(title: check("Touchscreen", tm == .touchscreen), style: .default) { [weak self] _ in
            LumenSettings.touchMode = .touchscreen; self?.engine.mode = .touchscreen
        })

        let kbShown = softKeyboard.isFirstResponder
        sheet.addAction(UIAlertAction(title: kbShown ? "Hide keyboard" : "Show keyboard", style: .default) { [weak self] _ in
            guard let self = self else { return }
            if self.softKeyboard.isFirstResponder { _ = self.softKeyboard.resignFirstResponder() }
            else { _ = self.softKeyboard.becomeFirstResponder() }
        })

        let ext = ExternalDisplay.enabled
        sheet.addAction(UIAlertAction(title: ext ? "External display / AirPlay: On" : "External display / AirPlay: Off", style: .default) { [weak self] _ in
            ExternalDisplay.enabled = !ExternalDisplay.enabled        // observers update the screens
            self?.client.reconnectForResolution()
        })
        sheet.addAction(UIAlertAction(title: "Choose AirPlay screen…", style: .default) { [weak self] _ in
            guard let btn = self?.routePicker.subviews.compactMap({ $0 as? UIButton }).first else { return }
            btn.sendActions(for: .touchUpInside)
        })

        if pointerLockAvailable {
            sheet.addAction(UIAlertAction(title: locked ? "Release mouse (Ctrl+Opt+L)" : "Capture mouse for games (Ctrl+Opt+L)", style: .default) { [weak self] _ in
                self?.toggleLock()
            })
        }
        sheet.addAction(UIAlertAction(title: "Disconnect", style: .destructive) { [weak self] _ in self?.client.disconnect() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = menuButton
            pop.sourceRect = menuButton.bounds
        }
        present(sheet, animated: true, completion: nil)
    }

    // MARK: Geometry

    /// The aspect-fit video rectangle inside the touch view.
    private func videoRect() -> CGRect {
        let bounds = touchView.bounds
        let vs = client.videoSize
        guard vs.width > 0, vs.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / vs.width, bounds.height / vs.height)
        let w = vs.width * scale, h = vs.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func normalised(_ p: CGPoint) -> (UInt16, UInt16) {
        let rect = videoRect()
        guard rect.width > 0, rect.height > 0 else { return (0, 0) }
        let nx = min(max((p.x - rect.minX) / rect.width, 0), 1)
        let ny = min(max((p.y - rect.minY) / rect.height, 0), 1)
        return (UInt16(nx * 65535), UInt16(ny * 65535))
    }

    // MARK: TouchEngineDelegate

    func engineEmit(_ event: InputEvent) { client.sendInput(event) }

    func engineMoveCursor(dx: Float, dy: Float) { input.addRelative(dx: dx, dy: dy) }

    func engineNormalise(_ point: CGPoint) -> (UInt16, UInt16) { return normalised(point) }

    func engineSourcePixelsPerPoint() -> CGFloat {
        let rect = videoRect()
        let src = client.hostSourceSize.width > 0 ? client.hostSourceSize.width : client.videoSize.width
        guard rect.width > 0 else { return 1 }
        return src / rect.width
    }

    // MARK: Hovering pointer (iPad trackpad / mouse, iOS 13+)

    @available(iOS 13.0, *)
    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        guard !locked, g.state == .began || g.state == .changed else { return }
        let (x, y) = normalised(g.location(in: touchView))
        client.sendInput(.mouseAbs(x: x, y: y))
    }
}
