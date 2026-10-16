import AppKit

/// Click, then press the shortcut. Esc cancels; Delete clears it.
final class ShortcutRecorder:NSButton {
    enum Severity { case none, warning, error }
    private(set) var spec:ShortcutSpec?
    private(set) var isRecording = false
    private var hint:String?
    private var severity = Severity.none
    var onChange:((ShortcutRecorder) -> Void)?
    var onRecordingChange:((Bool) -> Void)?

    init(spec:ShortcutSpec?) {
        self.spec = spec
        super.init(frame:.zero)
        bezelStyle = .rounded; setButtonType(.momentaryPushIn)
        target = self; action = #selector(beginRecording)
        refreshTitle()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder:Bool { true }

    func setConflict(_ message:String?,severity:Severity) {
        self.severity = message == nil ? .none : severity
        toolTip = message ?? "Click, then press the shortcut. Esc cancels; Delete clears."
        refreshTitle()
    }

    @objc private func beginRecording() {
        guard !isRecording else { return }
        window?.makeFirstResponder(self)
        isRecording = true; hint = nil; onRecordingChange?(true); refreshTitle()
        NotificationCenter.default.addObserver(self,selector:#selector(windowResignedKey),name:NSWindow.didResignKeyNotification,object:window)
    }
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false; hint = nil
        NotificationCenter.default.removeObserver(self,name:NSWindow.didResignKeyNotification,object:nil)
        onRecordingChange?(false); refreshTitle()
    }
    @objc private func windowResignedKey() { stopRecording() }
    override func resignFirstResponder() -> Bool { stopRecording(); return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow:NSWindow?) { if newWindow == nil { stopRecording() }; super.viewWillMove(toWindow:newWindow) }

    // Command combinations arrive as key equivalents before keyDown.
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with:event) }
        record(event); return true
    }
    override func keyDown(with event:NSEvent) {
        guard isRecording else { return super.keyDown(with:event) }
        record(event)
    }

    private func record(_ event:NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case 53: stopRecording(); return // Esc
        case 51, 117: spec = nil; stopRecording(); onChange?(self); return // Delete, Forward Delete
        default: break
        }
        var mods:ShortcutSpec.Modifiers = []
        if flags.contains(.control) { mods.insert(.control) }; if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.command) { mods.insert(.command) }; if flags.contains(.shift) { mods.insert(.shift) }
        guard ShortcutSpec.keyCodes.values.contains(UInt32(event.keyCode)) else { hint = "Use a letter or digit"; refreshTitle(); NSSound.beep(); return }
        guard let recorded = ShortcutSpec.recorded(keyCode:UInt32(event.keyCode),modifiers:mods) else { hint = "Add ⌃, ⌥ or ⌘"; refreshTitle(); NSSound.beep(); return }
        spec = recorded; stopRecording(); onChange?(self)
    }

    private func refreshTitle() {
        let text:String, color:NSColor
        if isRecording { text = hint ?? "Press shortcut…"; color = hint == nil ? .controlAccentColor : .systemOrange }
        else {
            text = spec?.display ?? "Click to record"
            switch severity {
            case .error: color = .systemRed
            case .warning: color = .systemOrange
            case .none: color = spec == nil ? .secondaryLabelColor : .labelColor
            }
        }
        let prefix = !isRecording && severity != .none ? "⚠︎ " : ""
        attributedTitle = NSAttributedString(string:prefix + text,attributes:[.foregroundColor:color,.font:NSFont.systemFont(ofSize:NSFont.systemFontSize)])
        setAccessibilityValue(isRecording ? "Recording" : (spec?.display ?? "None"))
    }
}
