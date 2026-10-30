import SwiftUI

/// What's New for 6.0 (14): one page per user-visible change (a picture of
/// the real UI with sample data where it helps, else a symbol per line),
/// then the fixes. 6.0 (14)'s pages are text only (the 6.0 (13) pictures
/// left the asset catalog with their pages). Centred, one fixed picture box so the pages never
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
        Page(image: nil, title: "Ping tab",
             lead: "",
             steps: ["Rows keep the order you type: an address typed between two rows lands there.",
                     "Drag rows to reorder them.",
                     "Right-click an IP ▸ Rename…: a name for this tab only, nothing saved.",
                     "An empty tab shows three chasing dots; the tab icon is three circles."],
             symbols: ["list.bullet.rectangle", "arrow.up.arrow.down", "pencil", "circle.dotted"]),
        Page(image: nil, title: "Console cable",
             lead: "",
             steps: ["Plug in a USB console cable: a card opens at the bottom right.",
                     "Device and cable kind, a speed menu with Other…, and Connect.",
                     "It goes after 15 s, when the cable is pulled, or when a tab opens the port.",
                     "The chip at the end of the tab strip is gone."],
             symbols: ["cable.connector", "chevron.up.chevron.down", "timer", "xmark.circle"]),
        Page(image: nil, title: "Safe Paste",
             lead: "",
             steps: ["Send Line by Line waits until the device is quiet for the delay and its prompt is back.",
                     "A --More-- prompt is answered during the run, after a short pause.",
                     "A device that keeps sending or stays at --More-- ends the run with a notice, not a garbled command."],
             symbols: ["text.line.first.and.arrowtriangle.forward", "return", "exclamationmark.triangle.fill"]),
        Page(image: nil, title: "Fixes",
             lead: "",
             steps: ["Ping: the Rename… popover hangs off the name.",
                     "The console card's 15 s waits while SheepTerm is hidden or its window is in the Dock.",
                     "Click anywhere else to drop a selection.",
                     "Split-pane headers light up under the pointer.",
                     "File Server: a tidier card — the server chips on top, one command box, the interface beside the address."],
             symbols: ["pencil", "timer", "selection.pin.in.out", "menubar.rectangle", "network"]),
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
