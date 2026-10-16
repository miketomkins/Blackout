import AppKit
import BlackoutCore
import Foundation
import ServiceManagement

func output(_ value: Any) throws {
    print(String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!)
}
let args = Array(CommandLine.arguments.dropFirst())
let store = PreferencesStore()
let backend = DisplayBackend()
do {
    if args == ["--list"] {
        let monitors = try backend.enumerate(store: store, remember: false)
        try output(
            monitors.map {
                [
                    "uuid": $0.uuid, "name": $0.alias, "id": $0.displayID, "active": $0.active, "builtIn": $0.isBuiltIn,
                    "x": $0.x, "y": $0.y, "shortcut": store.shortcut(for: $0.uuid)?.canonical ?? "",
                ] as [String: Any]
            })
        exit(0)
    }
    if args == ["--diagnostics"] {
        store.reload()
        try output([
            "app": "Blackout", "version": appVersion, "loginStatus": SMAppService.mainApp.status.rawValue,
            "ownedDisconnectedCount": store.disabledUUIDs.count, "preferenceDomain": PreferencesStore.suite,
        ])
        exit(0)
    }
    if args.count == 2, ["--toggle", "--connect", "--disconnect"].contains(args[0]) {
        guard UUID(uuidString: args[1]) != nil else {
            throw BlackoutError.unavailable("Supply a monitor UUID from --list.")
        }
        if args[0] == "--toggle" {
            try backend.toggle(uuid: args[1], store: store)
        } else {
            try backend.setEnabled(uuid: args[1], enabled: args[0] == "--connect", store: store)
        }
        exit(0)
    }
    if args == ["--connect-all"] {
        // Like the menu's Reconnect All: try every monitor, then report all failures together.
        var failures: [String] = []
        for monitor in try backend.enumerate(store: store) where !monitor.active && !monitor.isBuiltIn {
            do { try backend.setEnabled(uuid: monitor.uuid, enabled: true, store: store) } catch {
                failures.append("\(monitor.alias): \(error.localizedDescription)")
            }
        }
        guard failures.isEmpty else { throw BlackoutError.failed(failures.joined(separator: "\n")) }
        exit(0)
    }
    if args == ["--help"] {
        print(
            "Blackout \(appVersion)\n  --list                 Read-only display inventory JSON\n  --diagnostics          Read-only login/preference status\n  --toggle UUID          Toggle a monitor\n  --connect UUID         Reconnect a known monitor\n  --disconnect UUID      Disconnect a monitor (last display protected)\n  --connect-all          Reconnect known monitors\n  --show-settings        Open Settings\nNo arguments launches the menu-bar app. Quit reconnects monitors Blackout disabled."
        )
        exit(0)
    }
    guard args.isEmpty || args == ["--show-settings"] else {
        fputs("Unknown or incomplete arguments. Run Blackout --help.\n", stderr)
        exit(2)
    }
} catch {
    fputs("Blackout: \(error.localizedDescription)\n", stderr)
    exit(1)
}
let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.miketomkins.Blackout").first {
    $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
}
if let existing {
    if args == ["--show-settings"] {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.miketomkins.Blackout.showSettings"), object: nil, userInfo: nil,
            deliverImmediately: true)
    }
    existing.activate(options: [])
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
let observer = DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("com.miketomkins.Blackout.showSettings"), object: nil, queue: .main
) { _ in delegate.showSettings() }
if args == ["--show-settings"] { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { delegate.showSettings() } }
app.run()
