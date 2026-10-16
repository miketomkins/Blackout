import Foundation

public struct MonitorRecord: Codable, Equatable {
    public let uuid: String
    public var alias: String
    public var x: Int
    public var y: Int
    public var isBuiltIn: Bool
    public var displayID: UInt32
    public var active: Bool
    public init(uuid: String, alias: String, x: Int, isBuiltIn: Bool, displayID: UInt32 = 0, active: Bool = true, y: Int = 0) {
        self.uuid = uuid; self.alias = alias; self.x = x; self.y = y; self.isBuiltIn = isBuiltIn; self.displayID = displayID; self.active = active
    }
}

public enum MonitorPolicy {
    public static func canDisable(target: MonitorRecord, active: [MonitorRecord], disabled: Set<String>) -> Bool {
        guard !target.isBuiltIn, active.contains(where: { $0.uuid == target.uuid && $0.active }) else { return false }
        // Actual OS state wins over a stale saved ownership flag.
        return active.filter { $0.active }.count > 1
    }
    /// Only a monitor that is not online and that Blackout did not disconnect may be forgotten:
    /// an online one would be re-added at once, and a Blackout-disconnected one needs its saved address to come back.
    public static func canForget(uuid:String,online:Set<String>,disabled:Set<String>) -> Bool {
        !online.contains(uuid) && !disabled.contains(uuid)
    }
    /// Only a monitor that is part of the desktop has a screen to outline.
    public static func canIdentify(_ monitor:MonitorRecord,disabled:Set<String>) -> Bool {
        monitor.active && !disabled.contains(monitor.uuid)
    }
}

public struct ShortcutSpec: Codable, Equatable, Hashable {
    public struct Modifiers: OptionSet, Codable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1), option = Modifiers(rawValue: 2), command = Modifiers(rawValue: 4), shift = Modifiers(rawValue: 8)
    }
    public var modifiers: Modifiers
    public var key: String
    public init(modifiers: Modifiers, key: String) { self.modifiers = modifiers; self.key = key.lowercased() }
    public static let keyCodes: [String: UInt32] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46]
    public var keyCode: UInt32? { Self.keyCodes[key] }
    public static func parse(_ text: String) -> ShortcutSpec? {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in:.whitespaces) }
        guard let key = parts.last, keyCodes[key] != nil else { return nil }
        var mods: Modifiers = []
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control": mods.insert(.control)
            case "alt", "option", "opt": mods.insert(.option)
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            default: return nil
            }
        }
        guard !mods.intersection([.control,.option,.command]).isEmpty else { return nil }
        return ShortcutSpec(modifiers:mods,key:key)
    }
    public var canonical: String {
        [modifiers.contains(.control) ? "ctrl" : nil, modifiers.contains(.option) ? "alt" : nil, modifiers.contains(.command) ? "cmd" : nil, modifiers.contains(.shift) ? "shift" : nil, key].compactMap { $0 }.joined(separator:"+")
    }
    public var display: String { [modifiers.contains(.control) ? "⌃" : "", modifiers.contains(.option) ? "⌥" : "", modifiers.contains(.command) ? "⌘" : "", modifiers.contains(.shift) ? "⇧" : "", key.uppercased()].joined() }
    public static func validate(_ specs: [ShortcutSpec]) -> Bool { Set(specs).count == specs.count && specs.allSatisfy { parse($0.canonical) == $0 } }
    public static let reconnectAll = ShortcutSpec(modifiers:[.control,.option],key:"0")
    /// Builds a spec from a recorded key press; nil for keys or modifier sets Blackout cannot register.
    public static func recorded(keyCode:UInt32,modifiers:Modifiers) -> ShortcutSpec? {
        guard let key = keyCodes.first(where: { $0.value == keyCode })?.key else { return nil }
        return parse(ShortcutSpec(modifiers:modifiers,key:key).canonical)
    }
}

public enum ShortcutConflicts {
    /// Standard menu shortcuts found in nearly every Mac app. A global hotkey fires before any app's menu,
    /// so claiming one of these would break it everywhere. Symbolic macOS hotkeys are checked separately.
    public static let standardAppShortcuts:[ShortcutSpec:String] = {
        let cmd:[String:String] = ["a":"Select All","b":"Bold","c":"Copy","f":"Find","g":"Find Next","h":"Hide","i":"Italic","m":"Minimize","n":"New","o":"Open","p":"Print","q":"Quit","s":"Save","t":"New Tab","u":"Underline","v":"Paste","w":"Close Window","x":"Cut","z":"Undo"]
        let cmdShift:[String:String] = ["z":"Redo","s":"Save As","g":"Find Previous","n":"New Folder","t":"Reopen Closed Tab"]
        let cmdOption:[String:String] = ["h":"Hide Others","m":"Minimize All","w":"Close All","v":"Move (Finder)"]
        let ctrlCmd:[String:String] = ["f":"Full Screen","q":"Lock Screen","d":"Look Up"]
        var result:[ShortcutSpec:String] = [:]
        let groups:[(ShortcutSpec.Modifiers,[String:String])] = [([.command],cmd),([.command,.shift],cmdShift),([.command,.option],cmdOption),([.control,.command],ctrlCmd)]
        for (mods,table) in groups {
            for (key,name) in table { result[ShortcutSpec(modifiers:mods,key:key)] = name }
        }
        return result
    }()
    /// Non-blocking caution for Command-only combinations apps commonly use (for example ⌘1 for tabs).
    public static func appWarning(for spec:ShortcutSpec) -> String? {
        guard standardAppShortcuts[spec] == nil, spec.modifiers == .command || spec.modifiers == [.command,.shift] else { return nil }
        return "\(spec.display) is often used by apps; Blackout would take it over in every app."
    }
    /// Maps each conflicting id to a message: duplicates within the set, the reserved Reconnect All key,
    /// or a standard app shortcut such as ⌘C.
    public static func find(_ assignments:[(id:String,name:String,spec:ShortcutSpec?)]) -> [String:String] {
        var result:[String:String] = [:]
        for a in assignments {
            guard let spec = a.spec else { continue }
            if spec == .reconnectAll { result[a.id] = "\(spec.display) is reserved for Reconnect All."; continue }
            if let name = standardAppShortcuts[spec] { result[a.id] = "\(spec.display) is \(name) in most apps; a global shortcut would replace it everywhere."; continue }
            let others = assignments.filter { $0.id != a.id && $0.spec == spec }.map(\.name)
            if !others.isEmpty { result[a.id] = "\(spec.display) is also used by \(others.joined(separator:", "))." }
        }
        return result
    }
}

