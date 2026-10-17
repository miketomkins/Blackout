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

/// Speaks the DDC/CI byte protocol like a Dell U2723QE: Get/Set VCP, capabilities fragments, null replies.
final class SimulatedDDCMonitor: DDCTransport {
    static let u2723qeCapabilities =
        "(prot(monitor)type(lcd)model(U2723QE)cmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(01 04 05 06 08 09 0B 0C) "
        + "16 18 1A 52 60( 1B 0F 11) AA(01 02 04) AC AE B2 B6 C6 C8 C9 D6(01 04 05) DC(00 03 05) DF E0 E1 "
        + "E2(00 1D 01 02 04 0E 12 14 23 24 27) F0(00 0C 0F 10 11 31 32 34 35) F1 F2 FD)mswhql(1)mccs_ver(2.1))"
    var vcp: [UInt8: UInt16] = [0x60: 0x0F, 0x10: 75]
    var capabilities = SimulatedDDCMonitor.u2723qeCapabilities
    var notReadyReplies = 0
    var silent = false
    var ignoresInputChanges = false
    var writes: [[UInt8]] = []
    private var pending: [UInt8]?

    func write(_ bytes: [UInt8]) -> Bool {
        writes.append(bytes)
        guard bytes.count >= 4, bytes.dropLast().reduce(UInt8(0x6E ^ 0x51), ^) == bytes.last else {
            pending = nil
            return true
        }
        switch bytes[1] {
        case 0x01:
            let code = bytes[2]
            let value = vcp[code] ?? 0
            var reply: [UInt8] = [0x6E, 0x88, 0x02, vcp[code] == nil ? 0x01 : 0x00, code, 0x00, 0x00, 0x64]
            reply += [UInt8(value >> 8), UInt8(value & 0xFF)]
            pending = reply + [reply.reduce(UInt8(0x50), ^)]
        case 0x03:
            if !(bytes[2] == 0x60 && ignoresInputChanges) { vcp[bytes[2]] = UInt16(bytes[3]) << 8 | UInt16(bytes[4]) }
            pending = nil
        case 0xF3:
            let offset = Int(bytes[2]) << 8 | Int(bytes[3])
            let all = Array(capabilities.utf8)
            let chunk = offset < all.count ? Array(all[offset..<min(offset + 32, all.count)]) : []
            let reply: [UInt8] = [0x6E, 0x80 | UInt8(3 + chunk.count), 0xE3, bytes[2], bytes[3]] + chunk
            pending = reply + [reply.reduce(UInt8(0x50), ^)]
        default:
            pending = nil
        }
        return true
    }

