import CoreServices
import Foundation

public enum QuitPolicy {
    /// True when `event` is loginwindow's quit for a logout, restart or shutdown. loginwindow adds a quit reason
    /// (`kAEQuitReason`) to the quit Apple event it sends; a Quit chosen in the app calls `terminate` directly with
    /// no Apple event, and a scripted `quit` carries no reason, so both read as false.
    public static func isSystemQuit(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass),
            event.eventID == AEEventID(kAEQuitApplication)
        else { return false }
        return event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    }
}
