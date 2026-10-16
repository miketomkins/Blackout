import AppKit
import BlackoutCore

/// Outlines a monitor with a red border and its name, like Displays settings does, so you can tell which row is which.
final class DisplayIdentifier {
    private var panels:[String:NSPanel] = [:]
    private var timers:[String:Timer] = [:]
    private let hardware = NativeDisplayHardware()

    /// Returns false if the monitor isn't on the desktop right now.
    @discardableResult func identify(uuid:String,name:String,duration:TimeInterval = 2) -> Bool {
        // Match by identity rather than a saved display ID, which can change after a disconnect.
        guard let screen = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).flatMap { hardware.identity(for:$0.uint32Value) } == uuid
        }) else { return false }
        timers.removeValue(forKey:uuid)?.invalidate(); panels.removeValue(forKey:uuid)?.orderOut(nil)
        let panel = NSPanel(contentRect:screen.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.ignoresMouseEvents = true
        panel.level = .screenSaver; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        panel.contentView = IdentifyView(name:name); panel.setFrame(screen.frame,display:false)
        panel.alphaValue = 1; panel.orderFrontRegardless(); panels[uuid] = panel
        timers[uuid] = Timer.scheduledTimer(withTimeInterval:duration,repeats:false) { [weak self] _ in self?.fadeOut(uuid) }
        return true
    }
    func dismissAll() { for uuid in Array(panels.keys) { timers.removeValue(forKey:uuid)?.invalidate(); panels.removeValue(forKey:uuid)?.orderOut(nil) } }
    private func fadeOut(_ uuid:String) {
        timers[uuid] = nil
        guard let panel = panels[uuid] else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) { [weak self] in
            // A newer Identify for the same monitor replaces the panel; leave that one alone.
            guard self?.panels[uuid] === panel else { return }
            panel.orderOut(nil); self?.panels[uuid] = nil
        }
    }
}

private final class IdentifyView:NSView {
    let name:String
    init(name:String) { self.name = name; super.init(frame:.zero) }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect:NSRect) {
        let border:CGFloat = 12
        let outline = NSBezierPath(rect:bounds.insetBy(dx:border/2,dy:border/2)); outline.lineWidth = border
        NSColor.systemRed.setStroke(); outline.stroke()
        let attributes:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:48,weight:.semibold),.foregroundColor:NSColor.white]
        let size = (name as NSString).size(withAttributes:attributes)
        let pill = NSRect(x:bounds.midX-size.width/2-32,y:bounds.midY-size.height/2-18,width:size.width+64,height:size.height+36)
        NSColor.systemRed.withAlphaComponent(0.9).setFill(); NSBezierPath(roundedRect:pill,xRadius:18,yRadius:18).fill()
        (name as NSString).draw(at:NSPoint(x:pill.minX+32,y:pill.minY+18),withAttributes:attributes)
    }
}
