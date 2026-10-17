import AppKit
import BlackoutCore
import ServiceManagement

final class SettingsViewController: NSViewController {
    weak var delegate: AppDelegate?
    var fields: [String: (NSTextField, ShortcutRecorder)] = [:]
    var rows: [String: NSStackView] = [:]
    var inputControls: [String: InputControls] = [:]
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
                "A shortcut either disconnects a monitor from macOS (windows move to the other screens; panel power stays on) or switches its input to your other computer over DDC (windows stay put). The last active display stays on. Use Forget to remove a monitor that's no longer connected."
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
                    let container = NSStackView(views: [row])
                    container.orientation = .vertical
                    container.alignment = .leading
                    container.spacing = 6
                    let controls = InputControls(
                        uuid: monitor.uuid, target: self, action: #selector(inputControlsChanged(_:)))
                    controls.load(
                        setting: d.store.inputSwitch(for: monitor.uuid), inputs: d.store.knownInputs(for: monitor.uuid))
                    if !monitor.active || disabled.contains(monitor.uuid) {
                        controls.setUnavailable("Connect this monitor to change what its shortcut does.")
                    }
                    container.addArrangedSubview(controls.row)
                    inputControls[monitor.uuid] = controls
                    stack.addArrangedSubview(container)
                    fields[monitor.uuid] = (name, shortcut)
                    rows[monitor.uuid] = container
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
        view.frame.size.height = Self.height(monitors: fields.count)
        evaluateConflicts(showSummary: false)
        refreshInputs()
    }
    static func height(monitors: Int) -> CGFloat { CGFloat(325 + monitors * 72) }

