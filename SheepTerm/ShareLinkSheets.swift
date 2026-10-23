import AppKit
import SheepSync
import SwiftUI

/// What the Share Link sheets show while Google or the network is being waited for.
private struct WorkingRow: View {
    let text: String
    let cancel: (() -> Void)?
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12))
            Spacer()
            if let cancel { Button("Cancel", action: cancel) }
        }
    }
}

/// "Sign in with Google" row shown by the sheets while Sync has no account (a link needs the Google account Sync uses).
private struct SignInRow: View {
    let engine = SheepTermSync.shared.engine
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            if engine.phase == .signingIn {
                ProgressView().controlSize(.small)
                Text("Finish signing in in your browser…").font(.system(size: 12))
                Spacer()
                Button("Cancel") { engine.cancelSignIn() }
            } else if engine.phase == .notConfigured {
                Text("Sync is not available in this build").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Sign in with Google…") { Task { await engine.signIn() } }
            }
        }
    }
}

private extension Error {
    /// Short, in words; never the raw Swift type.
    var shareMessage: String {
        if let sync = self as? SyncBackendError { return sync.errorDescription ?? String(localized: "Google Drive failed.") }
        return (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}

// MARK: - Share Link…

/// Right-click a group → Share Link…
struct ShareLinkSheet: View {
    let request: ShareLinkRequest
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var links = ShareLinks.shared

    private enum Stage { case form, working, done(ShareRecord, SharedLink) }
    @State private var stage = Stage.form
    @State private var recipients = ""
    @State private var includeCredentials = false
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var lifetime = ShareLifetime.week
    @State private var error: String?
    @State private var copied = false
    @State private var task: Task<Void, Never>?
    private let engine = SheepTermSync.shared.engine

    private var group: HostGroup? { model.store.groups.first { $0.id == request.groupID } }
    private var logins: Int { group.map { links.loginCount(in: $0) } ?? 0 }

    private var recipientsValid: Bool { (try? ShareRecipients.parse([recipients], excluding: engine.account)) != nil }
    private var passphraseValid: Bool {
        passphrase.count >= ShareService.minimumPassphraseLength && passphrase == confirmation
    }
    private var canCreate: Bool { links.isSignedIn && recipientsValid && passphraseValid && group != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share \u{201C}\(group?.name ?? "—")\u{201D} as a Link").font(.headline)
            switch stage {
            case .form: form
            case .working: working
            case .done(let record, let link): done(record, link)
            }
        }
        .padding(20)
        .frame(width: 440)
        .sheepSheetChrome()
        .noAutoFill()
        .onExitCommand { close() }
#if DEBUG
        // SHEEPTERM_DEBUG_SHARE_PREFILL="a@x.test,b@x.test;passphrase;day|week|month|never;creds" (scratch runs only)
        .onAppear {
            guard let raw = ProcessInfo.processInfo.environment["SHEEPTERM_DEBUG_SHARE_PREFILL"] else { return }
            let parts = raw.components(separatedBy: ";")
            recipients = parts[0]
            if parts.count > 1 { passphrase = parts[1]; confirmation = parts[1] }
            if parts.count > 3, parts[3] == "creds" { includeCredentials = true }
            if parts.count > 2, let life = ShareLifetime(rawValue: parts[2]) { lifetime = life }
        }
#endif
    }

    @ViewBuilder private var form: some View {
        if !links.isSignedIn {
            SignInRow(text: String(localized: "Links are shared from your Google account."))
        }
        Form {
            TextField("Recipients", text: $recipients, prompt: Text("name@gmail.com, other@gmail.com"))
                .help("Google account addresses, separated by commas. SheepTerm opens the link only when signed in as one of them. The file on your Drive is encrypted; without the passphrase it is unreadable.")
            Toggle("Include credentials", isOn: $includeCredentials)
                .disabled(logins == 0)
                .help(logins == 0
                      ? String(localized: "None of the hosts in this group has a saved credential.")
                      : String(localized: "Sends \(logins) saved logins (username and password) with the group."))
            RevealableSecureField(title: "Share passphrase", text: $passphrase)
                .help("At least \(ShareService.minimumPassphraseLength) characters. The link opens nothing without it. Tell the recipients by another route (phone, LINE) \u{2014} never together with the link.")
            RevealableSecureField(title: "Confirm passphrase", text: $confirmation)
            Picker("Link expires", selection: $lifetime) {
                Text("In 1 day").tag(ShareLifetime.day)
                Text("In 7 days").tag(ShareLifetime.week)
                Text("In 30 days").tag(ShareLifetime.month)
                Text("Never").tag(ShareLifetime.never)
            }
            .help("After this the link stops working and the file is deleted from your Google Drive. Hosts already imported stay with the recipients.")
        }
        .textFieldStyle(.roundedBorder)
        .onSubmit { create() }
        if let note = group.flatMap({ ShareLinkPlan.jumpHostNote(ShareLinkPlan.jumpHostCount($0)) }) {
            // The note is shared with Windows and compared by the harness; said here in words.
            let count = group.map { ShareLinkPlan.jumpHostCount($0) } ?? 0
            Text(String(localized: "\(count) hosts use a jump host — it is not shared."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if let error {
            Text(error).font(.system(size: 11)).foregroundStyle(Theme.destructive).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Spacer()
            Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
            Button("Create Link") { create() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkingRow(text: engine.isAuthorizing ? String(localized: "Allow SheepTerm in your browser\u{2026}") : String(localized: "Creating the link\u{2026}"),
                       cancel: engine.isAuthorizing ? { engine.cancelSignIn() } : nil)
        }
    }

    @ViewBuilder private func done(_ record: ShareRecord, _ link: SharedLink) -> some View {
        Text(link.url)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(4)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
        Text("For \(record.recipients.joined(separator: ", ")) \u{00B7} \(Self.expiryText(record.expires))")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Text("Now send the passphrase another way \u{2014} phone, LINE, in person \u{2014} never in the same message as the link. Anyone with both can open the share.")
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button(copied ? String(localized: "Copied") : String(localized: "Copy Link")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url, forType: .string)
                copied = true
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    static func expiryText(_ date: Date?) -> String {
        guard let date else { return String(localized: "never expires") }
        return String(localized: "expires \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    private func close() {
        task?.cancel()
        if engine.isAuthorizing { engine.cancelSignIn() }
        dismiss()
    }

    private func create() {
        guard canCreate, let group else { return }
        error = nil
        stage = .working
        let (to, withCredentials, secret, life) = (recipients, includeCredentials, passphrase, lifetime)
        task = Task {
            do {
                let made = try await links.createShare(group: group, recipients: to, includeCredentials: withCredentials,
                                                       passphrase: secret, lifetime: life)
                stage = .done(made.record, made.link)
            } catch {
                if (error as? GoogleOAuth.OAuthError) != .cancelled { self.error = error.shareMessage }
                stage = .form
            }
        }
    }
}

// MARK: - Import from Link…

struct ImportLinkSheet: View {
    let request: ImportLinkRequest
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var links = ShareLinks.shared

    /// The preview carries its summary, decoded once when the content arrived — not on every render.
    private enum Stage { case enter, working(String), preview(ShareContent, name: String, hostCount: Int), imported(ShareLinks.Imported) }
    @State private var stage = Stage.enter
    @State private var text = ""
    @State private var passphrase = ""
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    private let engine = SheepTermSync.shared.engine

    private var parsed: SharedLink? { SharedLink.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from Link").font(.headline)
            switch stage {
            case .enter: enter
            case .working(let what): WorkingRow(text: what, cancel: nil)
            case .preview(let content, let name, let hostCount): previewView(content, name: name, hostCount: hostCount)
            case .imported(let done): importedView(done)
            }
        }
        .padding(20)
        .frame(width: 440)
        .sheepSheetChrome()
        .noAutoFill()
        .onExitCommand { close() }
        .onAppear {
            if let link = request.link { text = link }
            else if let clip = NSPasteboard.general.string(forType: .string), SharedLink.parse(clip) != nil { text = clip }
#if DEBUG
            if let p = ProcessInfo.processInfo.environment["SHEEPTERM_DEBUG_IMPORT_PASSPHRASE"] { passphrase = p }
#endif
        }
    }

    @ViewBuilder private var enter: some View {
        if !links.isSignedIn {
            SignInRow(text: String(localized: "Sign in with the Google account the link was made for."))
        }
        TextField("Link", text: $text, prompt: Text("Paste a share link"))
            .textFieldStyle(.roundedBorder)
        if parsed != nil {
            RevealableSecureField(title: "Share passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .help("The sender gives you this separately from the link.")
                .onSubmit { open() }
        }
        if let error {
            Text(error).font(.system(size: 11)).foregroundStyle(Theme.destructive).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Spacer()
            Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
            Button("Open") { open() }
                .keyboardShortcut(.defaultAction)
                .disabled(!links.isSignedIn || parsed == nil || passphrase.isEmpty)
        }
    }

    @ViewBuilder private func previewView(_ content: ShareContent, name: String, hostCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Counted from the decoded group, not the envelope (the envelope is only the sender's claim).
            Text(name).font(.system(size: 14, weight: .semibold))
            Text(content.credentials == nil ? String(localized: "\(hostCount) hosts · credentials not included")
                                            : String(localized: "\(hostCount) hosts · credentials included"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("From \(content.sender)").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
        if let error {
            Text(error).font(.system(size: 11)).foregroundStyle(Theme.destructive).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Spacer()
            Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
            Button("Import") { performImport(content) }.keyboardShortcut(.defaultAction)
        }
    }

    private static func importedText(_ done: ShareLinks.Imported) -> String {
        guard done.loginCount > 0 else { return String(localized: "Imported “\(done.name)” — \(done.hostCount) hosts.") }
        return String(localized: "Imported “\(done.name)” — \(done.hostCount) hosts, \(done.loginCount) credentials.")
    }

    @ViewBuilder private func importedView(_ done: ShareLinks.Imported) -> some View {
        Text(Self.importedText(done))
            .font(.system(size: 12))
        HStack {
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    private func close() {
        task?.cancel()
        dismiss()
    }

    private func open() {
        guard let link = parsed, links.isSignedIn, !passphrase.isEmpty else { return }
        error = nil
        stage = .working(String(localized: "Opening the link\u{2026}"))
        let secret = passphrase
        task = Task {
            do {
                let content = try await links.open(link, passphrase: secret)
                let shown = ShareLinkPlan.previewSummary(document: content.group, envelopeName: content.name,
                                                         envelopeHostCount: content.hostCount)
                stage = .preview(content, name: shown.name, hostCount: shown.hostCount)
            } catch {
                self.error = error.shareMessage
                stage = .enter
            }
        }
    }

    private func performImport(_ content: ShareContent) {
        error = nil
        do { stage = .imported(try links.importShare(content)) } catch { self.error = error.shareMessage }
    }
}

// MARK: - Shared Links…

/// The sender's list: copy a link again, revoke it.
struct SharedLinksSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var links = ShareLinks.shared
    @State private var error: String?
    @State private var busy = false
    @State private var copiedID: String?
    private let engine = SheepTermSync.shared.engine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shared Links").font(.headline)
            if links.records.isEmpty {
                Text("No shared links yet")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 16)
            } else {
                List {
                    ForEach(links.records) { record in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.groupName)
                                Text(record.recipients.joined(separator: ", "))
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                Text(Self.summary(of: record))
                                    .font(.system(size: 10)).foregroundStyle(record.isExpired(at: Date()) ? Theme.warn : .secondary)
                            }
                            Spacer()
                            Button {
                                if links.copyLink(for: record) { copiedID = record.id }
                            } label: {
                                Image(systemName: copiedID == record.id ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            Button { confirmRevoke(record) } label: {
                                Image(systemName: "trash").font(.system(size: 11))
                            }
                            .buttonStyle(.plain).foregroundStyle(Theme.destructive)
                            .disabled(busy)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .frame(height: min(CGFloat(links.records.count) * 54 + 20, 260))
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.destructive).fixedSize(horizontal: false, vertical: true)
            }
            if busy {
                WorkingRow(text: engine.isAuthorizing ? String(localized: "Allow SheepTerm in your browser\u{2026}") : String(localized: "Revoking\u{2026}"),
                           cancel: engine.isAuthorizing ? { engine.cancelSignIn() } : nil)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .sheepSheetChrome()
        .onExitCommand { dismiss() }
        .onAppear { links.refresh() }
    }

    /// "3 hosts · with credentials · expires …" under a record.
    private static func summary(of record: ShareRecord) -> String {
        var parts = [String(localized: "\(record.hostCount) hosts")]
        if record.includesCredentials { parts.append(String(localized: "with credentials")) }
        parts.append(ShareLinkSheet.expiryText(record.expires))
        return parts.joined(separator: " \u{00B7} ")
    }

    private func confirmRevoke(_ record: ShareRecord) {
        // Deferred a turn, like every sheet-side alert.
        DispatchQueue.main.async {
            let alert = SheepAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Revoke the link to \u{201C}\(record.groupName)\u{201D}?")
            alert.informativeText = String(localized: "The recipients lose access right away. Hosts and credentials they have already imported stay on their Macs \u{2014} revoking cannot take those back.")
            let revoke = alert.addButton(withTitle: String(localized: "Revoke"))
            let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
            revoke.hasDestructiveAction = true
            revoke.keyEquivalent = ""
            cancel.keyEquivalent = "\r"
            guard alert.sheepStyled().runModal() == .alertFirstButtonReturn else { return }
            error = nil
            busy = true
            Task {
                do { try await links.revoke(record) } catch {
                    if (error as? GoogleOAuth.OAuthError) != .cancelled { self.error = error.shareMessage }
                }
                busy = false
            }
        }
    }
}