public final class PreferencesStore {
    public static let suite = "com.miketomkins.Blackout.preferences"
    private let defaults: UserDefaults
    public init(suiteName:String = PreferencesStore.suite) { defaults = UserDefaults(suiteName:suiteName)!; defaults.synchronize() }
    public func reload() { defaults.synchronize() }
    private func save() { defaults.synchronize() }
    public var disabledUUIDs: Set<String> { Set(defaults.stringArray(forKey:"disabledUUIDs") ?? []) }
    public func setDisabled(uuid:String, disabled:Bool) {
        var ids = disabledUUIDs
        if disabled { ids.insert(uuid) } else { ids.remove(uuid) }
        defaults.set(Array(ids).sorted(),forKey:"disabledUUIDs"); save()
    }
    public func alias(for uuid:String,fallback:String) -> String { (defaults.dictionary(forKey:"aliases")?[uuid] as? String) ?? fallback }
    public func setAlias(_ alias:String,for uuid:String) {
        let name = alias.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var d = allAliases(); d[uuid] = String(name.prefix(60)); defaults.set(d,forKey:"aliases"); save()
    }
    public func allAliases() -> [String:String] { defaults.dictionary(forKey:"aliases") as? [String:String] ?? [:] }
    /// True once a shortcut was saved for this monitor, including an explicit "none" (stored as "").
    public func hasShortcutSetting(for uuid:String) -> Bool { defaults.dictionary(forKey:"shortcuts")?[uuid] != nil }
    public func shortcut(for uuid:String) -> ShortcutSpec? {
        guard let s = defaults.dictionary(forKey:"shortcuts")?[uuid] as? String else { return nil }; return ShortcutSpec.parse(s)
    }
    public func setShortcut(_ spec:ShortcutSpec?,for uuid:String) {
        var d = defaults.dictionary(forKey:"shortcuts") as? [String:String] ?? [:]
        d[uuid] = spec?.canonical ?? ""; defaults.set(d,forKey:"shortcuts"); save()
    }
    public var knownMonitors:[MonitorRecord] {
        guard let data = defaults.data(forKey:"knownMonitors") else { return [] }
        return (try? JSONDecoder().decode([MonitorRecord].self,from:data)) ?? []
    }
    public func remember(_ monitors:[MonitorRecord]) {
        var records = Dictionary(uniqueKeysWithValues:knownMonitors.map { ($0.uuid,$0) })
        for m in monitors { records[m.uuid] = m }
        if let data = try? JSONEncoder().encode(Array(records.values).sorted { $0.uuid < $1.uuid }) { defaults.set(data,forKey:"knownMonitors"); save() }
    }
    /// Removes a monitor's saved record, name and shortcut. Check MonitorPolicy.canForget first.
    public func forget(uuid:String) {
        let records = knownMonitors.filter { $0.uuid != uuid }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data,forKey:"knownMonitors") }
        var aliases = allAliases(); aliases[uuid] = nil; defaults.set(aliases,forKey:"aliases")
        var shortcuts = defaults.dictionary(forKey:"shortcuts") as? [String:String] ?? [:]; shortcuts[uuid] = nil; defaults.set(shortcuts,forKey:"shortcuts")
        save()
    }
    public func seedDefaults(_ monitors:[MonitorRecord]) {
        let externals = monitors.filter { !$0.isBuiltIn }.sorted { $0.x == $1.x ? $0.uuid < $1.uuid : $0.x < $1.x }
        // Never hand out a key that is already taken: one duplicate would make the whole set unregistrable.
        var used = Set(externals.compactMap { shortcut(for:$0.uuid) }).union([.reconnectAll])
        for (index,m) in externals.enumerated() {
            if allAliases()[m.uuid] == nil {
                setAlias(externals.count == 2 ? (index == 0 ? "Left" : "Right") : "Display \(index+1)",for:m.uuid)
            }
            if !hasShortcutSetting(for:m.uuid) {
                let preferred = externals.count == 2 ? [index == 0 ? "l" : "r"] : (index < 9 ? [String(index+1)] : [])
                let candidates = (preferred + (1...9).map(String.init)).map { ShortcutSpec(modifiers:[.control,.option],key:$0) }
                if let spec = candidates.first(where: { !used.contains($0) }) { setShortcut(spec,for:m.uuid); used.insert(spec) }
            }
        }
    }
}