    /// Reads each connected monitor's current input and input list over DDC in the background.
    func refreshInputs() {
        guard let d = delegate else { return }
        let disabled = d.store.disabledUUIDs
        let live = Set(((try? d.backend.enumerate(store: d.store, remember: false)) ?? []).filter(\.active).map(\.uuid))
        for (uuid, controls) in inputControls where live.contains(uuid) && !disabled.contains(uuid) {
            controls.setChecking()
            DispatchQueue.global(qos: .userInitiated).async { [weak self, backend = d.backend, store = d.store] in
                let result = Result { try backend.inputInfo(uuid: uuid, store: store) }
                DispatchQueue.main.async {
                    guard let self, let controls = self.inputControls[uuid] else { return }
                    switch result {
                    case .success(let info):
                        // While Blackout has the monitor on the other computer, its current input isn't the Mac's.
                        let away = store.switchedUUIDs.contains(uuid)
                        controls.update(inputs: info.inputs, detectedMacInput: away ? nil : info.current)
                    case .failure(let error):
                        controls.setUnavailable("DDC isn't available: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    @objc func inputControlsChanged(_ sender: NSPopUpButton) {
        guard let uuid = sender.identifier?.rawValue else { return }
        inputControls[uuid]?.userChanged(sender)
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
        var inputSettings: [String: InputSwitchSetting?] = [:]
        for (uuid, controls) in inputControls where controls.isEditable {
            let name = fields[uuid]?.0.stringValue ?? "Monitor"
            guard let setting = controls.chosenSetting() else {
                if d.store.switchedUUIDs.contains(uuid) {
                    fail(
                        "\(name) is on the other computer. Bring it back to the Mac before changing what its shortcut does."
                    )
                    return
                }
                inputSettings[uuid] = .some(nil)
                continue
            }
            guard setting.macInput != setting.otherInput else {
                fail("\(name): the Mac's input and the other computer's input must be different.")
                return
            }
            inputSettings[uuid] = .some(setting)
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
            for (uuid, setting) in inputSettings { d.store.setInputSwitch(setting, for: uuid) }
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
                self.inputControls[uuid] = nil
                self.rows.removeValue(forKey: uuid)?.removeFromSuperview()
                window.setContentSize(
                    NSSize(width: window.contentLayoutRect.width, height: Self.height(monitors: self.fields.count)))
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

/// The per-monitor "what does the shortcut do" line: disconnect, or switch between the Mac's and another input.
final class InputControls {
    let row = NSStackView()
    private let mode = NSPopUpButton()
    private let mac = NSPopUpButton()
    private let other = NSPopUpButton()
    private let note = NSTextField(labelWithString: "")
    private var inputs: [UInt8] = []
    private var saved: InputSwitchSetting?
    private var detectedMac: UInt8?
    private var otherChosen = false
    private(set) var isEditable = false

    init(uuid: String, target: AnyObject, action: Selector) {
        mode.addItems(withTitles: ["Shortcut disconnects", "Shortcut switches input"])
        for (popup, width, key) in [(mode, 190.0, "mode"), (mac, 120.0, "mac"), (other, 120.0, "other")] {
            popup.identifier = NSUserInterfaceItemIdentifier(uuid)
            popup.setAccessibilityIdentifier("monitor.input.\(key).\(uuid)")
            popup.target = target
            popup.action = action
            popup.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        mode.setAccessibilityLabel("Shortcut action")
        mac.setAccessibilityLabel("Mac's input")
        other.setAccessibilityLabel("Other computer's input")
        mac.toolTip = "The input your Mac is connected to. Blackout detects it; change it if it's wrong."
        other.toolTip = "The input your other computer is connected to."
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let macLabel = NSTextField(labelWithString: "Mac")
        let otherLabel = NSTextField(labelWithString: "Other")
        for label in [macLabel, otherLabel] { label.textColor = .secondaryLabelColor }
        row.orientation = .horizontal
        row.spacing = 8
        for view in [mode, macLabel, mac, otherLabel, other, note] { row.addArrangedSubview(view) }
    }

    func load(setting: InputSwitchSetting?, inputs: [UInt8]) {
        saved = setting
        mode.selectItem(at: setting == nil ? 0 : 1)
        update(inputs: inputs, detectedMacInput: nil)
    }

    /// Fills the input lists. The Mac's input is the saved one if any, otherwise the input the monitor shows now.
    func update(inputs newInputs: [UInt8], detectedMacInput: UInt8?) {
        var list = newInputs
        for code in [saved?.macInput, saved?.otherInput, detectedMacInput].compactMap({ $0 }) where !list.contains(code)
        {
            list.append(code)
        }
        inputs = list
        if let detectedMacInput { detectedMac = detectedMacInput }
        let macInput = saved?.macInput ?? detectedMac
        fill(mac, selecting: macInput)
        let chosenOther = otherChosen ? selectedCode(other) : nil
        let otherInput =
            saved?.otherInput ?? chosenOther
            ?? macInput.flatMap { InputSwitchPolicy.defaultOtherInput(inputs: list, macInput: $0) }
        fill(other, selecting: otherInput)
        // Until the Mac's input is known (saved or detected), a popup's default first item could be mistaken for it.
        isEditable = list.count >= 2 && macInput != nil
        note.stringValue = isEditable ? "" : "Checking monitor…"
        refreshEnabled()
    }

    func setChecking() {
        if inputs.count < 2 { note.stringValue = "Checking monitor…" }
    }

    func setUnavailable(_ reason: String) {
        isEditable = false
        note.stringValue = saved == nil ? "DDC unavailable" : ""
        row.toolTip = reason
        refreshEnabled()
    }

    /// A popup changed by the user; remembers an explicit "Other" choice across background refreshes.
    func userChanged(_ popup: NSPopUpButton) {
        if popup === other { otherChosen = true }
        refreshEnabled()
    }

    func refreshEnabled() {
        mode.isEnabled = isEditable
        let switching = isEditable && mode.indexOfSelectedItem == 1
        mac.isEnabled = switching
        other.isEnabled = switching
    }

    /// nil when the shortcut should disconnect.
    func chosenSetting() -> InputSwitchSetting? {
        guard mode.indexOfSelectedItem == 1, let macInput = selectedCode(mac), let otherInput = selectedCode(other)
        else {
            return nil
        }
        return InputSwitchSetting(macInput: macInput, otherInput: otherInput)
    }

    private func fill(_ popup: NSPopUpButton, selecting code: UInt8?) {
        popup.removeAllItems()
        for input in inputs {
            popup.addItem(withTitle: DDC.inputName(input))
            popup.lastItem?.tag = Int(input)
        }
        if let code, let index = inputs.firstIndex(of: code) { popup.selectItem(at: index) }
    }

    private func selectedCode(_ popup: NSPopUpButton) -> UInt8? {
        popup.selectedItem.map { UInt8(truncatingIfNeeded: $0.tag) }
    }
}
