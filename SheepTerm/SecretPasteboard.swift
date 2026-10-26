import AppKit

/// A password on the clipboard: marked concealed (clipboard managers and
/// history skip it, nspasteboard.org) and cleared after a minute unless
/// something else was copied meanwhile. The Credentials sheet and the File
/// Server popover's login password both copy through here (review 6.0 (4):
/// the popover used the plain clipboard and never cleared it).
enum SecretPasteboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let clearAfter: TimeInterval = 60

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general, clearAfter: TimeInterval = clearAfter) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: concealedType)
        let count = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) {
            if pasteboard.changeCount == count { pasteboard.clearContents() }
        }
    }
}
