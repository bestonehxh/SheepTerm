import SwiftUI

/// 6.0's What's New: Open File, Serve File, watching transfers, Ping (each a
/// picture of the real UI with sample data and three or four short steps),
/// then what else is new. Centred, one fixed picture box so the pages never
/// jump (the user, 6.0: clean and balanced). Shown once (`WhatsNewPlan`);
/// closing it records the release.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page: Int = {
        #if DEBUG
        if let p = ProcessInfo.processInfo.environment["SHEEPTERM_DEBUG_WHATSNEW_PAGE"].flatMap(Int.init) { return p }
        #endif
        return 0
    }()

    private struct Page {
        let image: String?
        let title: LocalizedStringKey
        let lead: LocalizedStringKey
        let steps: [LocalizedStringKey]
    }

    private let pages: [Page] = [
        Page(image: "WhatsNewOpenFile", title: "Open File",
             lead: "Files on a device, from any tab.",
             steps: ["＋ or File ▸ Open File…",
                     "Pick SFTP, SCP, FTP or TFTP and type the address.",
                     "On an SSH tab: right-click the tab ▸ Open File."]),
        Page(image: "WhatsNewServeFile", title: "Serve File",
             lead: "A device copies a file from this Mac.",
             steps: ["＋ or File ▸ Serve File…",
                     "Start TFTP, SFTP, SCP or FTP and choose the file.",
                     "Copy the command for your device."]),
        Page(image: "WhatsNewTransfers", title: "Watching transfers",
             lead: "Progress and history, at a glance.",
             steps: ["The server icon, left of the clock.",
                     "Percent and size in the bottom bar.",
                     "Point at a row for details; ⓘ tells why it failed.",
                     "The clock button: every past transfer."]),
        Page(image: "WhatsNewPing", title: "Ping",
             lead: "Many hosts, live, at a glance.",
             steps: ["＋ or File ▸ New Ping Tab",
                     "Add IPs, names or a range like 10.10.1.0/29.",
                     "Split it beside an SSH tab to watch a reload.",
                     "Select a host for its packet log; copy or save it as CSV."]),
        Page(image: nil, title: "Also in 6.0",
             lead: "",
             steps: ["Telnet, and telnet:// links from GNS3 / EVE-NG.",
                     "SSH port forwarding: Local, Remote, SOCKS.",
                     "Connection status: Wool, Packet or Sheep."]),
    ]

    /// Telnet, port forwarding, connection status.
    private static let alsoSymbols = ["network", "arrow.left.arrow.right", "circle.dotted"]
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
                            Image(systemName: Self.alsoSymbols[index % Self.alsoSymbols.count])
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

            // Back · dots · Next — the dots stay centred on every page.
            ZStack {
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle().fill(i == page ? Theme.tabText : Theme.dimText.opacity(0.4)).frame(width: 6, height: 6)
                    }
                }
                HStack {
                    if page > 0 {
                        Button("Back") { page -= 1 }
                            .frame(width: 84, alignment: .leading)
                    } else {
                        Color.clear.frame(width: 84, height: 1)
                    }
                    Spacer()
                    if page < pages.count - 1 {
                        Button("Next") { page += 1 }
                            .keyboardShortcut(.defaultAction)
                            .frame(width: 84, alignment: .trailing)
                    } else {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                            .frame(width: 84, alignment: .trailing)
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
        .onDisappear { UserDefaults.standard.set(WhatsNewPlan.release, forKey: WhatsNewPlan.seenKey) }
    }
}
