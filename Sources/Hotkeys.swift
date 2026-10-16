import AppKit
import Carbon

final class HotkeyManager {
    private var refs:[EventHotKeyRef] = []
    private var handler:EventHandlerRef?
    private var installed:[(UInt32,ShortcutSpec)] = []
    private var reservedRef:EventHotKeyRef?
    private var reserved:ShortcutSpec?
    private(set) var reservedError:String?
    private var handlerStatus:OSStatus = noErr
    var onPress:((UInt32)->Void)?
    var registeredCount:Int { refs.count }
    init() {
        var kind = EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _,event,context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotID = EventHotKeyID()
            let status = GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&hotID)
            guard status == noErr, hotID.signature == OSType(0x424C4B54) else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue().onPress?(hotID.id)
            return noErr
        },1,&kind,Unmanaged.passUnretained(self).toOpaque(),&handler)
    }
    // Registered once and kept outside register(), so a bad per-monitor set can never remove it.
    func reserve(id:UInt32,spec:ShortcutSpec) {
        guard handlerStatus == noErr else { reservedError = "Global shortcut handler failed (\(handlerStatus))."; return }
        let (ref,error) = add(id:id,spec:spec)
        reservedRef = ref; reserved = ref == nil ? nil : spec; reservedError = error
    }
    // Transactional replace: a failed customization retains previous bindings.
    func register(_ specs:[(UInt32,ShortcutSpec)]) -> [String] {
        guard handlerStatus == noErr else { return ["Global shortcut handler failed (\(handlerStatus))."] }
        guard ShortcutSpec.validate(specs.map { $0.1 } + (reserved.map { [$0] } ?? [])) else { return ["Shortcuts must use distinct supported keys with Control, Option, or Command."] }
        let previous = installed
        unregisterKeys()
        let errors = install(specs)
        if errors.isEmpty { installed = specs }
        else { unregisterKeys(); _ = install(previous); installed = previous }
        return errors
    }
    private func install(_ specs:[(UInt32,ShortcutSpec)]) -> [String] {
        var errors:[String] = []
        for (id,spec) in specs {
            let (ref,error) = add(id:id,spec:spec)
            if let ref { refs.append(ref) }
            if let error { errors.append(error) }
        }
        return errors
    }
    private func add(id:UInt32,spec:ShortcutSpec) -> (EventHotKeyRef?,String?) {
        guard let key = spec.keyCode else { return (nil,"Unsupported key: \(spec.key)") }
        var modifiers:UInt32 = 0
        if spec.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        if spec.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if spec.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if spec.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        var ref:EventHotKeyRef?
        let status = RegisterEventHotKey(key,modifiers,EventHotKeyID(signature:OSType(0x424C4B54),id:id),GetApplicationEventTarget(),0,&ref)
        if status == noErr, let ref { return (ref,nil) }
        return (nil,"\(spec.display) is unavailable or used by another app (\(status)). Choose another shortcut.")
    }
    private func unregisterKeys() { refs.forEach { UnregisterEventHotKey($0) }; refs.removeAll() }
    func unregister() {
        unregisterKeys(); installed.removeAll()
        if let reservedRef { UnregisterEventHotKey(reservedRef) }; reservedRef = nil; reserved = nil
    }
    deinit { unregister(); if let handler { RemoveEventHandler(handler) } }
}
