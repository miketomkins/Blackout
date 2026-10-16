import AppKit
import BlackoutCore
import ServiceManagement

final class SettingsViewController: NSViewController {
    weak var delegate: AppDelegate?
    var fields: [String: (NSTextField, ShortcutRecorder)] = [:]
    var rows: [String: NSStackView] = [:]
    var systemWarnings: [String: String] = [:]
    let displayIdentifier = DisplayIdentifier()
    let feedback = NSTextField(wrappingLabelWithString: "")
    let login = NSButton(checkboxWithTitle: "Launch Blackout at login", target: nil, action: nil)
    let loginStatus = NSTextField(wrappingLabelWithString: "")
    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 650, height: 420))
        view.setAccessibilityIdentifier("blackout.settings")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
        ])
        let title = NSTextField(labelWithString: "Your monitors. One shortcut away.")
        title.font = .boldSystemFont(ofSize: 20)
        stack.addArrangedSubview(title)
        let help = NSTextField(
            wrappingLabelWithString:
                "Off disconnects the display from macOS; it does not cut panel power. The last active display stays on. Names and shortcuts are remembered; use Forget to remove a monitor that's no longer connected."
        )
        help.textColor = .secondaryLabelColor
        stack.addArrangedSubview(help)
        do {
            if let d = delegate {
                let online = (try? d.backend.onlineUUIDs()) ?? []
                let disabled = d.store.disabledUUIDs
                for monitor in try d.backend.enumerate(store: d.store) where !monitor.isBuiltIn {
                    let row = NSStackView()
                    row.orientation = .horizontal
                    row.spacing = 12
                    let name = NSTextField(string: monitor.alias)
                    name.setAccessibilityIdentifier("monitor.name.\(monitor.uuid)")
                    name.setAccessibilityLabel("\(monitor.alias) monitor name")
                    name.widthAnchor.constraint(equalToConstant: 180).isActive = true
                    let shortcut = ShortcutRecorder(spec: d.store.shortcut(for: monitor.uuid))
                    shortcut.setAccessibilityIdentifier("monitor.shortcut.\(monitor.uuid)")
                    shortcut.setAccessibilityLabel("\(monitor.alias) shortcut")
                    shortcut.widthAnchor.constraint(equalToConstant: 190).isActive = true
                    shortcut.onChange = { [weak self] _ in self?.evaluateConflicts() }
                    shortcut.onRecordingChange = { [weak d] recording in
                        if recording { d?.hotkeys.suspend() } else { d?.hotkeys.resume() }
                    }
                    let status =
                        disabled.contains(monitor.uuid)
                        ? "Off (Blackout)"
                        : monitor.active ? "Connected" : online.contains(monitor.uuid) ? "Inactive" : "Not connected"
                    let state = NSTextField(labelWithString: status)
                    state.textColor = .secondaryLabelColor
                    state.widthAnchor.constraint(equalToConstant: 100).isActive = true
                    row.addArrangedSubview(name)
                    row.addArrangedSubview(shortcut)
                    row.addArrangedSubview(state)
                    if MonitorPolicy.canIdentify(monitor, disabled: disabled) {
                        let identify = NSButton(title: "Identify", target: self, action: #selector(identifyMonitor(_:)))
                        identify.bezelStyle = .rounded
                        identify.identifier = NSUserInterfaceItemIdentifier(monitor.uuid)
                        identify.setAccessibilityIdentifier("monitor.identify.\(monitor.uuid)")
                        identify.setAccessibilityLabel("Identify \(monitor.alias)")
                        identify.toolTip = "Outline this monitor in red for a moment."
                        row.addArrangedSubview(identify)
                    }
                    if MonitorPolicy.canForget(uuid: monitor.uuid, online: online, disabled: disabled) {
                        let forget = NSButton(title: "Forget", target: self, action: #selector(forgetMonitor(_:)))
                        forget.bezelStyle = .rounded
                        forget.identifier = NSUserInterfaceItemIdentifier(monitor.uuid)
                        forget.setAccessibilityIdentifier("monitor.forget.\(monitor.uuid)")
                        forget.setAccessibilityLabel("Forget \(monitor.alias)")
                        forget.toolTip =
                            "Remove this monitor's name and shortcut. It comes back with defaults if connected again."
                        row.addArrangedSubview(forget)
                    }
                    stack.addArrangedSubview(row)
                    fields[monitor.uuid] = (name, shortcut)
                    rows[monitor.uuid] = row
                }
            }
        } catch { feedback.stringValue = error.localizedDescription }
        let hint = NSTextField(
            wrappingLabelWithString:
                "Click a shortcut, then press the keys: a letter or digit with ⌃, ⌥ or ⌘ (⇧ optional). Esc cancels; Delete clears. Reconnect All always uses ⌃⌥0. Keys refer to US physical key positions."
        )
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        let save = NSButton(title: "Save Changes", target: self, action: #selector(saveChanges))
        save.bezelStyle = .rounded
        save.setAccessibilityIdentifier("blackout.save")
        stack.addArrangedSubview(save)
        feedback.font = .systemFont(ofSize: 12)
        feedback.setAccessibilityIdentifier("blackout.feedback")
        feedback.stringValue = delegate?.shortcutError ?? ""
        stack.addArrangedSubview(feedback)
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 590).isActive = true
        stack.addArrangedSubview(line)
        login.target = self
        login.action = #selector(loginChanged)
        login.setAccessibilityIdentifier("blackout.launchAtLogin")
        stack.addArrangedSubview(login)
        loginStatus.font = .systemFont(ofSize: 11)
        loginStatus.textColor = .secondaryLabelColor
        loginStatus.setAccessibilityIdentifier("blackout.loginStatus")
        stack.addArrangedSubview(loginStatus)
        refreshLogin()
        view.frame.size.height = CGFloat(325 + fields.count * 38)
        evaluateConflicts(showSummary: false)
    }
    // Flags duplicates, the reserved key and standard app shortcuts like ⌘C (blocking),
    // plus enabled macOS shortcuts and other Command-only combinations (warning only).
    func evaluateConflicts(showSummary: Bool = true) {
        guard let d = delegate else { return }
        let rows = fields.map { (id: $0.key, name: $0.value.0.stringValue, spec: $0.value.1.spec) }
        let duplicates = ShortcutConflicts.find(rows)
        systemWarnings = [:]
        for row in rows {
            let recorder = fields[row.id]!.1
            if let message = duplicates[row.id] {
                recorder.setConflict(message, severity: .error)
                continue
            }
            let system = row.spec.flatMap { d.hotkeys.systemConflict(for: $0) ?? ShortcutConflicts.appWarning(for: $0) }
            if let system { systemWarnings[row.id] = system }
            recorder.setConflict(system, severity: .warning)
        }
        guard showSummary else { return }
        let messages = rows.sorted { $0.name < $1.name }.compactMap { row in
            (duplicates[row.id] ?? systemWarnings[row.id]).map { "\(row.name): \($0)" }
        }
        if messages.isEmpty {
            feedback.textColor = .secondaryLabelColor
            feedback.stringValue = "No conflicts. Save Changes to apply."
        } else {
            feedback.textColor = duplicates.isEmpty ? .systemOrange : .systemRed
            feedback.stringValue = messages.joined(separator: "\n")
        }
    }
    @objc func saveChanges() {
        guard let d = delegate else { return }
        var specs: [String: ShortcutSpec?] = [:]
        for (uuid, pair) in fields {
            guard !pair.0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                fail("Give every monitor a name.")
                return
            }
            specs[uuid] = pair.1.spec
        }
        let conflicts = ShortcutConflicts.find(
            fields.map { (id: $0.key, name: $0.value.0.stringValue, spec: $0.value.1.spec) })
        guard conflicts.isEmpty else {
            evaluateConflicts()
            return
        }
        do {
            let monitors = try d.backend.enumerate(store: d.store)
            let errors = d.configureHotkeys(monitors: monitors, overrides: specs)
            guard errors.isEmpty else {
                fail(errors.joined(separator: "\n"))
                return
            }
            for (uuid, pair) in fields {
                d.store.setAlias(pair.0.stringValue, for: uuid)
                d.store.setShortcut(pair.1.spec, for: uuid)
            }
            d.updateShortcutError([])
            d.buildMenu()
            evaluateConflicts(showSummary: false)
            if systemWarnings.isEmpty {
                feedback.textColor = .systemGreen
                feedback.stringValue = "Saved. Shortcuts are active."
            } else {
                feedback.textColor = .systemOrange
                feedback.stringValue =
                    "Saved, but these may clash with other shortcuts:\n"
                    + systemWarnings.values.sorted().joined(separator: "\n")
            }
        } catch { fail(error.localizedDescription) }
    }
    @objc func identifyMonitor(_ sender: NSButton) {
        guard let uuid = sender.identifier?.rawValue else { return }
        let name = fields[uuid]?.0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Monitor"
        if !displayIdentifier.identify(uuid: uuid, name: name) {
            fail("\(name) isn't on the desktop right now, so it can't be outlined.")
        }
    }
    @objc func forgetMonitor(_ sender: NSButton) {
        guard let d = delegate, let uuid = sender.identifier?.rawValue, let window = view.window else { return }
        let name = fields[uuid]?.0.stringValue ?? "this monitor"
        let alert = NSAlert()
        alert.messageText = "Forget \(name)?"
        alert.informativeText =
            "Its name and shortcut will be removed. If it's connected again, Blackout adds it back with default settings."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try d.backend.forget(uuid: uuid, store: d.store)
                self.fields[uuid] = nil
                self.rows.removeValue(forKey: uuid)?.removeFromSuperview()
                window.setContentSize(
                    NSSize(width: window.contentLayoutRect.width, height: CGFloat(325 + self.fields.count * 38)))
                if let monitors = try? d.backend.enumerate(store: d.store) {
                    d.updateShortcutError(d.configureHotkeys(monitors: monitors))
                }
                d.buildMenu()
                self.evaluateConflicts(showSummary: false)
                self.feedback.textColor = .secondaryLabelColor
                self.feedback.stringValue = "Forgot \(name)."
            } catch { self.fail(error.localizedDescription) }
        }
    }
    func fail(_ message: String) {
        feedback.textColor = .systemRed
        feedback.stringValue = message
    }
    func refreshLogin() {
        let status = SMAppService.mainApp.status
        login.state = (status == .enabled || status == .requiresApproval) ? .on : .off
        switch status {
        case .enabled: loginStatus.stringValue = "Enabled. Blackout will start when you sign in."
        case .requiresApproval:
            loginStatus.stringValue = "Waiting for approval in System Settings → General → Login Items."
        case .notRegistered: loginStatus.stringValue = "Off. Enable this if you want Blackout to start automatically."
        default: loginStatus.stringValue = "Login item is unavailable. Keep Blackout in Applications."
        }
    }
    @objc func loginChanged() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLogin()
        } catch {
            fail("Login setting: \(error.localizedDescription)")
            refreshLogin()
        }
    }
    override func viewWillAppear() {
        super.viewWillAppear()
        refreshLogin()
    }
    override func viewWillDisappear() {
        super.viewWillDisappear()
        for (_, recorder) in fields.values { recorder.stopRecording() }
        displayIdentifier.dismissAll()
    }
}
