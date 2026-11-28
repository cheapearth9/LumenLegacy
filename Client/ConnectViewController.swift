import UIKit

/// The start screen: computers found on the network, recents, cable hint, manual IP and the stream settings.
final class ConnectViewController: UITableViewController {
    private enum Section: Int {
        case hosts, recent, cable, manual, display, touch, resolution, quality, status
    }
    private let sections: [Section] = [.hosts, .recent, .cable, .manual, .display, .touch, .resolution, .quality, .status]

    private let client: StreamClient
    private let rows = SettingsRows()
    private var recents: [RecentHost] = []

    private let cableNote = NoteCell(text: "Plug this device into your computer with a USB cable and start Lumen Host. It connects automatically.")
    private let manualCell = TextFieldCell(placeholder: "e.g. 192.168.1.20")
    private let manualButton = UITableViewCell(style: .default, reuseIdentifier: nil)
    private let resumeCell = UITableViewCell(style: .default, reuseIdentifier: nil)

    init(client: StreamClient) {
        self.client = client
        super.init(style: .grouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Lumen"
        tableView.keyboardDismissMode = .onDrag

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Settings", style: .plain, target: self, action: #selector(openSettings))

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pulled(_:)), for: .valueChanged)
        refreshControl = refresh

        manualCell.field.keyboardType = .numbersAndPunctuation
        manualCell.field.returnKeyType = .go
        manualCell.field.text = UserDefaults.standard.string(forKey: LumenSettings.manualHostKey)
        manualCell.field.addTarget(self, action: #selector(manualEdited), for: .editingChanged)
        manualCell.field.addTarget(self, action: #selector(manualGo), for: .editingDidEndOnExit)

        manualButton.textLabel?.text = "Connect"
        manualButton.textLabel?.textAlignment = .center
        manualButton.textLabel?.textColor = view.tintColor
        resumeCell.textLabel?.text = "Resume cable auto-connect"
        resumeCell.textLabel?.textColor = view.tintColor

        rows.onResolutionLayoutChange = { [weak self] in
            guard let self = self, let idx = self.sections.firstIndex(of: .resolution) else { return }
            self.tableView.reloadSections(IndexSet(integer: idx), with: .none)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(clientChanged(_:)), name: StreamClient.didChange, object: client)
        NotificationCenter.default.addObserver(self, selector: #selector(externalChanged), name: ExternalDisplay.changed, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        recents = RecentHosts.load()
        rows.refreshFromSettings()
        tableView.reloadData()
        client.setDiscoveryActive(true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        client.setDiscoveryActive(false)
    }

    // MARK: Actions

    @objc private func openSettings() {
        let nav = UINavigationController(rootViewController: SettingsViewController())
        present(nav, animated: true, completion: nil)
    }

    @objc private func pulled(_ r: UIRefreshControl) {
        client.rescan {
            DispatchQueue.main.async { r.endRefreshing() }
        }
    }

    @objc private func manualEdited() {
        UserDefaults.standard.set(manualCell.field.text ?? "", forKey: LumenSettings.manualHostKey)
    }

    @objc private func manualGo() {
        let text = (manualCell.field.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        manualCell.field.resignFirstResponder()
        client.connect(host: text, hello: LumenSettings.makeHello())
    }

    @objc private func externalChanged() { /* resolution text depends on the attached monitor; nothing to redraw */ }

    /// Reloading one section whose row count changed raises NSInternalInconsistencyException on newer iOS
    /// (e.g. the "Connecting" row appearing); a full reload is always safe in that case.
    private func refresh(section i: Int) {
        // numberOfRows(inSection:) can already report the new count, so the old/new comparison cannot be trusted: always reload fully.
        tableView.reloadData()
    }

    @objc private func clientChanged(_ n: Notification) {
        guard let field = n.userInfo?["field"] as? String else { return }
        switch field {
        case "hosts":
            if let i = sections.firstIndex(of: .hosts) { refresh(section: i) }
        case "state", "cablePaused":
            for s in [Section.cable, Section.status] {
                if let i = sections.firstIndex(of: s) { refresh(section: i) }
            }
        default:
            break
        }
    }

    // MARK: Table data

    override func numberOfSections(in tableView: UITableView) -> Int { return sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .hosts: return max(1, client.hosts.count)
        case .recent: return recents.count
        case .cable: return client.cablePaused ? 2 : 1
        case .manual: return 2
        case .display: return 2
        case .touch: return 2
        case .resolution: return rows.resolutionRows.count
        case .quality: return 3
        case .status: return statusText() == nil && !isConnecting ? 0 : 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .hosts: return "Computers on your network"
        case .recent: return recents.isEmpty ? nil : "Recent"
        case .cable: return "Cable"
        case .manual: return "Connect by IP address"
        case .display: return "Display"
        case .touch: return "Touch"
        case .resolution: return "Resolution"
        case .quality: return "Quality"
        case .status: return nil
        }
    }

    private var isConnecting: Bool {
        if case .connecting = client.state { return true }
        return false
    }

    private func statusText() -> String? {
        if case .failed(let m) = client.state { return m }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let r = indexPath.row
        switch sections[indexPath.section] {
        case .hosts:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            if client.hosts.isEmpty {
                cell.textLabel?.text = "Searching…"
                cell.textLabel?.textColor = FormStyle.secondaryText
                cell.selectionStyle = .none
            } else {
                let h = client.hosts[r]
                cell.textLabel?.text = h.name
                cell.detailTextLabel?.text = h.platformLabel
            }
            return cell
        case .recent:
            let rec = recents[r]
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = rec.name
            cell.detailTextLabel?.text = rec.address
            return cell
        case .cable: return r == 0 ? cableNote : resumeCell
        case .manual: return r == 0 ? manualCell : manualButton
        case .display: return r == 0 ? rows.display : rows.sound
        case .touch: return r == 0 ? rows.touch : rows.touchNote
        case .resolution: return rows.resolutionRows[r]
        case .quality: return r == 0 ? rows.fps : (r == 1 ? rows.cable : rows.wifi)
        case .status:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            if let m = statusText() {
                cell.textLabel?.text = m
                cell.textLabel?.textColor = .red
                cell.textLabel?.numberOfLines = 0
            } else {
                cell.textLabel?.text = "Connecting…"
            }
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let r = indexPath.row
        switch sections[indexPath.section] {
        case .hosts:
            if r < client.hosts.count { client.connect(host: client.hosts[r], hello: LumenSettings.makeHello()) }
        case .recent:
            client.connect(recent: recents[r], hello: LumenSettings.makeHello())
        case .cable:
            if r == 1 { client.resumeCable() }
        case .manual:
            if r == 1 { manualGo() }
        default:
            break
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return sections[indexPath.section] == .recent
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, sections[indexPath.section] == .recent else { return }
        RecentHosts.remove(address: recents[indexPath.row].address)
        recents = RecentHosts.load()
        tableView.reloadSections(IndexSet(integer: indexPath.section), with: .automatic)
    }

    override func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat { return 56 }
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { return UITableView.automaticDimension }
}

/// Touch, display, resolution, keyboard and controller options in a modal sheet.
final class SettingsViewController: UITableViewController {
    private enum Section: Int { case touch, display, resolution, keyboard, controllers }
    private let sections: [Section] = [.touch, .display, .resolution, .keyboard, .controllers]
    private let rows = SettingsRows()

    init() { super.init(style: .grouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        tableView.keyboardDismissMode = .onDrag
        rows.onResolutionLayoutChange = { [weak self] in
            guard let self = self, let idx = self.sections.firstIndex(of: .resolution) else { return }
            self.tableView.reloadSections(IndexSet(integer: idx), with: .none)
        }
    }

    @objc private func done() { dismiss(animated: true, completion: nil) }

    override func numberOfSections(in tableView: UITableView) -> Int { return sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .touch: return 2
        case .display: return 2
        case .resolution: return rows.resolutionRows.count
        case .keyboard: return 2
        case .controllers: return 2
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .touch: return "Touch"
        case .display: return "Display"
        case .resolution: return "Resolution"
        case .keyboard: return "Keyboard"
        case .controllers: return "Controllers"
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let r = indexPath.row
        switch sections[indexPath.section] {
        case .touch: return r == 0 ? rows.touch : rows.touchNote
        case .display: return r == 0 ? rows.display : rows.sound
        case .resolution: return rows.resolutionRows[r]
        case .keyboard:
            return r == 0 ? rows.keyboardAuto
                : NoteCell(text: "You can also open or close it any time from the ••• menu while streaming (Show keyboard). It types into the computer.")
        case .controllers:
            return r == 0 ? rows.controllers
                : NoteCell(text: "Connect an Xbox, PlayStation or MFi controller to this device over Bluetooth. It shows up as an Xbox 360 controller on the computer (Windows needs the ViGEmBus driver).")
        }
    }

    override func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat { return 56 }
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { return UITableView.automaticDimension }
}
