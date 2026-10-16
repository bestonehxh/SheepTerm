#if DEBUG
import AppKit
import SwiftUI

/// DEBUG builds only: `SHEEPTERM_AI_DEMO=conversation|chip|settings` sets the
/// AI panel up for a screenshot (with `SHEEPTERM_AI_BIN_DIR=Tests/fakecli`,
/// an isolated HOME and `SHEEPTERM_AI_DEMO_FILE` = a sample device output).
/// A local tab in the scratch HOME `cat`s the sample; nothing else is sent.
@MainActor
enum AIPanelDemo {
    static var mode: String? { ProcessInfo.processInfo.environment["SHEEPTERM_AI_DEMO"] }

    static func runIfRequested(_ ai: AIPanelModel) {
        guard let mode else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if mode == "settings" {
                NSApp.activate()
                if let menu = NSApp.mainMenu?.items.first?.submenu,
                   let index = menu.items.firstIndex(where: { $0.title.hasPrefix("Settings") }) {
                    menu.performActionForItem(at: index)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    for window in NSApp.windows {
                        guard let item = window.toolbar?.items.first(where: { $0.label == "AI" }),
                              let action = item.action else { continue }
                        NSApp.sendAction(action, to: item.target, from: item)
                    }
                }
                return
            }
            AIPanelChrome.shared.shown = true
            AppModel.shared.newLocalTab()
            guard let session = AppModel.shared.selectedID else { return }
            let file = ProcessInfo.processInfo.environment["SHEEPTERM_AI_DEMO_FILE"] ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                AppModel.shared.terminalHost(ofSession: session)?.sendCommand("clear; cat '\(file)'\n")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                ai.attachTail(for: session)
                ai.setDraft("Why is Gi1/0/24 down and how do I bring it back?", for: session)
                if mode == "conversation" || mode == "scroll" { ai.send(for: session) }
            }
            // `scroll`: a long conversation, then the panel off and on again —
            // it must come back at the latest message (5.0 (22)).
            guard mode == "scroll" else { return }
            for turn in 1...5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + Double(turn) * 2.5) {
                    ai.setDraft("Follow-up question \(turn): and what about Gi1/0/\(turn)?", for: session)
                    ai.send(for: session)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 18) { AIPanelChrome.shared.shown = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 19.5) { AIPanelChrome.shared.shown = true }
        }
    }

    /// The chip screenshot starts with the attachment expanded.
    static var chipsStartExpanded: Bool { mode == "chip" }
}
#endif
