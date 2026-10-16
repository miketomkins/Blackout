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
    public func shortcut(for uuid:String) -> ShortcutSpec? {
        guard let s = defaults.dictionary(forKey:"shortcuts")?[uuid] as? String else { return nil }; return ShortcutSpec.parse(s)
    }
    public func setShortcut(_ spec:ShortcutSpec?,for uuid:String) {
        var d = defaults.dictionary(forKey:"shortcuts") as? [String:String] ?? [:]
        d[uuid] = spec?.canonical; defaults.set(d,forKey:"shortcuts"); save()
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
    public func seedDefaults(_ monitors:[MonitorRecord]) {
        let externals = monitors.filter { !$0.isBuiltIn }.sorted { $0.x == $1.x ? $0.uuid < $1.uuid : $0.x < $1.x }
        for (index,m) in externals.enumerated() {
            if allAliases()[m.uuid] == nil {
                setAlias(externals.count == 2 ? (index == 0 ? "Left" : "Right") : "Display \(index+1)",for:m.uuid)
            }
            if shortcut(for:m.uuid) == nil {
                let key = externals.count == 2 ? (index == 0 ? "l" : "r") : String(min(index+1,9))
                setShortcut(ShortcutSpec(modifiers:[.control,.option],key:key),for:m.uuid)
            }
        }
    }
}
