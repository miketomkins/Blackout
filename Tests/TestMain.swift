import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main struct BlackoutTests {
    static func main() {
        let left = MonitorRecord(uuid: "left", alias: "Left", x: -3840, isBuiltIn: false)
        let right = MonitorRecord(uuid: "right", alias: "Right", x: 0, isBuiltIn: false)
        let other = MonitorRecord(uuid: "other", alias: "Other", x: 3840, isBuiltIn: false)
        check(MonitorPolicy.canDisable(target: right, active: [left, right], disabled: []), "can disable one of two")
        check(!MonitorPolicy.canDisable(target: right, active: [left, other], disabled: []), "cannot disable identity absent from fresh active snapshot")
        check(!MonitorPolicy.canDisable(target: right, active: [right], disabled: []), "cannot disable last active")
        check(ShortcutSpec.parse("ctrl+alt+l") == ShortcutSpec(modifiers: [.control,.option], key: "l"), "parse shortcut")
        check(ShortcutSpec.parse("ctrl+alt+?") == nil, "reject keys without a supported virtual keycode")
        check(ShortcutSpec.parse("shift+l") == nil, "reject shortcuts without control option or command")
        check(!ShortcutSpec.validate([ShortcutSpec(modifiers: [.control,.option], key:"l"),ShortcutSpec(modifiers: [.control,.option],key:"l")]), "reject duplicates")
        let suite = "com.miketomkins.Blackout.tests.\(UUID().uuidString)"
        let store = PreferencesStore(suiteName:suite)
        store.setAlias("Studio Right", for:"right")
        check(PreferencesStore(suiteName:suite).alias(for:"right",fallback:"missing") == "Studio Right", "alias survives new store")
        store.setDisabled(uuid:"right",disabled:true)
        check(PreferencesStore(suiteName:suite).disabledUUIDs.contains("right"), "disabled state survives store restart")
        store.setShortcut(ShortcutSpec(modifiers:[.control,.option],key:"r"),for:"right")
        check(PreferencesStore(suiteName:suite).shortcut(for:"right")?.key == "r", "shortcut survives new store")
        UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)
        print("Blackout core tests: PASS (\(checks) assertions)")
    }
}
