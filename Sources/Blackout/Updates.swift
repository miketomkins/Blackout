import AppKit
import BlackoutCore

/// Check for Updates…: runs only when chosen, and installs only after the user confirms.
final class UpdateController {
    enum State {
        case idle, checking, installing
    }
    private(set) var state = State.idle
    var onStateChange: (() -> Void)?
    /// The helper that reopens Blackout once this process exits; cancelled if quitting is cancelled.
    private(set) var relauncher: Process?
    private let work = DispatchQueue(label: "com.miketomkins.Blackout.updates")
    private let http = URLSessionHTTP(appVersion: appVersion)

    var menuTitle: String {
        switch state {
        case .idle: return "Check for Updates…"
        case .checking: return "Checking for Updates…"
        case .installing: return "Installing Update…"
        }
    }

    func check() {
        guard state == .idle else { return }
        setState(.checking)
        work.async { [http] in
            let result = Result { try UpdateChecker(http: http).check(current: appVersion) }
            DispatchQueue.main.async {
                self.setState(.idle)
                switch result {
                case .success(let update?): self.offer(update)
                case .success(nil):
                    self.inform("Blackout is up to date", "Version \(appVersion) is the newest release.")
                case .failure(let error):
                    self.inform("Couldn't check for updates", error.localizedDescription)
                }
            }
        }
    }

    private func offer(_ update: UpdateCandidate) {
        let alert = NSAlert()
        alert.messageText = "Blackout \(update.version) is available"
        alert.informativeText =
            "You have version \(appVersion). Installing quits Blackout, which reconnects any monitors it turned off, "
            + "then reopens the new version. Your settings and shortcuts are kept."
        if let notes = update.release.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            alert.accessoryView = notesView(notes)
        }
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        install(update)
    }

    private func install(_ update: UpdateCandidate) {
        let installed = Bundle.main.bundleURL
        let installer: UpdateInstaller
        do { installer = UpdateInstaller(http: http, publicKey: try UpdateConfig.publicKey()) } catch {
            return inform("Couldn't install the update", error.localizedDescription)
        }
        guard installer.canReplace(installed) else {
            return offerReleasePage(
                update,
                message: "Blackout can't replace itself in \(installed.deletingLastPathComponent().path). "
                    + "Download the new version from GitHub instead.")
        }
        guard let current = AppVersion(appVersion) else {
            return inform("Couldn't install the update", UpdateError.unknownVersion(appVersion).localizedDescription)
        }
        setState(.installing)
        work.async {
            let result = Result { try installer.prepare(update, replacing: installed, current: current) }
            DispatchQueue.main.async {
                do { try installer.swap(installed: installed, with: result.get()) } catch {
                    self.setState(.idle)
                    self.offerReleasePage(
                        update, message: error.localizedDescription + "\nBlackout \(appVersion) is still installed.")
                    return
                }
                do { try self.relaunch(installed) } catch {
                    self.setState(.idle)
                    self.inform(
                        "Blackout \(update.version) is installed",
                        "Blackout couldn't reopen itself. Quit Blackout, then open it again to start the new version.")
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// Starts a helper that waits for this process to exit, then opens the new app.
    private func relaunch(_ app: URL) throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"", "sh",
            String(ProcessInfo.processInfo.processIdentifier), app.path,
        ]
        try helper.run()
        relauncher = helper
    }

    /// Quitting was cancelled after an install: the new version is on disk, but don't reopen it behind the user's back.
    func quitCancelled() {
        relauncher?.terminate()
        relauncher = nil
        setState(.idle)
    }

    private func offerReleasePage(_ update: UpdateCandidate, message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't install the update"
        alert.informativeText = message
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(update.release.page) }
    }

    private func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func notesView(_ notes: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.string = notes
        text.isEditable = false
        text.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        text.textContainerInset = NSSize(width: 4, height: 4)
        text.autoresizingMask = [.width]
        scroll.documentView = text
        return scroll
    }

    private func setState(_ new: State) {
        state = new
        onStateChange?()
    }
}
