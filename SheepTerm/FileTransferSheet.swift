import SwiftUI

/// ＋ / File → Open File…: the Files tab for a device by address,
/// without an SSH tab first. Same door as typing `sftp://…` in the connect
/// box (`Host.parseFilesURL` → `open(host:)` → `openFiles`); the login is
/// asked in the tab when the device wants one.
struct FileTransferSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// The last protocol picked with no SSH tab focused; an SSH tab's own
    /// SFTP start is NOT written back over it (review 6.0).
    @AppStorage("fileTransferProto") private var savedProto = "sftp"
    @State private var proto = "sftp"
    @State private var address = ""
    @State private var port = ""
    @State private var username = ""

    static let protos = ["sftp", "scp", "ftp", "tftp"]

    init() {}

    /// What's New art only: the form shown filled in.
    init(sample address: String, username: String) {
        _address = State(initialValue: address)
        _username = State(initialValue: username)
    }

    /// The focused tab's device when it is an SSH session.
    private var tabHost: Host? {
        guard let tab = model.selectedTab, case .ssh(let controller) = tab.content else { return nil }
        return controller.host
    }

    private var target: Host? {
        FilesPlan.transferURL(proto: proto, address: address, port: port, username: username).flatMap(ConnectParser.parseFilesURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open File").font(.headline)
            HStack {
                Spacer(minLength: 0)
                Picker("", selection: $proto) {
                    ForEach(Self.protos, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer(minLength: 0)
            }
            Form {
                TextField("Host / IP", text: $address, prompt: Text("10.10.1.1"))
                    .formRow("Host / IP")
                TextField("Port", text: $port, prompt: Text(String(FilesPlan.defaultPort(proto))))
                    .formRow("Port")
                if proto != "tftp" {
                    TextField("Username", text: $username, prompt: Text("admin"))
                        .formRow("Username")
                }
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    guard let target else { return }
                    if tabHost == nil { savedProto = proto }
                    dismiss()
                    // The focused SSH tab's own device over SFTP: ride that
                    // session's connection (no second login, jump host OK).
                    if proto == "sftp", let tab = tabHost, target.address == tab.address, target.port == tab.port,
                       target.username.isEmpty || target.username == tab.username {
                        model.openFilesForSelectedTab()
                    } else {
                        model.open(host: target)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(target == nil)
            }
        }
        .padding(20)
        .frame(width: SheetLayout.width)
        .sheepSheetChrome()
        .noAutoFill()
        .onAppear {
            proto = Self.protos.contains(savedProto) ? savedProto : "sftp"
            // Starts on the focused SSH tab's device.
            if let tab = tabHost {
                proto = "sftp"
                address = tab.address
                if tab.port != 22 { port = String(tab.port) }
                username = tab.username
            }
        }
    }
}
