import AppKit
import SheepVTRender
import SwiftUI

/// Hosts a session's `SheepVTRender.TerminalView` (local pty, SSH or serial)
/// and keeps it focused while its tab is active.
struct TerminalViewRepresentable: NSViewRepresentable {
    let host: SessionTerminalHost
    let isActive: Bool

    /// The coordinator IS the host, so `dismantleNSView` — which is static —
    /// can still reach it.
    func makeCoordinator() -> SessionTerminalHost { host }

    func makeNSView(context: Context) -> TerminalView {
        host.terminalView
    }

    /// The tab was switched away: only the selected terminal is attached to a
    /// window, and continuing an invisible configuration paste is unsafe.
    /// (2.x cancelled this from the view's own `viewDidMoveToWindow`; the view
    /// is `final` now, and this is the hook SwiftUI gives us for the same
    /// moment — ContentView only ever mounts the selected tab.)
    static func dismantleNSView(_ view: TerminalView, coordinator: SessionTerminalHost) {
        coordinator.cancelSafePaste(reason: .sessionEnded)
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        guard isActive else {
            host.cancelSafePaste(reason: .sessionEnded)
            return
        }
        DispatchQueue.main.async {
            guard let window = view.window, window.firstResponder !== view else { return }
            // A focused text field (sidebar search, sheets) owns an
            // NSTextView field editor — never yank its focus away just
            // because a @Published change re-ran this update.
            guard !(window.firstResponder is NSTextView) else { return }
            // Same for the sidebar outline. It handles Return-to-connect,
            // which was unreachable in practice: any @Published change —
            // and selecting a row causes several — stole focus back here
            // before the key could arrive.
            guard !(window.firstResponder is NSOutlineView) else { return }
            window.makeFirstResponder(view)
        }
    }
}
