import BlackoutCore
import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main struct BlackoutTests {
    static func main() {
        let left = MonitorRecord(uuid: "left", alias: "Left", x: -3840, isBuiltIn: false)
        let right = MonitorRecord(uuid: "right", alias: "Right", x: 0, isBuiltIn: false)
        let other = MonitorRecord(uuid: "other", alias: "Other", x: 3840, isBuiltIn: false)
        check(MonitorPolicy.canDisable(target: right, active: [left, right], disabled: []), "can disable one of two")
        check(
            !MonitorPolicy.canDisable(target: right, active: [left, other], disabled: []),
            "cannot disable identity absent from fresh active snapshot")
        check(!MonitorPolicy.canDisable(target: right, active: [right], disabled: []), "cannot disable last active")
        check(
            ShortcutSpec.parse("ctrl+alt+l") == ShortcutSpec(modifiers: [.control, .option], key: "l"), "parse shortcut"
        )
        check(ShortcutSpec.parse("ctrl+alt+?") == nil, "reject keys without a supported virtual keycode")
        check(ShortcutSpec.parse("shift+l") == nil, "reject shortcuts without control option or command")
        check(
            !ShortcutSpec.validate([
                ShortcutSpec(modifiers: [.control, .option], key: "l"),
                ShortcutSpec(modifiers: [.control, .option], key: "l"),
            ]), "reject duplicates")
        let suite = "com.miketomkins.Blackout.tests.\(UUID().uuidString)"
        let store = PreferencesStore(suiteName: suite)
        store.setAlias("Studio Right", for: "right")
        check(
            PreferencesStore(suiteName: suite).alias(for: "right", fallback: "missing") == "Studio Right",
            "alias survives new store")
        store.setDisabled(uuid: "right", disabled: true)
        check(
            PreferencesStore(suiteName: suite).disabledUUIDs.contains("right"), "disabled state survives store restart")
        store.setShortcut(ShortcutSpec(modifiers: [.control, .option], key: "r"), for: "right")
        check(PreferencesStore(suiteName: suite).shortcut(for: "right")?.key == "r", "shortcut survives new store")
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)

        let seedSuite = "com.miketomkins.Blackout.tests.seed.\(UUID().uuidString)"
        let seeded = PreferencesStore(suiteName: seedSuite)
        let three = (0..<3).map { MonitorRecord(uuid: "m\($0)", alias: "", x: $0 * 1000, isBuiltIn: false) }
        seeded.seedDefaults(three)
        check(
            three.compactMap { seeded.shortcut(for: $0.uuid)?.key } == ["1", "2", "3"],
            "three monitors seed digits by position")
        let farLeft = MonitorRecord(uuid: "m3", alias: "", x: -5000, isBuiltIn: false)
        seeded.seedDefaults(three + [farLeft])
        let four = (three + [farLeft]).compactMap { seeded.shortcut(for: $0.uuid) }
        check(
            four.count == 4 && Set(four).count == 4 && ShortcutSpec.validate(four + [.reconnectAll]),
            "late monitor sorted first does not reuse a taken digit")
        let many = (0..<12).map { MonitorRecord(uuid: "n\($0)", alias: "", x: $0 * 1000 + 10000, isBuiltIn: false) }
        seeded.seedDefaults(three + [farLeft] + many)
        let all = (three + [farLeft] + many).compactMap { seeded.shortcut(for: $0.uuid) }
        check(
            all.count == 9 && ShortcutSpec.validate(all + [.reconnectAll]),
            "more than nine monitors never produce duplicate shortcuts")
        UserDefaults(suiteName: seedSuite)?.removePersistentDomain(forName: seedSuite)

        check(
            ShortcutSpec.recorded(keyCode: 37, modifiers: [.control, .option])
                == ShortcutSpec(modifiers: [.control, .option], key: "l"), "recorded key code maps to US physical key")
        check(ShortcutSpec.recorded(keyCode: 37, modifiers: [.shift]) == nil, "recorded shift-only press is rejected")
        check(
            ShortcutSpec.recorded(keyCode: 122, modifiers: [.control]) == nil,
            "recorded unsupported key (F1) is rejected")
        let l = ShortcutSpec(modifiers: [.control, .option], key: "l")
        let conflicts = ShortcutConflicts.find([
            (id: "a", name: "Left", spec: l), (id: "b", name: "Right", spec: l),
            (id: "c", name: "Other", spec: .reconnectAll), (id: "d", name: "None", spec: nil),
        ])
        check(
            conflicts["a"]?.contains("Right") == true && conflicts["b"]?.contains("Left") == true,
            "duplicate shortcut flags both monitors by name")
        check(
            conflicts["c"]?.contains("Reconnect All") == true && conflicts["d"] == nil && conflicts.count == 3,
            "reserved key flagged; cleared shortcut is not a conflict")

        let copy = ShortcutSpec.parse("cmd+c")!
        let standard = ShortcutConflicts.find([
            (id: "a", name: "Left", spec: copy), (id: "b", name: "Right", spec: ShortcutSpec.parse("cmd+shift+z")!),
        ])
        check(
            standard["a"]?.contains("Copy") == true && standard["b"]?.contains("Redo") == true,
            "standard app shortcuts like ⌘C and ⌘⇧Z block saving")
        check(
            ShortcutConflicts.find([(id: "a", name: "Left", spec: ShortcutSpec.parse("ctrl+alt+c")!)]).isEmpty,
            "⌃⌥C is not mistaken for ⌘C")
        check(
            ShortcutConflicts.appWarning(for: ShortcutSpec.parse("cmd+1")!) != nil
                && ShortcutConflicts.appWarning(for: copy) == nil
                && ShortcutConflicts.appWarning(for: ShortcutSpec.parse("ctrl+alt+cmd+k")!) == nil,
            "other Command-only keys warn; standard and multi-modifier keys do not")

        check(
            MonitorPolicy.canForget(uuid: "x", online: [], disabled: [])
                && !MonitorPolicy.canForget(uuid: "x", online: ["x"], disabled: [])
                && !MonitorPolicy.canForget(uuid: "x", online: [], disabled: ["x"]),
            "only offline monitors Blackout did not disconnect can be forgotten")
        check(
            MonitorPolicy.canIdentify(right, disabled: []) && !MonitorPolicy.canIdentify(right, disabled: ["right"])
                && !MonitorPolicy.canIdentify(
                    MonitorRecord(uuid: "x", alias: "X", x: 0, isBuiltIn: false, active: false), disabled: []),
            "only active monitors Blackout has not turned off can be identified")

        let clearSuite = "com.miketomkins.Blackout.tests.clear.\(UUID().uuidString)"
        let cleared = PreferencesStore(suiteName: clearSuite)
        let pair = [
            MonitorRecord(uuid: "left", alias: "", x: 0, isBuiltIn: false),
            MonitorRecord(uuid: "right", alias: "", x: 100, isBuiltIn: false),
        ]
        cleared.seedDefaults(pair)
        cleared.setShortcut(nil, for: "right")
        cleared.seedDefaults(pair)
        check(
            cleared.shortcut(for: "right") == nil && cleared.hasShortcutSetting(for: "right"),
            "a cleared shortcut is not re-seeded")
        UserDefaults(suiteName: clearSuite)?.removePersistentDomain(forName: clearSuite)
        print("Blackout core tests: PASS (\(checks) assertions)")
    }
}
