import SwiftUI

/// Host badges (6.1): one colour per `HostType` — or all grey, Settings ▸
/// Optimization ▸ Host Badges. The sidebar, Home, Quick Search, the Add Host
/// badge menu and the Add Hosts Type column all paint through here.
enum HostBadgeStyle: String, CaseIterable, Identifiable {
    case coloured, grey
    var id: String { rawValue }
    static let key = "hostBadgeStyle"
    static var current: HostBadgeStyle {
        HostBadgeStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .coloured
    }
}

extension Theme {
    static func badgeColor(_ type: HostType?, style: HostBadgeStyle = HostBadgeStyle.current) -> Color {
        guard style == .coloured, let type else { return dimText }
        // One family (6.0 (37), the user: "colours that go together; Cloud
        // sky blue?"): the same pastel weight on the dark sidebar, each hue
        // its own — SSH the app's blue, Cloud a lighter sky, Docker orange,
        // Server mint (This Mac keeps the green), Telnet a quiet slate.
        switch type {
        case .ssh: return accent                                   // 5AA5D6 blue
        case .server: return Color(nsColor: nsColor(0x4FD1B5))     // mint
        case .docker: return Color(nsColor: nsColor(0xF0A05A))     // orange
        case .cloud: return Color(nsColor: nsColor(0x7DD3FC))      // sky
        case .serial: return warn                                  // amber
        case .telnet: return Color(nsColor: nsColor(0xA3AEC2))     // slate
        case .jump: return Color(nsColor: nsColor(0xF08BB4))       // rose
        case .web: return web                                      // lavender
        }
    }

    /// A host's badge colour: its type's, This Mac's green.
    static func badgeColor(for host: Host) -> Color {
        host.kind == .local ? ok : badgeColor(host.hostType)
    }
}

/// The small rounded badge ("SSH") the sidebar draws, as a SwiftUI view.
struct HostTypeBadge: View {
    let type: HostType
    @AppStorage(HostBadgeStyle.key) private var style = HostBadgeStyle.coloured

    var body: some View {
        let color = Theme.badgeColor(type, style: style)
        Text(type.badge)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 32, height: 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.18)))
    }
}

/// The badge with a ▾: picks the type (Add Host, before the name; Add Hosts,
/// the Type column). `types` limits the list (a form without Serial…).
/// A Button that pops an NSMenu, not a SwiftUI Menu: a borderless Menu's
/// label keeps only text and images — the pill was dropped and the chevron
/// drawn large in front (the user, 6.0 (31)).
struct HostTypeMenu: View {
    @Binding var selection: HostType
    var types: [HostType] = HostType.allCases
    @State private var anchor = MenuAnchorBox()

    var body: some View {
        Button {
            let menu = NSMenu()
            for type in types {
                let item = MenuAction(title: Self.label(type)) { selection = type }
                item.state = type == selection ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: (anchor.view?.bounds.height ?? 16) + 4), in: anchor.view)
        } label: {
            HStack(spacing: 2) {
                HostTypeBadge(type: selection)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(box: anchor))
        .fixedSize()
        .help("Type")
        .accessibilityLabel("Type, \(Self.label(selection))")
    }

    static func label(_ type: HostType) -> String {
        switch type {
        case .ssh: return "SSH"
        // "Jump", not "Jump Server" (the user, 6.0 (35): too long for the menu).
        case .jump: return String(localized: "Jump")
        case .telnet: return "Telnet"
        case .serial: return String(localized: "Serial")
        case .web: return "Web"
        case .server: return String(localized: "Server")
        case .docker: return "Docker"
        case .cloud: return String(localized: "Cloud")
        }
    }
}

extension HostType {
    /// Add Host's type tabs (6.1 (10)): SSH, Jump, Telnet, Web — the kinds
    /// of host. No Serial (a console has no Add Host; it is saved from its
    /// tab), no Server / Docker / Cloud (an SSH host's badge, `sshLabels`).
    /// A type whose Feature is off is not offered.
    static func formTypes(jump: Bool) -> [HostType] {
        [.ssh]
            + (jump && OptimizationPlan.Feature.isOn(.jumpServers) ? [.jump] : [])
            + (OptimizationPlan.Feature.isOn(.telnet) ? [.telnet] : [])
            + [.web]
    }

    /// An SSH host's badge menu (Add Host / Edit Host, before the Name):
    /// SSH, Server, Docker, Cloud while Cloud & Docker is on — or while the
    /// host already wears one of them, so it can be taken off.
    static func sshLabels(keeping badge: SSHBadge?) -> [HostType] {
        [.ssh] + (OptimizationPlan.Feature.isOn(.cloudDocker) || badge != nil ? [.server, .docker, .cloud] : [])
    }

    /// Add Hosts' Type column and Home's type filter: every type a GROUP can
    /// hold whose Feature is on. Never Serial — a console is not filed in a
    /// group, it lives in Recent only (the user, 6.0 (42)).
    static var bulkTypes: [HostType] {
        allCases.filter { type in
            switch type {
            case .jump: return OptimizationPlan.Feature.isOn(.jumpServers)
            case .telnet: return OptimizationPlan.Feature.isOn(.telnet)
            case .serial: return false
            case .server, .docker, .cloud: return OptimizationPlan.Feature.isOn(.cloudDocker)
            case .ssh, .web: return true
            }
        }
    }
}

/// Environment (6.0 (30), Optimization ▸ Environment Tags): None, PROD,
/// STAGING or DEV — a tag beside the host, nothing more.
struct EnvironmentRow: View {
    @Binding var environment: HostEnvironment?

    var body: some View {
        FormPopup(selection: $environment,
                  items: [.option(String(localized: "None"), nil)] + HostEnvironment.allCases.map { .option($0.label, $0) })
            .formRow("Environment")
    }
}
