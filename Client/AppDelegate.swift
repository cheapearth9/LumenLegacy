import UIKit

/// The app's main window (used to find the top view controller for alerts).
enum AppWindows {
    static var main: UIWindow?
}

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let client = StreamClient()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        CrashReporter.install()
        Crumb.add("launch")
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = RootViewController(client: client)
        w.makeKeyAndVisible()
        window = w
        AppWindows.main = w

        client.helloProvider = { LumenSettings.makeHello() }
        ExternalDisplay.startObserving()

        if let failure = CryptoSelfTest.run() {
            let alert = UIAlertController(title: "Encryption self-test failed",
                                          message: "Connections will not work on this device (\(failure)).",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            DispatchQueue.main.async { w.rootViewController?.present(alert, animated: true, completion: nil) }
        }
        client.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { CrashReporter.offerPreviousReport(from: w.rootViewController) }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        var task = UIBackgroundTaskIdentifier.invalid
        task = application.beginBackgroundTask { application.endBackgroundTask(task) }
        client.disconnectForBackground()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { application.endBackgroundTask(task) }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // The cable listener can be torn down while backgrounded; re-arm it.
        client.start()
    }
}

// MARK: - External display (USB-C / Lightning HDMI adapter, AirPlay screen mirroring target)

/// iOS 12 (and iOS 13-15 apps without a scene manifest) announce an attached monitor through UIScreen notifications.
/// Giving the new UIScreen its own UIWindow makes the monitor a real second display showing the stream
/// instead of a plain mirror of the device screen.
enum ExternalDisplay {
    static let changed = Notification.Name("LumenExternalDisplayChanged")
    private(set) static var screen: UIScreen?
    private static var window: UIWindow?
    private static var observing = false

    static var isConnected: Bool { screen != nil }

    /// The user can switch the external display / AirPlay output off from the stream menu.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "externalOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "externalOn"); NotificationCenter.default.post(name: changed, object: nil) }
    }
    static var isActive: Bool { isConnected && enabled }

    /// Real pixel size of the attached monitor (its current mode, e.g. 1920x1080), not the scaled point size.
    static var pixelSize: CGSize? {
        guard let s = screen else { return nil }
        if let m = s.currentMode?.size, m.width > 0 { return m }
        let n = s.nativeBounds.size
        return n.width > 0 ? n : nil
    }

    static func startObserving() {
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIScreen.didConnectNotification, object: nil, queue: .main) { n in
            if let s = n.object as? UIScreen { attach(s) }
        }
        nc.addObserver(forName: UIScreen.didDisconnectNotification, object: nil, queue: .main) { n in
            if let s = n.object as? UIScreen { detach(s) }
        }
        for s in UIScreen.screens where s !== UIScreen.main { attach(s) }
    }

    private static func attach(_ s: UIScreen) {
        guard screen == nil, s !== UIScreen.main else { return }
        s.overscanCompensation = .none               // no inset black border on TVs / AirPlay
        let w = UIWindow(frame: s.bounds)
        w.screen = s
        w.rootViewController = ExternalVideoController()
        w.isHidden = false
        window = w
        screen = s
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func detach(_ s: UIScreen) {
        guard screen === s else { return }
        window?.isHidden = true
        window = nil
        screen = nil
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

final class ExternalVideoController: UIViewController {
    override func loadView() {
        let v = VideoView()
        v.displayLayer.videoGravity = .resizeAspect
        view = v
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: ExternalDisplay.changed, object: nil)
        refresh()
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func refresh() { view.isHidden = !ExternalDisplay.enabled }
    override var prefersStatusBarHidden: Bool { return true }
}

// MARK: - Root container

/// Shows the connect screen, or the stream while one is running.
final class RootViewController: UIViewController {
    private let client: StreamClient
    private let connectNav: UINavigationController
    private var stream: StreamViewController?
    private var current: UIViewController?

    init(client: StreamClient) {
        self.client = client
        connectNav = UINavigationController(rootViewController: ConnectViewController(client: client))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        show(connectNav)
        NotificationCenter.default.addObserver(self, selector: #selector(clientChanged(_:)), name: StreamClient.didChange, object: client)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var prefersStatusBarHidden: Bool { return stream != nil }
    override var childForStatusBarHidden: UIViewController? { return stream }
    override var childForHomeIndicatorAutoHidden: UIViewController? { return stream }

    @objc private func clientChanged(_ n: Notification) {
        guard (n.userInfo?["field"] as? String) == "state" else { return }
        let streaming: Bool
        if case .streaming = client.state { streaming = true } else { streaming = false }
        if streaming && stream == nil {
            let s = StreamViewController(client: client)
            stream = s
            show(s)
        } else if !streaming && stream != nil {
            stream = nil
            show(connectNav)
        }
        setNeedsStatusBarAppearanceUpdate()
        if #available(iOS 11.0, *) { setNeedsUpdateOfHomeIndicatorAutoHidden() }
    }

    private func show(_ vc: UIViewController) {
        if let old = current {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        addChild(vc)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(vc.view)
        vc.didMove(toParent: self)
        current = vc
    }
}
