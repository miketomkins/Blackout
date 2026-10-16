import BlackoutCore
import Foundation

final class SimulatedHardware: DisplayHardware {
    var displays: [MonitorRecord]
    var calls: [(UInt32, Bool)] = []
    var failApply = false
    var suppressApply = false
    var failSnapshotsAfterApply = 0
    private var pendingSnapshotFailures = 0
    let initial: [MonitorRecord]
    init() {
        initial = [
            MonitorRecord(uuid: "left", alias: "Left", x: -3840, isBuiltIn: false, displayID: 1),
            MonitorRecord(uuid: "right", alias: "Right", x: 0, isBuiltIn: false, displayID: 2),
        ]
        displays = initial
    }
    func snapshot() throws -> [MonitorRecord] {
        if pendingSnapshotFailures > 0 {
            pendingSnapshotFailures -= 1
            throw BlackoutError.unavailable("simulated mid-reconfiguration read")
        }
        return displays
    }
    func identity(for id: UInt32) -> String? { displays.first { $0.displayID == id }?.uuid }
    func apply(id: UInt32, enabled: Bool) throws {
        calls.append((id, enabled))
        pendingSnapshotFailures = failSnapshotsAfterApply
        if failApply { throw BlackoutError.failed("simulated external OS failure") }
        if suppressApply { return }
        if enabled {
            if !displays.contains(where: { $0.displayID == id }),
                let original = initial.first(where: { $0.displayID == id })
            {
                displays.append(original)
            }
        } else {
            displays.removeAll { $0.displayID == id }
        }
    }
}
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}
func rejects(_ operation: () throws -> Void, _ message: String) {
    do {
        try operation()
        check(false, message)
    } catch { check(true, message) }
}
@main struct BackendTests {
    static func main() throws {
        let suite = "com.miketomkins.Blackout.backendtests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(suiteName: suite)
        let hw = SimulatedHardware()
        let lock = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/tests-\(UUID().uuidString)/display.lock").path
        defer { try? FileManager.default.removeItem(atPath: (lock as NSString).deletingLastPathComponent) }
        let backend = DisplayBackend(hardware: hw, lockPath: lock, settleTimeout: 0)
        _ = try backend.enumerate(store: store, remember: false)
        check(store.knownMonitors.isEmpty && store.allAliases().isEmpty, "read-only inventory does not persist state")
        _ = try backend.enumerate(store: store)
        check(store.alias(for: "left", fallback: "") == "Left", "geometric left default")
        check(store.shortcut(for: "right")?.canonical == "ctrl+alt+r", "right hotkey default is saved")
        try backend.setEnabled(uuid: "right", enabled: false, store: store)
        check(hw.displays.map(\.uuid) == ["left"], "native adapter boundary disables intended display only")
        check(hw.identity(for: 2) == nil, "simulation matches actual macOS disconnected NULL identity")
        check(store.disabledUUIDs == ["right"], "intent persists across disconnect")
        let listed = try backend.enumerate(store: store)
        check(listed.first { $0.uuid == "right" }?.active == false, "disconnected monitor remains listed")
        rejects(
            { try backend.setEnabled(uuid: "left", enabled: false, store: store) }, "last-active guard rejects write")
        check(hw.calls.count == 1, "last-active rejection performs no native write")
        let restarted = PreferencesStore(suiteName: suite)
        try DisplayBackend(hardware: hw, lockPath: lock, settleTimeout: 0).setEnabled(
            uuid: "right", enabled: true, store: restarted)
        check(
            Set(hw.displays.map(\.uuid)) == ["left", "right"],
            "restart reconnect uses saved ID despite absent live UUID")
        check(restarted.disabledUUIDs.isEmpty, "confirmed reconnect clears ownership")
        restarted.setDisabled(uuid: "right", disabled: true)
        try backend.toggle(uuid: "right", store: restarted)
        check(hw.displays.count == 1, "toggle trusts OS active state instead of stale ownership")
        hw.displays.append(MonitorRecord(uuid: "intruder", alias: "Other", x: 0, isBuiltIn: false, displayID: 2))
        let writes = hw.calls.count
        rejects(
            { try backend.setEnabled(uuid: "right", enabled: true, store: store) },
            "recycled address cannot reconnect wrong identity")
        check(hw.calls.count == writes, "recycled ID rejection happens before native write")
        hw.displays = hw.initial
        hw.failApply = true
        rejects({ try backend.setEnabled(uuid: "right", enabled: false, store: store) }, "native OS error surfaces")
        check(
            !store.disabledUUIDs.contains("right"),
            "failed disable leaves no false owned-off flag when OS reports active")
        hw.failApply = false
        hw.suppressApply = true
        rejects(
            { try backend.setEnabled(uuid: "right", enabled: false, store: store) },
            "successful native return without state change is not accepted")
        hw.suppressApply = false
        hw.displays = hw.initial
        hw.failSnapshotsAfterApply = 2
        let settling = DisplayBackend(hardware: hw, lockPath: lock, settleTimeout: 1)
        try settling.setEnabled(uuid: "right", enabled: false, store: store)
        check(
            hw.displays.map(\.uuid) == ["left"] && store.disabledUUIDs.contains("right"),
            "transient read failures after a successful change are retried, not reported")
        hw.failSnapshotsAfterApply = 0
        try settling.setEnabled(uuid: "right", enabled: true, store: store)
        rejects({ try backend.forget(uuid: "right", store: store) }, "a connected monitor cannot be forgotten")
        check(store.knownMonitors.contains { $0.uuid == "right" }, "rejected forget keeps the record")
        try backend.setEnabled(uuid: "right", enabled: false, store: store)
        rejects(
            { try backend.forget(uuid: "right", store: store) },
            "a Blackout-disconnected monitor cannot be forgotten (its address is needed to reconnect)")
        try backend.setEnabled(uuid: "right", enabled: true, store: store)
        store.remember([
            MonitorRecord(uuid: "old", alias: "Display", x: 9000, isBuiltIn: false, displayID: 9, active: false)
        ])
        store.setAlias("Projector", for: "old")
        store.setShortcut(ShortcutSpec(modifiers: [.control, .option], key: "p"), for: "old")
        try backend.forget(uuid: "old", store: store)
        check(
            !store.knownMonitors.contains { $0.uuid == "old" } && store.alias(for: "old", fallback: "none") == "none"
                && !store.hasShortcutSetting(for: "old"), "forget removes record, name and shortcut")
        let afterForget = try backend.enumerate(store: store)
        check(
            !afterForget.contains { $0.uuid == "old" } && store.alias(for: "right", fallback: "") == "Right",
            "forgotten monitor stays gone; others untouched")
        check(
            ShortcutSpec.keyCodes["l"] == 37 && ShortcutSpec.keyCodes["r"] == 15,
            "virtual keycodes are not ASCII character codes")
        check(!ShortcutSpec.validate([.reconnectAll, .reconnectAll]), "Reconnect All key cannot be duplicated")
        let native = try NativeDisplayHardware().snapshot()
        check(
            !native.isEmpty && native.allSatisfy { $0.displayID != 0 && UUID(uuidString: $0.uuid) != nil },
            "real read-only native snapshot yields real stable identities")
        print("Blackout backend tests: PASS (\(checks) assertions; simulated writes + real read-only native adapter)")
    }
}
