import AppKit
import CoreGraphics
import ServiceManagement

private let displayChanged:CGDisplayReconfigurationCallBack = { _,flags,context in
    guard !flags.contains(.beginConfigurationFlag), let context else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { delegate.refreshAfterDisplayChange() }
}

final class AppDelegate:NSObject,NSApplicationDelegate,NSMenuDelegate {
    let store = PreferencesStore()
    let backend = DisplayBackend()
    let hotkeys = HotkeyManager()
    var statusItem:NSStatusItem!
    let menu = NSMenu()
    var settingsWindow:NSWindow?
    var bindings:[UInt32:String] = [:]
    var lastHotkeyTime = Date.distantPast
    var refreshWork:DispatchWorkItem?
    var shortcutError:String?
    var busy = false
    let operations = DispatchQueue(label:"com.miketomkins.Blackout.display-operations")

    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName:"display",accessibilityDescription:"Blackout")
        statusItem.button?.setAccessibilityLabel("Blackout")
        statusItem.button?.toolTip = "Blackout — monitor toggles"
        menu.delegate = self; statusItem.menu = menu
        hotkeys.onPress = { [weak self] id in
            guard let self, Date().timeIntervalSince(self.lastHotkeyTime) > 0.45, !self.busy else { return }
            self.lastHotkeyTime = Date()
            if id == 999 { self.reconnectAll() }
            else if let uuid = self.bindings[id] { self.toggleUUID(uuid) }
        }
        hotkeys.reserve(id:999,spec:.reconnectAll)
        do { let monitors = try backend.enumerate(store:store); updateShortcutError(configureHotkeys(monitors:monitors)) }
        catch { updateShortcutError([error.localizedDescription]) }
        buildMenu()
        CGDisplayRegisterReconfigurationCallback(displayChanged,Unmanaged.passUnretained(self).toOpaque())
    }
    func menuWillOpen(_ menu:NSMenu) { buildMenu() }
    func refreshAfterDisplayChange() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.buildMenu()
            if let monitors = try? self.backend.enumerate(store:self.store), Set(monitors.filter { !$0.isBuiltIn }.map(\.uuid)) != Set(self.bindings.values) {
                self.updateShortcutError(self.configureHotkeys(monitors:monitors))
            }
        }
        refreshWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.3,execute:work)
    }
    @discardableResult func configureHotkeys(monitors:[MonitorRecord],overrides:[String:ShortcutSpec?] = [:]) -> [String] {
        var specs:[(UInt32,ShortcutSpec)] = []
        var map:[UInt32:String] = [:]
        var seen:Set<ShortcutSpec> = [.reconnectAll], skipped:[String] = []
        for (i,m) in monitors.filter({ !$0.isBuiltIn }).sorted(by: { $0.uuid < $1.uuid }).enumerated() {
            guard let spec = overrides[m.uuid] ?? store.shortcut(for:m.uuid) else { continue } // A cleared override is .some(nil).
            // Skip a saved duplicate rather than letting it block every other shortcut.
            guard seen.insert(spec).inserted else { skipped.append("\(m.alias): \(spec.display) is already in use. Choose another shortcut."); continue }
            let id = UInt32(i+1); specs.append((id,spec)); map[id] = m.uuid
        }
        let errors = hotkeys.register(specs)
        if errors.isEmpty { bindings = map }
        return skipped + errors
    }
    func updateShortcutError(_ errors:[String]) { shortcutError = ([hotkeys.reservedError].compactMap { $0 } + errors).joined(separator:"\n").nilIfEmpty }
    func buildMenu() {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title:"Blackout",action:nil,keyEquivalent:""))
        menu.addItem(.separator())
        do {
            let monitors = try backend.enumerate(store:store)
            let activeCount = monitors.filter(\.active).count
            for display in monitors {
                let item = NSMenuItem(title:"\(display.active ? "Disconnect" : "Connect") \(display.alias)",action:#selector(toggle(_:)),keyEquivalent:"")
                item.target = self; item.representedObject = display.uuid
                item.isEnabled = !busy && !display.isBuiltIn && (!display.active || activeCount > 1)
                if let shortcut = store.shortcut(for:display.uuid) { item.keyEquivalent = shortcut.key; item.keyEquivalentModifierMask = shortcut.modifiers.eventFlags }
                menu.addItem(item)
            }
            if monitors.isEmpty { menu.addItem(NSMenuItem(title:"No monitors found",action:nil,keyEquivalent:"")) }
        } catch { menu.addItem(NSMenuItem(title:"Display state unavailable",action:nil,keyEquivalent:"")) }
        menu.autoenablesItems = false
        menu.addItem(.separator())
        let all = NSMenuItem(title:"Reconnect All",action:#selector(reconnectAll),keyEquivalent:"0"); all.target = self; all.keyEquivalentModifierMask = [.control,.option]; menu.addItem(all)
        if shortcutError != nil { let warning = NSMenuItem(title:"Shortcut needs attention — open Settings",action:#selector(showSettings),keyEquivalent:""); warning.target = self; menu.addItem(warning) }
        let settings = NSMenuItem(title:"Settings…",action:#selector(showSettings),keyEquivalent:","); settings.target = self; menu.addItem(settings)
        let about = NSMenuItem(title:"About Blackout",action:#selector(showAbout),keyEquivalent:""); about.target = self; menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title:"Quit Blackout",action:#selector(quit),keyEquivalent:"q"); quit.target = self; menu.addItem(quit)
    }
    @objc func toggle(_ sender:NSMenuItem) { if let uuid = sender.representedObject as? String { toggleUUID(uuid) } }
    func toggleUUID(_ uuid:String) {
        perform { [backend,store] in try backend.toggle(uuid:uuid,store:store); return [] }
    }
    @objc func reconnectAll() {
        perform { [backend,store] in
            var errors:[String] = []
            for monitor in try backend.enumerate(store:store) where !monitor.active && !monitor.isBuiltIn {
                do { try backend.setEnabled(uuid:monitor.uuid,enabled:true,store:store) } catch { errors.append("\(monitor.alias): \(error.localizedDescription)") }
            }
            return errors
        }
    }
    // A change can wait seconds for the lock and for macOS to confirm it; keep that off the main thread.
    // busy stays set until any error alert is dismissed, so shortcuts and menu items cannot queue more work.
    private func perform(_ work:@escaping () throws -> [String]) {
        guard !busy else { return }; busy = true; buildMenu()
        operations.async {
            let errors:[String]
            do { errors = try work() } catch { errors = [error.localizedDescription] }
            DispatchQueue.main.async {
                if !errors.isEmpty { self.showError(BlackoutError.failed(errors.joined(separator:"\n"))) }
                self.busy = false; self.buildMenu()
            }
        }
    }
    @objc func showSettings() {
        let controller = SettingsViewController(delegate:self)
        if settingsWindow == nil {
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:650,height:420),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title = "Blackout Settings"; window.isReleasedWhenClosed = false; window.center(); settingsWindow = window
        }
        settingsWindow?.contentViewController = controller
        NSApp.activate(ignoringOtherApps:true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps:true)
        NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"Blackout",.applicationVersion:"1.0.0",.credits:NSAttributedString(string:"Disconnect a monitor. Keep your focus.\nControl–Option–L / R · Reconnect all: Control–Option–0\nCustom shortcuts and Launch at Login are in Settings.\nUses a private macOS display API; local build, not notarized.")])
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        var errors:[String] = []
        operations.sync {} // Let an in-flight change finish before restoring displays.
        store.reload()
        for uuid in store.disabledUUIDs {
            do { try backend.setEnabled(uuid:uuid,enabled:true,store:store) } catch { errors.append(error.localizedDescription) }
        }
        if !errors.isEmpty {
            let alert = NSAlert(); alert.messageText = "Some monitors could not reconnect"; alert.informativeText = errors.joined(separator:"\n") + "\nQuit anyway? Blackout will remember them for next launch."; alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:"Quit Anyway")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification:Notification) { CGDisplayRemoveReconfigurationCallback(displayChanged,Unmanaged.passUnretained(self).toOpaque()); hotkeys.unregister() }
    func showError(_ error:Error) {
        let alert = NSAlert(); alert.messageText = "Blackout could not change that display"; alert.informativeText = error.localizedDescription; NSApp.activate(ignoringOtherApps:true); alert.runModal(); buildMenu()
    }
}

final class SettingsViewController:NSViewController {
    weak var delegate:AppDelegate?
    var fields:[String:(NSTextField,ShortcutRecorder)] = [:]
    var rows:[String:NSStackView] = [:]
    var systemWarnings:[String:String] = [:]
    let feedback = NSTextField(wrappingLabelWithString:"")
    let login = NSButton(checkboxWithTitle:"Launch Blackout at login",target:nil,action:nil)
    let loginStatus = NSTextField(wrappingLabelWithString:"")
    init(delegate:AppDelegate) { self.delegate = delegate; super.init(nibName:nil,bundle:nil) }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        view = NSView(frame:NSRect(x:0,y:0,width:650,height:420)); view.setAccessibilityIdentifier("blackout.settings")
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:26),stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-26),stack.topAnchor.constraint(equalTo:view.topAnchor,constant:24),stack.bottomAnchor.constraint(lessThanOrEqualTo:view.bottomAnchor,constant:-20)])
        let title = NSTextField(labelWithString:"Your monitors. One shortcut away."); title.font = .boldSystemFont(ofSize:20); stack.addArrangedSubview(title)
        let help = NSTextField(wrappingLabelWithString:"Off disconnects the display from macOS; it does not cut panel power. The last active display stays on. Names and shortcuts are remembered; use Forget to remove a monitor that's no longer connected."); help.textColor = .secondaryLabelColor; stack.addArrangedSubview(help)
        do {
            if let d = delegate {
                let online = (try? d.backend.onlineUUIDs()) ?? [], disabled = d.store.disabledUUIDs
                for monitor in try d.backend.enumerate(store:d.store) where !monitor.isBuiltIn {
                    let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
                    let name = NSTextField(string:monitor.alias); name.setAccessibilityIdentifier("monitor.name.\(monitor.uuid)"); name.setAccessibilityLabel("\(monitor.alias) monitor name"); name.widthAnchor.constraint(equalToConstant:180).isActive = true
                    let shortcut = ShortcutRecorder(spec:d.store.shortcut(for:monitor.uuid)); shortcut.setAccessibilityIdentifier("monitor.shortcut.\(monitor.uuid)"); shortcut.setAccessibilityLabel("\(monitor.alias) shortcut"); shortcut.widthAnchor.constraint(equalToConstant:190).isActive = true
                    shortcut.onChange = { [weak self] _ in self?.evaluateConflicts() }
                    shortcut.onRecordingChange = { [weak d] recording in if recording { d?.hotkeys.suspend() } else { d?.hotkeys.resume() } }
                    let status = disabled.contains(monitor.uuid) ? "Off (Blackout)" : monitor.active ? "Connected" : online.contains(monitor.uuid) ? "Inactive" : "Not connected"
                    let state = NSTextField(labelWithString:status); state.textColor = .secondaryLabelColor; state.widthAnchor.constraint(equalToConstant:110).isActive = true
                    row.addArrangedSubview(name); row.addArrangedSubview(shortcut); row.addArrangedSubview(state)
                    if MonitorPolicy.canForget(uuid:monitor.uuid,online:online,disabled:disabled) {
                        let forget = NSButton(title:"Forget",target:self,action:#selector(forgetMonitor(_:))); forget.bezelStyle = .rounded; forget.identifier = NSUserInterfaceItemIdentifier(monitor.uuid)
                        forget.setAccessibilityIdentifier("monitor.forget.\(monitor.uuid)"); forget.setAccessibilityLabel("Forget \(monitor.alias)"); forget.toolTip = "Remove this monitor's name and shortcut. It comes back with defaults if connected again."
                        row.addArrangedSubview(forget)
                    }
                    stack.addArrangedSubview(row); fields[monitor.uuid] = (name,shortcut); rows[monitor.uuid] = row
                }
            }
        } catch { feedback.stringValue = error.localizedDescription }
        let hint = NSTextField(wrappingLabelWithString:"Click a shortcut, then press the keys: a letter or digit with ⌃, ⌥ or ⌘ (⇧ optional). Esc cancels; Delete clears. Reconnect All always uses ⌃⌥0. Keys refer to US physical key positions."); hint.font = .systemFont(ofSize:11); hint.textColor = .secondaryLabelColor; stack.addArrangedSubview(hint)
        let save = NSButton(title:"Save Changes",target:self,action:#selector(saveChanges)); save.bezelStyle = .rounded; save.setAccessibilityIdentifier("blackout.save"); stack.addArrangedSubview(save)
        feedback.font = .systemFont(ofSize:12); feedback.setAccessibilityIdentifier("blackout.feedback"); feedback.stringValue = delegate?.shortcutError ?? ""; stack.addArrangedSubview(feedback)
        let line = NSBox(); line.boxType = .separator; line.widthAnchor.constraint(equalToConstant:590).isActive = true; stack.addArrangedSubview(line)
        login.target = self; login.action = #selector(loginChanged); login.setAccessibilityIdentifier("blackout.launchAtLogin"); stack.addArrangedSubview(login)
        loginStatus.font = .systemFont(ofSize:11); loginStatus.textColor = .secondaryLabelColor; loginStatus.setAccessibilityIdentifier("blackout.loginStatus"); stack.addArrangedSubview(loginStatus); refreshLogin()
        view.frame.size.height = CGFloat(325 + fields.count * 38)
        evaluateConflicts(showSummary:false)
    }
    // Flags duplicates, the reserved key and standard app shortcuts like ⌘C (blocking),
    // plus enabled macOS shortcuts and other Command-only combinations (warning only).
    func evaluateConflicts(showSummary:Bool = true) {
        guard let d = delegate else { return }
        let rows = fields.map { (id:$0.key,name:$0.value.0.stringValue,spec:$0.value.1.spec) }
        let duplicates = ShortcutConflicts.find(rows)
        systemWarnings = [:]
        for row in rows {
            let recorder = fields[row.id]!.1
            if let message = duplicates[row.id] { recorder.setConflict(message,severity:.error); continue }
            let system = row.spec.flatMap { d.hotkeys.systemConflict(for:$0) ?? ShortcutConflicts.appWarning(for:$0) }
            if let system { systemWarnings[row.id] = system }
            recorder.setConflict(system,severity:.warning)
        }
        guard showSummary else { return }
        let messages = rows.sorted { $0.name < $1.name }.compactMap { row in (duplicates[row.id] ?? systemWarnings[row.id]).map { "\(row.name): \($0)" } }
        if messages.isEmpty { feedback.textColor = .secondaryLabelColor; feedback.stringValue = "No conflicts. Save Changes to apply." }
        else { feedback.textColor = duplicates.isEmpty ? .systemOrange : .systemRed; feedback.stringValue = messages.joined(separator:"\n") }
    }
    @objc func saveChanges() {
        guard let d = delegate else { return }
        var specs:[String:ShortcutSpec?] = [:]
        for (uuid,pair) in fields {
            guard !pair.0.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { fail("Give every monitor a name."); return }
            specs[uuid] = pair.1.spec
        }
        let conflicts = ShortcutConflicts.find(fields.map { (id:$0.key,name:$0.value.0.stringValue,spec:$0.value.1.spec) })
        guard conflicts.isEmpty else { evaluateConflicts(); return }
        do {
            let monitors = try d.backend.enumerate(store:d.store)
            let errors = d.configureHotkeys(monitors:monitors,overrides:specs)
            guard errors.isEmpty else { fail(errors.joined(separator:"\n")); return }
            for (uuid,pair) in fields { d.store.setAlias(pair.0.stringValue,for:uuid); d.store.setShortcut(pair.1.spec,for:uuid) }
            d.updateShortcutError([]); d.buildMenu()
            evaluateConflicts(showSummary:false)
            if systemWarnings.isEmpty { feedback.textColor = .systemGreen; feedback.stringValue = "Saved. Shortcuts are active." }
            else { feedback.textColor = .systemOrange; feedback.stringValue = "Saved, but these may clash with other shortcuts:\n" + systemWarnings.values.sorted().joined(separator:"\n") }
        } catch { fail(error.localizedDescription) }
    }
    @objc func forgetMonitor(_ sender:NSButton) {
        guard let d = delegate, let uuid = sender.identifier?.rawValue, let window = view.window else { return }
        let name = fields[uuid]?.0.stringValue ?? "this monitor"
        let alert = NSAlert(); alert.messageText = "Forget \(name)?"
        alert.informativeText = "Its name and shortcut will be removed. If it's connected again, Blackout adds it back with default settings."
        alert.addButton(withTitle:"Forget"); alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try d.backend.forget(uuid:uuid,store:d.store)
                self.fields[uuid] = nil; self.rows.removeValue(forKey:uuid)?.removeFromSuperview()
                window.setContentSize(NSSize(width:window.contentLayoutRect.width,height:CGFloat(325 + self.fields.count * 38)))
                if let monitors = try? d.backend.enumerate(store:d.store) { d.updateShortcutError(d.configureHotkeys(monitors:monitors)) }
                d.buildMenu(); self.evaluateConflicts(showSummary:false)
                self.feedback.textColor = .secondaryLabelColor; self.feedback.stringValue = "Forgot \(name)."
            } catch { self.fail(error.localizedDescription) }
        }
    }
    func fail(_ message:String) { feedback.textColor = .systemRed; feedback.stringValue = message }
    func refreshLogin() {
        let status = SMAppService.mainApp.status
        login.state = (status == .enabled || status == .requiresApproval) ? .on : .off
        switch status {
        case .enabled: loginStatus.stringValue = "Enabled. Blackout will start when you sign in."
        case .requiresApproval: loginStatus.stringValue = "Waiting for approval in System Settings → General → Login Items."
        case .notRegistered: loginStatus.stringValue = "Off. Enable this if you want Blackout to start automatically."
        default: loginStatus.stringValue = "Login item is unavailable. Keep Blackout in Applications."
        }
    }
    @objc func loginChanged() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLogin()
        } catch { fail("Login setting: \(error.localizedDescription)"); refreshLogin() }
    }
    override func viewWillAppear() { super.viewWillAppear(); refreshLogin() }
    override func viewWillDisappear() { super.viewWillDisappear(); fields.values.forEach { $0.1.stopRecording() } }
}

private extension String { var nilIfEmpty:String? { isEmpty ? nil : self } }
private extension ShortcutSpec.Modifiers {
    var eventFlags:NSEvent.ModifierFlags {
        var flags:NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }; if contains(.option) { flags.insert(.option) }; if contains(.command) { flags.insert(.command) }; if contains(.shift) { flags.insert(.shift) }; return flags
    }
}
