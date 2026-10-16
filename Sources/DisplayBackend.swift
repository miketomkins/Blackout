import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import Darwin

// Private Apple ABI independently verified against displayplacer's Header.h,
// git blob f8bf91b07f795d9fa6ed145bab7511a7c2527b69. Original implementation.
@_silgen_name("CGDisplayCreateUUIDFromDisplayID") private func displayUUID(_ id:CGDirectDisplayID) -> Unmanaged<CFUUID>?
@_silgen_name("CGSConfigureDisplayEnabled") private func configureEnabled(_ config:CGDisplayConfigRef,_ id:CGDirectDisplayID,_ enabled:Bool) -> Int32

public enum BlackoutError: LocalizedError, CustomStringConvertible {
    case unsafe(String), unavailable(String), failed(String)
    public var description:String { switch self { case .unsafe(let s),.unavailable(let s),.failed(let s):return s } }
    public var errorDescription:String? { description }
}

public protocol DisplayHardware {
    func snapshot() throws -> [MonitorRecord]
    func identity(for id:UInt32) -> String?
    func apply(id:UInt32,enabled:Bool) throws
}

public final class NativeDisplayHardware:DisplayHardware {
    public init() {}
    public func identity(for id:UInt32) -> String? {
        guard let uuid = displayUUID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil,uuid) as String?
    }
    public func snapshot() throws -> [MonitorRecord] {
        var ids = [CGDirectDisplayID](repeating:0,count:64); var count:UInt32 = 0
        let error = CGGetOnlineDisplayList(64,&ids,&count)
        guard error == .success else { throw BlackoutError.failed("Cannot read display state (\(error.rawValue)).") }
        return try ids.prefix(Int(count)).map { id in
            guard let uuid = identity(for:id) else { throw BlackoutError.unavailable("A connected monitor has no stable identity. Try again after it wakes.") }
            let b = CGDisplayBounds(id)
            return MonitorRecord(uuid:uuid,alias:"Display",x:Int(b.origin.x),isBuiltIn:CGDisplayIsBuiltin(id) != 0,displayID:id,active:CGDisplayIsActive(id) != 0,y:Int(b.origin.y))
        }
    }
    public func apply(id:UInt32,enabled:Bool) throws {
        var config:CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { throw BlackoutError.failed("Cannot begin display change (\(begin.rawValue)).") }
        let changed = configureEnabled(config,id,enabled)
        guard changed == 0 else { CGCancelDisplayConfiguration(config); throw BlackoutError.failed("macOS refused the display change (\(changed)). The monitor may be unplugged.") }
        let committed = CGCompleteDisplayConfiguration(config,.forSession)
        guard committed == .success else { throw BlackoutError.failed("macOS could not commit the display change (\(committed.rawValue)).") }
    }
}

public final class DisplayBackend {
    private let hardware:DisplayHardware
    private let lockPath:String
    private let settleTimeout:TimeInterval
    public init(hardware:DisplayHardware = NativeDisplayHardware(), lockPath:String? = nil, settleTimeout:TimeInterval = 3) {
        self.hardware = hardware; self.settleTimeout = settleTimeout
        self.lockPath = lockPath ?? (NSHomeDirectory() + "/Library/Application Support/Blackout/display.lock")
    }
    public func enumerate(store:PreferencesStore,remember:Bool = true) throws -> [MonitorRecord] {
        store.reload()
        let live = try hardware.snapshot()
        var known = Dictionary(uniqueKeysWithValues:store.knownMonitors.map { ($0.uuid,$0) })
        for key in Array(known.keys) { known[key]?.active = false }
        for m in live { known[m.uuid] = m }
        var all = Array(known.values).sorted { $0.x == $1.x ? $0.uuid < $1.uuid : $0.x < $1.x }
        if remember { store.seedDefaults(all); store.remember(all) }
        all = all.map { m in var value = m; value.alias = store.alias(for:m.uuid,fallback:m.alias); return value }
        return all
    }
    public func setEnabled(uuid:String,enabled:Bool,store:PreferencesStore) throws { try change(uuid:uuid,desired:enabled,store:store) }
    public func toggle(uuid:String,store:PreferencesStore) throws { try change(uuid:uuid,desired:nil,store:store) }
    private func change(uuid:String,desired:Bool?,store:PreferencesStore) throws {
        try withLock {
            store.reload()
            let live = try hardware.snapshot()
            let current = live.first { $0.uuid == uuid }
            let enabled = desired ?? !(current?.active ?? false)
            guard let target = current ?? store.knownMonitors.first(where: { $0.uuid == uuid }) else {
                throw BlackoutError.unavailable("Monitor is not known. Connect it normally once so Blackout can identify it.")
            }
            guard target.displayID != 0 else { throw BlackoutError.unavailable("No saved display address. Reconnect the monitor normally first.") }
            if enabled, current?.active == true { store.setDisabled(uuid:uuid,disabled:false); return }
            if !enabled {
                guard MonitorPolicy.canDisable(target:target,active:live,disabled:[]) else { throw BlackoutError.unsafe("The last active display must stay on. Built-in displays are also protected.") }
                guard hardware.identity(for:target.displayID) == uuid else { throw BlackoutError.unsafe("Monitor identity changed; nothing was disconnected.") }
            } else {
                // A macOS-disconnected display has no live UUID. Only connect may
                // use its saved runtime ID, never disconnect. Reject recycled IDs.
                if let conflict = live.first(where: { $0.displayID == target.displayID }), conflict.uuid != uuid { throw BlackoutError.unsafe("The monitor address belongs to a different display. Reconnect it normally first.") }
                if let identity = hardware.identity(for:target.displayID), identity != uuid { throw BlackoutError.unsafe("Saved monitor identity no longer matches.") }
            }
            store.remember(live + (current == nil ? [target] : []))
            if !enabled { store.setDisabled(uuid:uuid,disabled:true) }
            do { try hardware.apply(id:target.displayID,enabled:enabled) }
            catch {
                if !enabled, (try? hardware.snapshot().contains(where: { $0.uuid == uuid && $0.active })) == true { store.setDisabled(uuid:uuid,disabled:false) }
                throw error
            }
            let end = Date().addingTimeInterval(settleTimeout)
            var state = try hardware.snapshot()
            while state.contains(where: { $0.uuid == uuid && $0.active }) != enabled, Date() < end {
                Thread.sleep(forTimeInterval:0.08); state = try hardware.snapshot()
            }
            guard state.contains(where: { $0.uuid == uuid && $0.active }) == enabled else { throw BlackoutError.failed("macOS did not confirm the change. Use Reconnect All or reconnect the cable if necessary.") }
            guard state.contains(where: { $0.active }) else { throw BlackoutError.failed("No active display was reported. Reconnect the monitor normally.") }
            store.setDisabled(uuid:uuid,disabled:!enabled)
            store.remember(state)
        }
    }
    private func withLock<T>(_ body:() throws -> T) throws -> T {
        let parent = URL(fileURLWithPath:lockPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd = open(lockPath,O_CREAT | O_RDWR | O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw BlackoutError.failed("Cannot open display-operation lock.") }
        defer { flock(fd,LOCK_UN); close(fd) }
        let end = Date().addingTimeInterval(3)
        while flock(fd,LOCK_EX | LOCK_NB) != 0 {
            guard Date() < end else { throw BlackoutError.failed("Another display operation is busy. Try again.") }
            Thread.sleep(forTimeInterval:0.02)
        }
        return try body()
    }
}
