import AppKit
import SwiftUI
import SystemConfiguration

/// View → Network Info… (5.0 (17)): this Mac's interfaces and ARP table as
/// the APP reads them (`NetworkTables`). Since macOS 27 a local tab of a
/// self-signed app shows 02:00:00:00:00:00 and an empty `arp -an`; this
/// sheet is where the real values are, without touching the shell.
struct NetworkInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var interfaces: [NetworkTables.Interface] = []
    @State private var neighbors: [NetworkTables.Neighbor] = []
    @State private var displayNames: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Network Info")
                .font(.headline)

            Text("Interfaces").font(.subheadline.weight(.semibold))
            Table(interfaces) {
                TableColumn("Interface") { i in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i.name).font(.system(size: 12, design: .monospaced))
                        if let display = displayNames[i.name] {
                            Text(display).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .opacity(i.isUp ? 1 : 0.5)
                }
                .width(min: 110, ideal: 140)
                TableColumn("MAC") { i in mono(i.mac ?? "—") }
                    .width(min: 130, ideal: 140)
                TableColumn("IPv4") { i in mono(i.ipv4.joined(separator: "\n")) }
                    .width(min: 110, ideal: 130)
                TableColumn("IPv6") { i in mono(i.ipv6.joined(separator: "\n")) }
                    .width(min: 200, ideal: 300)
            }
            .contextMenu(forSelectionType: NetworkTables.Interface.ID.self) { ids in
                if let i = interfaces.first(where: { ids.contains($0.id) }) {
                    if let mac = i.mac { Button("Copy MAC") { copy(mac) } }
                    if let ip = i.ipv4.first { Button("Copy IPv4") { copy(ip) } }
                }
            }
            .frame(height: 220)

            Text("ARP").font(.subheadline.weight(.semibold))
            Table(neighbors) {
                TableColumn("IP") { n in mono(n.ip) }
                    .width(min: 110, ideal: 130)
                TableColumn("MAC") { n in mono(n.mac) }
                    .width(min: 130, ideal: 140)
                TableColumn("Interface") { n in mono(n.interfaceCell) }
                    .width(min: 140)
            }
            .contextMenu(forSelectionType: NetworkTables.Neighbor.ID.self) { ids in
                if let n = neighbors.first(where: { ids.contains($0.id) }) {
                    Button("Copy MAC") { copy(n.mac) }
                    Button("Copy IP") { copy(n.ip) }
                }
            }
            .frame(height: 180)

            HStack {
                Button("Refresh") { reload() }
                Button("Copy All") {
                    copy(NetworkTables.report(interfaces: interfaces, neighbors: neighbors))
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 820)
        .sheepSheetChrome()
        .onExitCommand { dismiss() }
        .onAppear { reload() }
    }

    private func mono(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func reload() {
        interfaces = NetworkTables.interfaces()
        neighbors = NetworkTables.arpTable()
        var names: [String: String] = [:]
        for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
               let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                names[bsd] = display
            }
        }
        displayNames = names
    }
}
