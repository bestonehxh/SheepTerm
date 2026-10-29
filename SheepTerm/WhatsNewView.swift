import SwiftUI

/// What's New for 6.0 (13): one page per user-visible change (a picture of
/// the real UI with sample data where it helps, else a symbol per line),
/// then what else is new. Centred, one fixed picture box so the pages never
/// jump. Opens on its own once per release (`WhatsNewPlan`, recorded when
/// SHOWN) and from Help ▸ What's New…; Close / Esc on every page.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page: Int = {
        #if DEBUG
        if let p = ProcessInfo.processInfo.environment["SHEEPTERM_DEBUG_WHATSNEW_PAGE"].flatMap(Int.init) {
            return WhatsNewPlan.debugPage(p, count: WhatsNewView.pageCount)
        }
        #endif
        return 0
    }()

    private struct Page {
        let image: String?
        let title: LocalizedStringKey
        let lead: LocalizedStringKey
        let steps: [LocalizedStringKey]
        /// A page without a picture: one symbol per line.
        var symbols: [String] = []
    }

    private static let pages: [Page] = [
        Page(image: "WhatsNewGroups", title: "Groups inside groups",
             lead: "Folders in folders, three levels deep.",
             steps: ["Right-click a group ▸ New Group…, or drag one group onto another.",
                     "A coloured bar marks each level.",
                     "View ▸ Sidebar ▸ Group Colors turns the bars off."]),
        Page(image: "WhatsNewPanes", title: "Split panes in a grid",
             lead: "Up to 3 × 3, always tidy.",
             steps: ["⌘D splits right, ⇧⌘D splits down.",
                     "Drag a tab, a pane or a host anywhere into a pane: the lit half is where it goes.",
                     "Closing a tab of several panes asks first."]),
        Page(image: "WhatsNewBaud", title: "Wrong console speed",
             lead: "A hint offers the next speed.",
             steps: ["Garbled text: Garbled? Try 115200.",
                     "Three Returns and no answer: No response?",
                     "Try only changes the port's speed — nothing is sent."]),
        Page(image: "WhatsNewFileServer", title: "File Server address",
             lead: "Pick the address your devices reach.",
             steps: ["Click the server icon, left of the clock.",
                     "Automatic, or one network interface.",
                     "TFTP listens on port 69, the one devices expect."]),
        Page(image: nil, title: "Safe Paste",
             lead: "",
             steps: ["Send Line by Line waits for each line to leave a serial line.",
                     "100 ms between lines by default.",
                     "Hidden characters are removed: what you review is what is sent."],
             symbols: ["text.line.first.and.arrowtriangle.forward", "timer", "eye"]),
        Page(image: nil, title: "Also",
             lead: "",
             steps: ["View ▸ Sidebar: Show Sidebar at Launch, Keep Sidebar Open, Group Colors.",
                     "The View menu is grouped: Sidebar, Terminal, Web, AI, Bottom Bar.",
                     "Earlier in 6.0: Open File, Serve File and Ping tabs."],
             symbols: ["sidebar.left", "menubar.rectangle", "clock.arrow.circlepath"]),
    ]

    static var pageCount: Int { pages.count }
    private var pages: [Page] { Self.pages }

    private static let pictureHeight: CGFloat = 250

    var body: some View {
        let current = pages[page]
        VStack(spacing: 0) {
            Text("New in SheepTerm 6.0")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.dimText)
                .padding(.bottom, 14)
            // One box for every page: a picture, or the app icon.
            Group {
                if let image = current.image {
                    Image(image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.chromeLine, lineWidth: 1))
                } else {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 112, height: 112)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.pictureHeight)

            Text(current.title)
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 22)
            if current.image != nil {
                Text(current.lead)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dimText)
                    .padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(current.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .center, spacing: 12) {
                        if current.image == nil {
                            Image(systemName: current.symbols.indices.contains(index) ? current.symbols[index] : "circle")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accent.opacity(0.12)))
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.ok)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Theme.ok.opacity(0.15)))
                        }
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 13))
            .frame(maxWidth: 420, alignment: .leading)
            .padding(.top, 18)

            Spacer(minLength: 0)

            // Close · dots · Back Next — Close (and Esc) on every page, so
            // someone who does not want to read is out from page 1.
            ZStack {
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle().fill(i == page ? Theme.tabText : Theme.dimText.opacity(0.4)).frame(width: 6, height: 6)
                    }
                }
                HStack(spacing: 8) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if page > 0 {
                        Button("Back") { page -= 1 }
                    }
                    if page < pages.count - 1 {
                        Button("Next") { page += 1 }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 32)
        .padding(.top, 22)
        .padding(.bottom, 22)
        .frame(width: 600, height: 600)
        .sheepSheetChrome()
        // Seen when SHOWN: a crash or force-quit never brings it back.
        .onAppear {
            let defaults = UserDefaults.standard
            defaults.set(WhatsNewPlan.seenAfterShowing(defaults.string(forKey: WhatsNewPlan.seenKey)), forKey: WhatsNewPlan.seenKey)
        }
    }
}
