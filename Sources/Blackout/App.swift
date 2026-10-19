import AppKit
import BlackoutCore
import CoreGraphics

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

private let displayChanged: CGDisplayReconfigurationCallBack = { _, flags, context in
    guard !flags.contains(.beginConfigurationFlag), let context else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { delegate.refreshAfterDisplayChange() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = PreferencesStore()
    let backend = DisplayBackend()
    let hotkeys = HotkeyManager()
    let updates = UpdateController()
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var settingsWindow: NSWindow?
    var bindings: [UInt32: String] = [:]
    var lastHotkeyTime = Date.distantPast
    var refreshWork: DispatchWorkItem?
    var shortcutError: String?
    var busy = false
    var poweringOff = false
    let operations = DispatchQueue(label: "com.miketomkins.Blackout.display-operations")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Blackout")
        statusItem.button?.setAccessibilityLabel("Blackout")
        statusItem.button?.toolTip = "Blackout — monitor toggles"
        menu.delegate = self
        statusItem.menu = menu
        updates.onStateChange = { [weak self] in self?.buildMenu() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.poweringOff = true }
        hotkeys.onPress = { [weak self] id in
            guard let self, Date().timeIntervalSince(self.lastHotkeyTime) > 0.45, !self.busy else { return }
            self.lastHotkeyTime = Date()
            if id == 999 { self.reconnectAll() } else if let uuid = self.bindings[id] { self.toggleUUID(uuid) }
        }
        hotkeys.reserve(id: 999, spec: .reconnectAll)
        // Monitors Blackout turned off before a logout or restart are back on now; drop their stale flags.
        operations.async { [backend, store] in try? backend.clearStaleDisabled(store: store) }
        do {
            let monitors = try backend.enumerate(store: store)
            updateShortcutError(configureHotkeys(monitors: monitors))
        } catch { updateShortcutError([error.localizedDescription]) }
        buildMenu()
        CGDisplayRegisterReconfigurationCallback(displayChanged, Unmanaged.passUnretained(self).toOpaque())
    }
    func menuWillOpen(_ menu: NSMenu) { buildMenu() }
    func refreshAfterDisplayChange() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.buildMenu()
            if let monitors = try? self.backend.enumerate(store: self.store),
                Set(monitors.filter { !$0.isBuiltIn }.map(\.uuid)) != Set(self.bindings.values)
            {
                self.updateShortcutError(self.configureHotkeys(monitors: monitors))
            }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    @discardableResult func configureHotkeys(monitors: [MonitorRecord], overrides: [String: ShortcutSpec?] = [:])
        -> [String]
    {
        var specs: [(UInt32, ShortcutSpec)] = []
        var map: [UInt32: String] = [:]
        var seen: Set<ShortcutSpec> = [.reconnectAll]
        var skipped: [String] = []
        for (i, m) in monitors.filter({ !$0.isBuiltIn }).sorted(by: { $0.uuid < $1.uuid }).enumerated() {
            // A cleared override is .some(nil), so it does not fall back to the saved shortcut.
            guard let spec = overrides[m.uuid] ?? store.shortcut(for: m.uuid) else { continue }
            // Skip a saved duplicate rather than letting it block every other shortcut.
            guard seen.insert(spec).inserted else {
                skipped.append("\(m.alias): \(spec.display) is already in use. Choose another shortcut.")
                continue
            }
            let id = UInt32(i + 1)
            specs.append((id, spec))
            map[id] = m.uuid
        }
        let errors = hotkeys.register(specs)
        if errors.isEmpty { bindings = map }
        return skipped + errors
    }
    func updateShortcutError(_ errors: [String]) {
        shortcutError = ([hotkeys.reservedError].compactMap { $0 } + errors).joined(separator: "\n").nilIfEmpty
    }
    func buildMenu() {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "Blackout", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        do {
            let monitors = try backend.enumerate(store: store)
            let activeCount = monitors.filter(\.active).count
            let switched = store.switchedUUIDs
            for display in monitors {
                let item = NSMenuItem(title: "", action: #selector(toggle(_:)), keyEquivalent: "")
                if let setting = store.inputSwitch(for: display.uuid) {
                    // Switch input mode: the display stays on the desktop, so the last-display guard doesn't apply.
                    item.title =
                        switched.contains(display.uuid)
                        ? "Bring \(display.alias) back to \(DDC.inputName(setting.macInput))"
                        : "Send \(display.alias) to \(DDC.inputName(setting.otherInput))"
                    item.isEnabled = !busy && display.active
                } else {
                    item.title = "\(display.active ? "Disconnect" : "Connect") \(display.alias)"
                    item.isEnabled = !busy && !display.isBuiltIn && (!display.active || activeCount > 1)
                }
                item.target = self
                item.representedObject = display.uuid
                if let shortcut = store.shortcut(for: display.uuid) {
                    item.keyEquivalent = shortcut.key
                    item.keyEquivalentModifierMask = shortcut.modifiers.eventFlags
                }
                menu.addItem(item)
            }
            if monitors.isEmpty { menu.addItem(NSMenuItem(title: "No monitors found", action: nil, keyEquivalent: "")) }
        } catch { menu.addItem(NSMenuItem(title: "Display state unavailable", action: nil, keyEquivalent: "")) }
        menu.autoenablesItems = false
        menu.addItem(.separator())
        let all = NSMenuItem(title: "Reconnect All", action: #selector(reconnectAll), keyEquivalent: "0")
        all.target = self
        all.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(all)
        if shortcutError != nil {
            let warning = NSMenuItem(
                title: "Shortcut needs attention — open Settings", action: #selector(showSettings), keyEquivalent: "")
            warning.target = self
            menu.addItem(warning)
        }
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let update = NSMenuItem(title: updates.menuTitle, action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        update.isEnabled = updates.state == .idle
        menu.addItem(update)
        let about = NSMenuItem(title: "About Blackout", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Blackout", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }
    @objc func toggle(_ sender: NSMenuItem) { if let uuid = sender.representedObject as? String { toggleUUID(uuid) } }
    func toggleUUID(_ uuid: String) {
        perform { [backend, store] in
            if store.inputSwitch(for: uuid) != nil {
                try backend.toggleInput(uuid: uuid, store: store)
            } else {
                try backend.toggle(uuid: uuid, store: store)
            }
            return []
        }
    }
    @objc func reconnectAll() {
        perform { [backend, store] in
            var errors: [String] = []
            for monitor in try backend.enumerate(store: store) where !monitor.active && !monitor.isBuiltIn {
                do { try backend.setEnabled(uuid: monitor.uuid, enabled: true, store: store) } catch {
                    errors.append("\(monitor.alias): \(error.localizedDescription)")
                }
            }
            errors += Self.returnSwitchedInputs(backend: backend, store: store)
            return errors
        }
    }
    /// Brings every monitor Blackout sent to the other computer back to the Mac's input.
    static func returnSwitchedInputs(backend: DisplayBackend, store: PreferencesStore) -> [String] {
        var errors: [String] = []
        for uuid in store.switchedUUIDs.sorted() {
            do { try backend.returnInputToMac(uuid: uuid, store: store) } catch {
                errors.append("\(store.alias(for: uuid, fallback: "Monitor")): \(error.localizedDescription)")
            }
        }
        return errors
    }
    // A change can wait seconds for the lock and for macOS to confirm it; keep that off the main thread.
    // busy stays set until any error alert is dismissed, so shortcuts and menu items cannot queue more work.
    private func perform(_ work: @escaping () throws -> [String]) {
        guard !busy else { return }
        busy = true
        buildMenu()
        operations.async {
            let errors: [String]
            do { errors = try work() } catch { errors = [error.localizedDescription] }
            DispatchQueue.main.async {
                if !errors.isEmpty { self.showError(BlackoutError.failed(errors.joined(separator: "\n"))) }
                self.busy = false
                self.buildMenu()
            }
        }
    }
    @objc func showSettings() {
        let controller = SettingsViewController(delegate: self)
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 650, height: 420), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "Blackout Settings"
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.contentViewController = controller
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func checkForUpdates() { updates.check() }
    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        // Version and build come from Info.plist; credits are just the author and the project link.
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let style: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centered,
        ]
        let credits = NSMutableAttributedString(string: "Made by Mike Tomkins\n", attributes: style)
        credits.append(
            NSAttributedString(
                string: "github.com/miketomkins/Blackout",
                attributes: style.merging([.link: URL(string: "https://github.com/miketomkins/Blackout")!]) { $1 }))
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Blackout", .credits: credits])
    }
    // Asks only for the menu's Quit; logout, restart and shutdown go straight to applicationShouldTerminate.
    @objc func quit() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit Blackout?"
        alert.informativeText =
            (store.disabledUUIDs.isEmpty ? "" : "Monitors Blackout turned off will be reconnected. ")
            + (store.switchedUUIDs.isEmpty ? "" : "Monitors on the other computer will switch back to the Mac. ")
            + "Your monitor shortcuts will stop working until you open Blackout again."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSApp.terminate(nil)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var errors: [String] = []
        operations.sync {}  // Let an in-flight change finish before restoring displays.
        // At logout or shutdown, change nothing and never block with a dialog. Display changes are session-scoped
        // (.forSession in NativeDisplayHardware.apply), so monitors Blackout turned off come back at the next login,
        // where launch clears their flags. Reconnecting now would only delay logout and, by restoring each monitor's
        // input, pull it back from the other computer; switched monitors likewise stay on the other computer.
        guard !poweringOff else { return .terminateNow }
        store.reload()
        errors += Self.returnSwitchedInputs(backend: backend, store: store)
        for uuid in store.disabledUUIDs {
            do { try backend.setEnabled(uuid: uuid, enabled: true, store: store) } catch {
                errors.append(error.localizedDescription)
            }
        }
        if !errors.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some monitors could not reconnect"
            alert.informativeText =
                errors.joined(separator: "\n") + "\nQuit anyway? Blackout will remember them for next launch."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")
            if alert.runModal() == .alertFirstButtonReturn {
                updates.quitCancelled()
                return .terminateCancel
            }
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        CGDisplayRemoveReconfigurationCallback(displayChanged, Unmanaged.passUnretained(self).toOpaque())
        hotkeys.unregister()
    }
    func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Blackout could not change that display"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        buildMenu()
    }
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
extension ShortcutSpec.Modifiers {
    fileprivate var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        return flags
    }
}