    func read(count: Int) -> [UInt8]? {
        if silent { return nil }
        var reply: [UInt8] = [0x6E, 0x80, 0xBE]
        if notReadyReplies > 0 { notReadyReplies -= 1 } else if let pending { reply = pending }
        return Array((reply + [UInt8](repeating: 0, count: max(0, count - reply.count))).prefix(count))
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

        // DDC/CI: packets match the bytes proven on Mike's monitors; the engine copes with null replies.
        check(DDC.getPacket(0x60) == [0x82, 0x01, 0x60, 0xDC], "Get VCP 0x60 packet and checksum")
        check(
            DDC.setPacket(0x60, value: 0x1B) == [0x84, 0x03, 0x60, 0x00, 0x1B, 0xC3],
            "Set VCP 0x60=USB-C packet and checksum")
        check(
            DDC.parseGetReply([0x6E, 0x80, 0xBE, 0, 0, 0, 0, 0, 0, 0, 0], code: 0x60) == .notReady,
            "null message means not ready")
        check(
            DDC.inputs(fromCapabilities: SimulatedDDCMonitor.u2723qeCapabilities) == [0x1B, 0x0F, 0x11],
            "U2723QE input list parsed")
        check(
            DDC.inputs(fromCapabilities: "vcp(B60(01) 60(0F 11))") == [0x0F, 0x11],
            "only a standalone 60(...) group is the input list")
        let panel = SimulatedDDCMonitor()
        panel.notReadyReplies = 3
        let ddc = DDC(transport: panel, sleep: { _ in })
        check((try? ddc.currentInput()) == 0x0F, "reads input after null replies")
        check(
            (try? ddc.capabilities()) == SimulatedDDCMonitor.u2723qeCapabilities,
            "capabilities string reassembled from fragments")
        try ddc.switchInput(to: 0x1B)
        check(panel.vcp[0x60] == 0x1B, "switchInput changes the input")
        check(
            !panel.writes.contains { $0.count > 1 && $0[1] == 0x03 && $0[2] != 0x60 },
            "only the input setting is ever written")
        panel.ignoresInputChanges = true
        rejects({ try ddc.switchInput(to: 0x0F) }, "a monitor that keeps reporting the old input is an error")
        panel.ignoresInputChanges = false
        panel.silent = true
        try ddc.switchInput(to: 0x0F)
        check(panel.vcp[0x60] == 0x0F, "a monitor that stops answering after switching still counts as switched")

        let ddcSuite = "com.miketomkins.Blackout.backendtests.ddc.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: ddcSuite)?.removePersistentDomain(forName: ddcSuite) }
        let ddcStore = PreferencesStore(suiteName: ddcSuite)
        let ddcHardware = SimulatedHardware()
        let panels = ["left": SimulatedDDCMonitor(), "right": SimulatedDDCMonitor()]
        let switcher = DisplayBackend(
            hardware: ddcHardware, lockPath: lock, settleTimeout: 0, ddcChannel: { panels[$0.uuid] }, ddcSleep: { _ in }
        )
        rejects({ try switcher.toggleInput(uuid: "right", store: ddcStore) }, "toggle needs Switch input mode")
        let info = try switcher.inputInfo(uuid: "right", store: ddcStore)
        check(
            info.current == 0x0F && info.inputs == [0x1B, 0x0F, 0x11]
                && ddcStore.knownInputs(for: "right") == info.inputs, "inputInfo reads and caches inputs")
        ddcStore.setInputSwitch(InputSwitchSetting(macInput: 0x0F, otherInput: 0x1B), for: "right")
        let sentTo = try switcher.toggleInput(uuid: "right", store: ddcStore)
        check(sentTo == 0x1B, "toggle sends the monitor to the other computer")
        check(
            panels["right"]!.vcp[0x60] == 0x1B && ddcStore.switchedUUIDs == ["right"] && panels["left"]!.writes.isEmpty,
            "only Right switched; recorded as away")
        let backTo = try switcher.toggleInput(uuid: "right", store: ddcStore)
        check(backTo == 0x0F && ddcStore.switchedUUIDs.isEmpty, "toggle brings it back")
        _ = try switcher.toggleInput(uuid: "right", store: ddcStore)
        try switcher.returnInputToMac(uuid: "right", store: ddcStore)
        check(
            panels["right"]!.vcp[0x60] == 0x0F && ddcStore.switchedUUIDs.isEmpty,
            "returnInputToMac restores the Mac input")
        panels["right"]!.silent = true
        _ = try switcher.toggleInput(uuid: "right", store: ddcStore)
        check(
            panels["right"]!.vcp[0x60] == 0x1B && ddcStore.switchedUUIDs == ["right"],
            "without a reading, Blackout's record decides the direction")
        _ = try switcher.toggleInput(uuid: "right", store: ddcStore)
        check(panels["right"]!.vcp[0x60] == 0x0F, "and the record brings it back")
        panels["right"]!.silent = false
        let before = panels["right"]!.writes.count
        ddcStore.setDisabled(uuid: "right", disabled: true)
        rejects(
            { try switcher.toggleInput(uuid: "right", store: ddcStore) },
            "no DDC switching while Blackout has the monitor disconnected")
        ddcStore.setDisabled(uuid: "right", disabled: false)
        ddcHardware.displays.removeAll { $0.uuid == "right" }
        rejects(
            { try switcher.toggleInput(uuid: "right", store: ddcStore) },
            "no DDC switching for a monitor that isn't on the desktop")
        check(panels["right"]!.writes.count == before, "refused switches send nothing to the monitor")
        ddcStore.setInputSwitch(nil, for: "right")
        check(
            ddcStore.inputSwitch(for: "right") == nil && ddcStore.switchedUUIDs.isEmpty,
            "leaving Switch input mode clears the away record")

        // Disconnect mode on a shared desk: reconnecting brings the monitor back from the other computer's input.
        let returnSuite = "com.miketomkins.Blackout.backendtests.return.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: returnSuite)?.removePersistentDomain(forName: returnSuite) }
        let returnStore = PreferencesStore(suiteName: returnSuite)
        let desk = SimulatedHardware()
        let rightPanel = SimulatedDDCMonitor()
        let deskBackend = DisplayBackend(
            hardware: desk, lockPath: lock, settleTimeout: 0, ddcChannel: { $0.uuid == "right" ? rightPanel : nil },
            ddcSleep: { _ in })
        try deskBackend.setEnabled(uuid: "right", enabled: false, store: returnStore)
        check(returnStore.returnInput(for: "right") == 0x0F, "disconnect records the input the Mac was using")
        check(!rightPanel.writes.contains { $0.count > 1 && $0[1] == 0x03 }, "disconnecting sends no DDC writes")
        rightPanel.vcp[0x60] = 0x1B  // The monitor's auto-input picks the other computer's live signal.
        try deskBackend.setEnabled(uuid: "right", enabled: true, store: returnStore)
        check(
            rightPanel.vcp[0x60] == 0x0F && returnStore.returnInput(for: "right") == nil,
            "reconnect switches the monitor back to the Mac's input")
        try deskBackend.setEnabled(uuid: "left", enabled: false, store: returnStore)
        try deskBackend.setEnabled(uuid: "left", enabled: true, store: returnStore)
        check(
            returnStore.returnInput(for: "left") == nil && desk.displays.count == 2,
            "monitors without DDC disconnect and reconnect as before")

        print("Blackout backend tests: PASS (\(checks) assertions; simulated writes + real read-only native adapter)")
    }
}
