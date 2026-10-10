import AppKit
import Combine
import SheepSync
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Sync. One section whose body follows the engine's phase:
/// sign in → create or unlock the vault → signed in.
struct SyncSettingsSection: View {
    /// False inside the account panel, whose header already names the account.
    var showsAccount = true
    private let engine = SheepTermSync.shared.engine
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var newPassphrase = ""
    @State private var working = false
    @State private var actionError: String?
    /// The phase the action error belongs to. An action can change the
    /// phase AND throw (createVault finds a vault: → needsPassphrase +
    /// "already exists"); the phase change must not wipe that message.
    @State private var actionErrorPhase: SyncPhase?
    @State private var changingPassphrase = false
    @State private var confirmReset = false

    static let minimumPassphrase = 8

    var body: some View {
        Section("Sync") {
            switch engine.phase {
            case .notConfigured:
                LabeledContent("Sync") {
                    Text("Not available in this build").foregroundStyle(.secondary)
                }
            case .signedOut:
                HStack {
                    Button {
                        Task { await engine.signIn() }
                    } label: {
                        Label("Sign in with Google…", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .help("Hosts, groups, snippets, settings and saved passwords follow you to every Mac signed in to the same Google account. Everything is encrypted on this Mac with your sync passphrase before it is uploaded to a hidden SheepTerm folder in your own Google Drive.")
                    Spacer()
                }
            case .signingIn:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…")
                    Spacer()
                    Button("Cancel") { engine.cancelSignIn() }
                }
            case .checkingVault:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking \(engine.account ?? "your Google Drive")…")
                }
            case .needsNewPassphrase:
                accountRow
                RevealableSecureField(title: "Sync passphrase", text: $passphrase)
                    .help("Encrypts everything before it leaves this Mac. Nobody can recover it — not Google, not SheepTerm. You will type it once on each Mac.")
                RevealableSecureField(title: "Confirm passphrase", text: $confirmation)
                HStack {
                    Button("Turn On Sync") { run { try await engine.createVault(passphrase: passphrase) } }
                        .disabled(working || passphrase.count < Self.minimumPassphrase || passphrase != confirmation)
                        .help("At least \(Self.minimumPassphrase) characters.")
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Sign Out") { Task { await engine.signOut() } }
                        .disabled(working)
                }
                if !confirmation.isEmpty, passphrase != confirmation {
                    Text("Passphrases don't match").font(.system(size: 11)).foregroundStyle(.red)
                }
            case .needsPassphrase:
                accountRow
                RevealableSecureField(title: "Sync passphrase", text: $passphrase)
                    .help("The passphrase chosen when sync was turned on on your first Mac. This Mac's current hosts are set aside (like a restore) before the synced ones replace them.")
                HStack {
                    Button("Unlock") { run { try await engine.unlock(passphrase: passphrase) } }
                        .disabled(working || passphrase.isEmpty)
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Forgot Passphrase…") { confirmReset = true }
                        .disabled(working)
                    Button("Sign Out") { Task { await engine.signOut() } }
                        .disabled(working)
                }
            case .ready:
                accountRow
                // The account panel says this under the picture already.
                if showsAccount {
                LabeledContent("Last synced") {
                    HStack(spacing: 6) {
                        if engine.isSyncing { ProgressView().controlSize(.mini) }
                        if let last = engine.lastSync {
                            Text("\(last, style: .relative) ago")
                        } else {
                            Text("Not yet")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                }
                if changingPassphrase {
                    RevealableSecureField(title: "Current passphrase", text: $passphrase)
                    RevealableSecureField(title: "New passphrase", text: $newPassphrase)
                    RevealableSecureField(title: "Confirm new passphrase", text: $confirmation)
                    // Apple's order: trailing, Cancel left of the action;
                    // Return = Change, Esc = Cancel.
                    HStack {
                        Spacer()
                        Button("Cancel") { changingPassphrase = false; clearFields() }
                            .keyboardShortcut(.cancelAction)
                            .disabled(working)
                        Button("Change Passphrase") {
                            run {
                                try await engine.changePassphrase(current: passphrase, new: newPassphrase)
                                changingPassphrase = false
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || passphrase.isEmpty || newPassphrase.count < Self.minimumPassphrase
                                  || newPassphrase != confirmation)
                    }
                    if !confirmation.isEmpty, newPassphrase != confirmation {
                        Text("Passphrases don't match").font(.system(size: 11)).foregroundStyle(.red)
                    }
                } else {
                    // One row. The account card is narrow, so it uses the
                    // short names (the full ones are the tooltips) — the full
                    // names did not fit and were cut to "Change…"/"Reset Sy…".
                    HStack {
                        Button("Sync Now") { Task { await engine.syncNow() } }
                            .disabled(engine.isSyncing)
                        Button {
                            clearFields(); changingPassphrase = true
                        } label: {
                            // The card is narrow: "Passphrase…" (420 pt is what
                            // fits the row uncut), the full words as the tooltip.
                            Text(showsAccount ? "Change Passphrase…" : "Passphrase…")
                        }
                        .help("Change Passphrase…")
                        .accessibilityLabel("Change Passphrase")
                        Spacer()
                        Button(showsAccount ? "Reset Sync…" : "Reset…") { confirmReset = true }
                            .disabled(working || engine.isSyncing)
                            .help("Reset Sync… — delete the synced copy and start again from this Mac")
                        Button("Sign Out") { Task { await engine.signOut() } }
                            .disabled(working)
                            .help("Forgets the Google sign-in and the vault key on this Mac. Your hosts and passwords stay here, and the synced copy stays for your other Macs.")
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let message = actionError ?? engine.lastError {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .noAutoFill()
        .onChange(of: engine.phase) {
            passphrase = ""
            confirmation = ""
            newPassphrase = ""
            changingPassphrase = false
            if actionErrorPhase != engine.phase { actionError = nil }
        }
        .confirmationDialog("Reset sync?", isPresented: $confirmReset) {
            Button("Delete Synced Data", role: .destructive) {
                run { try await engine.resetVault() }
            }
        } message: {
            Text("Deletes the encrypted copy in your Google Drive. This Mac's hosts and passwords are kept and uploaded again under a new passphrase; your other Macs will ask for the new one.")
        }
    }

    @ViewBuilder private var accountRow: some View {
        if showsAccount {
            LabeledContent("Google account") {
                Text(engine.account ?? "—").foregroundStyle(.secondary)
            }
        }
    }

    private func clearFields() {
        passphrase = ""
        confirmation = ""
        newPassphrase = ""
        actionError = nil
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        working = true
        actionError = nil
        Task {
            do { try await action(); clearFields() } catch {
                actionError = Self.describe(error)
                actionErrorPhase = engine.phase
            }
            working = false
        }
    }

    static func describe(_ error: Error) -> String {
        if case VaultCryptoError.wrongPassphrase = error { return "That passphrase does not open this vault." }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// The account control at the left of the sidebar's bottom bar: a "Sign In"
/// button while signed out, the user's round avatar once signed in (Google
/// photo, a figure, or a picture of their own — `SyncAvatar`). A click opens
/// the account card (`AccountCardPanel`) just above it.
struct SyncAccountButton: View {
    private let engine = SheepTermSync.shared.engine
    @ObservedObject private var avatar = SyncAvatar.shared
    /// The button's NSView, so the card can sit exactly above it.
    @State private var anchor = AnchorBox()

    /// A build without the Google secret (a public clone) has no Sync at
    /// all — no button that could only fail.
    var body: some View {
        if engine.phase != .notConfigured { button }
    }

    private var button: some View {
        Button {
            AccountCardPanel.shared.toggle(above: anchor.view)
        } label: {
            if signedIn {
                // The panel's proportions (ring and gap ≈ 1/20 of the
                // picture) at bar size: the picture stays the thing you see.
                SyncAvatarView(size: 18, ring: 1, gap: 1)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            } else {
                HStack(alignment: .center, spacing: 5) {
                    Group {
                        if engine.phase == .signingIn {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 14, weight: .regular))
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text("Sign In")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .fixedSize()
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(helpText)
        .accessibilityLabel(signedIn ? "Sync account" : "Sign in to Sync")
        .accessibilityValue(signedIn ? helpText : "")
        .background(AnchorReader(box: anchor))
        .task(id: engine.accountPicture) { await avatar.fetchGooglePhoto(engine.accountPicture) }
    }

    private var signedIn: Bool {
        switch engine.phase {
        case .notConfigured, .signedOut, .signingIn: return false
        default: return true
        }
    }

    private var helpText: String {
        switch engine.phase {
        case .notConfigured: return "Sync is not available in this build"
        case .signedOut: return "Sign in with Google to sync hosts and passwords across your Macs"
        case .signingIn: return "Signing in…"
        case .checkingVault: return "Sync: checking Google Drive…"
        case .needsNewPassphrase: return "Sync: choose a passphrase to turn it on"
        case .needsPassphrase: return "Sync: enter your passphrase on this Mac"
        case .ready:
            if !engine.isOnline { return "Offline — will sync when the Mac is back online" }
            return "Synced as \(engine.account ?? "Google account")" + (engine.lastError.map { " — \($0)" } ?? "")
        }
    }
}

/// Which picture the account button shows. This Mac only (not synced):
/// "google" (the account photo, the default), "symbol:<SF Symbol>" (one of
/// `figures`), or "file" (a picture the user chose, copied into Application
/// Support as avatar.png).
@MainActor
final class SyncAvatar: ObservableObject {
    static let shared = SyncAvatar()
    static let choiceKey = "syncAvatar"
    /// Whole figures, not just a head: picked from SF Symbols' people set.
    static let figures = [
        "figure.stand", "figure.wave", "figure.walk", "figure.run", "figure.hiking",
        "figure.mind.and.body", "figure.outdoor.cycle", "figure.pool.swim", "figure.climbing",
        "figure.skiing.downhill", "figure.archery", "figure.dance",
    ]

    /// Animal faces on a background that suits each one (emoji, drawn by the
    /// system font). Land first, then water; the sheep leads, it is the
    /// family's animal.
    static let landAnimals: [(String, String)] = [
        ("🐑", "#8FB8DE"), ("🐶", "#E8B77D"), ("🐱", "#F4A259"), ("🐭", "#B8B8C8"), ("🐹", "#F2C57C"),
        ("🐰", "#F7C6D9"), ("🦊", "#5B8E7D"), ("🐻", "#C08552"), ("🐼", "#9BC59D"), ("🐨", "#A7C4BC"),
        ("🐯", "#3E7CB1"), ("🦁", "#E07A5F"), ("🐮", "#9CCC65"), ("🐷", "#F5A6B8"), ("🐸", "#6FB07F"),
        ("🐵", "#D9A066"), ("🐔", "#F6D365"), ("🐧", "#7FA7D9"), ("🦉", "#6D5A72"), ("🦄", "#C9A7EB"),
    ]
    static let seaAnimals: [(String, String)] = [
        ("🐳", "#2E86AB"), ("🐬", "#4FB3D9"), ("🐟", "#3FA7D6"), ("🐠", "#1B998B"), ("🐡", "#59C3C3"),
        ("🦈", "#1D4E89"), ("🐙", "#F28482"), ("🦑", "#E76F51"), ("🦀", "#F4A261"), ("🦞", "#2A9D8F"),
        ("🐢", "#52B788"), ("🦭", "#6C9BCF"), ("🪼", "#7B6CF6"), ("🦦", "#A68A64"), ("🐋", "#3A6EA5"),
        ("🦐", "#48CAE4"),
    ]
    static let animalColors: [String: String] = Dictionary(
        (landAnimals + seaAnimals).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })

    enum Picture { case image(NSImage), symbol(String), emoji(String, Color) }

    @Published private(set) var choice: String
    @Published private(set) var googlePhoto: NSImage?
    @Published private(set) var customPhoto: NSImage?

    private static var googleFile: URL { BackupManager.baseDirectory.appendingPathComponent("avatar-google.png") }
    private static var customFile: URL { BackupManager.baseDirectory.appendingPathComponent("avatar.png") }

    /// The URL the cached Google photo came from: a photo is only shown for
    /// the account (URL) it was downloaded for — never another person's.
    private var googlePhotoURL: String?
    private static let googleURLKey = "syncAvatarGoogleURL"

    private init() {
        choice = UserDefaults.standard.string(forKey: Self.choiceKey) ?? "google"
        googlePhoto = NSImage(contentsOf: Self.googleFile)
        googlePhotoURL = UserDefaults.standard.string(forKey: Self.googleURLKey)
        customPhoto = NSImage(contentsOf: Self.customFile)
    }

    func resolved(google: URL?) -> Picture {
        if choice.hasPrefix("symbol:") { return .symbol(String(choice.dropFirst("symbol:".count))) }
        if choice.hasPrefix("emoji:") {
            let face = String(choice.dropFirst("emoji:".count))
            return .emoji(face, Color(hex: Self.animalColors[face] ?? "#8FB8DE"))
        }
        if choice == "file", let customPhoto { return .image(customPhoto) }
        if let google, google.absoluteString == googlePhotoURL, let googlePhoto { return .image(googlePhoto) }
        return .symbol("person.fill")
    }

    func choose(_ value: String) {
        choice = value
        UserDefaults.standard.set(value, forKey: Self.choiceKey)
    }

    /// Asks for a picture and keeps a 256 px copy (the original file may move).
    /// Non-modal (`begin`): a modal panel run from inside the transient
    /// account popover closed the popover underneath it.
    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.keepCustomPicture(from: url) }
        }
    }

    private func keepCustomPicture(from url: URL) {
        guard let image = NSImage(contentsOf: url), let png = Self.squarePNG(image, side: 256) else { return }
        do {
            try png.write(to: Self.customFile, options: .atomic)
            customPhoto = NSImage(data: png)
            choose("file")
        } catch {
            NSLog("SheepTerm: could not keep the avatar picture: %@", error.localizedDescription)
        }
    }

    /// Sign-out / another account: the old account's face must not stay.
    func forgetGooglePhoto() {
        googlePhoto = nil
        googlePhotoURL = nil
        UserDefaults.standard.removeObject(forKey: Self.googleURLKey)
        try? FileManager.default.removeItem(at: Self.googleFile)
    }

    /// The Google photo, downloaded once per address and kept on disk.
    /// nil (signed out) forgets the cached one.
    static let maxPhotoBytes = 2_000_000

    func fetchGooglePhoto(_ url: URL?) async {
        guard let url else { forgetGooglePhoto(); return }
        guard url.scheme == "https" else { return }
        if googlePhotoURL == url.absoluteString, googlePhoto != nil { return }
        guard let (bytes, response) = try? await URLSession.shared.bytes(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength <= Int64(Self.maxPhotoBytes) else { return }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                // Checked as it arrives, not after: a server that lies about
                // (or omits) the length cannot make us hold more.
                if data.count > Self.maxPhotoBytes { return }
            }
        } catch { return }
        guard let image = NSImage(data: data), let png = Self.squarePNG(image, side: 128) else { return }
        try? png.write(to: Self.googleFile, options: .atomic)
        UserDefaults.standard.set(url.absoluteString, forKey: Self.googleURLKey)
        googlePhotoURL = url.absoluteString
        googlePhoto = NSImage(data: png)
    }

    static func squarePNG(_ image: NSImage, side: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let size = image.size
        let scale = max(CGFloat(side) / max(size.width, 1), CGFloat(side) / max(size.height, 1))
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        image.draw(in: NSRect(x: (CGFloat(side) - drawn.width) / 2, y: (CGFloat(side) - drawn.height) / 2,
                              width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// The account page the avatar opens, laid out like other apps' account
/// cards: the picture (click to change it), who is signed in and how sync is
/// doing, then the Sync controls — Sync Now, passphrase, Reset, Sign Out.
struct SyncAccountPanel: View {
    private let engine = SheepTermSync.shared.engine
    @State private var editingPicture = false

    private var signedIn: Bool {
        switch engine.phase {
        case .notConfigured, .signedOut, .signingIn: return false
        default: return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if engine.phase == .signedOut || engine.phase == .signingIn {
                signInCard
            } else if signedIn {
                VStack(spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: AccountCardPanel.resizeDuration)) { editingPicture.toggle() }
                    } label: {
                        SyncAvatarView(size: 64, ring: 3, gap: 3)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.system(size: 18))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.accentColor)
                            }
                    }
                    .buttonStyle(.plain)
                    .help("Change picture")
                    Text(engine.account ?? "Google account")
                        .font(.system(size: 13, weight: .semibold))
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if editingPicture {
                        SyncAvatarPicker()
                            .padding(.top, 6)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                }
                .padding(.top, 18)
                .padding(.horizontal, 16)
            }
            if signedIn || engine.phase == .notConfigured {
                Form { SyncSettingsSection(showsAccount: false) }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
            }
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Signed out: what Sync is, and one button.
    private var signInCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Sync your hosts")
                .font(.system(size: 14, weight: .semibold))
            Text("Hosts, groups, snippets, settings and passwords on every Mac — encrypted with your passphrase before they leave this one.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if engine.phase == .signingIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").font(.system(size: 12))
                }
                .padding(.top, 4)
                Button("Cancel") { engine.cancelSignIn() }
                    .controlSize(.small)
            } else {
                Button {
                    Task { await engine.signIn() }
                } label: {
                    Text("Sign in with Google")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            }
            if let error = engine.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var status: String {
        switch engine.phase {
        case .ready:
            if !engine.isOnline { return "Offline — will sync when back online" }
            if engine.isSyncing { return "Syncing…" }
            guard let last = engine.lastSync else { return "Sync on" }
            return "Synced " + last.formatted(.relative(presentation: .named))
        case .needsPassphrase: return "Enter your sync passphrase on this Mac"
        case .needsNewPassphrase: return "Choose a passphrase to turn on sync"
        case .checkingVault: return "Checking Google Drive…"
        default: return ""
        }
    }
}

/// Sync's state as the ring around the avatar (5.0 (7)): green = synced,
/// a turning green arc = syncing, orange = needs the user (passphrase, an
/// error), red = offline. No ring = signed out.
enum SyncRingState: Equatable {
    case none, synced, syncing, attention, offline

    @MainActor static func of(_ engine: SyncEngine) -> SyncRingState {
        switch engine.phase {
        case .notConfigured, .signedOut, .signingIn: return .none
        case .checkingVault:
            if !engine.isOnline { return .offline }
            return engine.lastError == nil ? .syncing : .attention
        case .needsPassphrase, .needsNewPassphrase: return engine.isOnline ? .attention : .offline
        case .ready:
            if !engine.isOnline { return .offline }
            if engine.isSyncing { return .syncing }
            return engine.lastError == nil ? .synced : .attention
        }
    }

    var color: Color {
        switch self {
        case .none: return .clear
        case .synced, .syncing: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .attention: return .orange
        case .offline: return Color(red: 0.94, green: 0.27, blue: 0.27)
        }
    }
}

/// The current picture, round, at any size — with the status ring outside
/// it when `ring` > 0. The `gap` of window background between picture and
/// ring keeps a green ring from melting into a frog's green background.
struct SyncAvatarView: View {
    let size: CGFloat
    var ring: CGFloat = 0
    var gap: CGFloat = 0
    @ObservedObject private var avatar = SyncAvatar.shared
    private let engine = SheepTermSync.shared.engine

    var body: some View {
        let state = ring > 0 ? SyncRingState.of(engine) : .none
        let outer = size + 2 * (gap + ring)
        ZStack {
            picture
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            if state == .syncing {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(state.color, style: StrokeStyle(lineWidth: ring, lineCap: .round))
                        .rotationEffect(.degrees(turn * 360))
                }
                .frame(width: outer - ring, height: outer - ring)
            } else if state != .none {
                Circle()
                    .stroke(state.color, lineWidth: ring)
                    .frame(width: outer - ring, height: outer - ring)
            }
        }
        .frame(width: outer, height: outer)
        .animation(.easeOut(duration: 0.2), value: state)
    }

    @ViewBuilder private var picture: some View {
        switch avatar.resolved(google: engine.accountPicture) {
        case .image(let image):
            Image(nsImage: image).resizable().scaledToFill()
        case .symbol(let name):
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.35))
                Image(systemName: name)
                    .font(.system(size: size * 0.55, weight: .medium))
                    .foregroundStyle(.white)
            }
        case .emoji(let face, let background):
            ZStack {
                Circle().fill(background)
                Text(face).font(.system(size: size * 0.62))
            }
        }
    }
}

/// The picture choices: Google photo, whole figures, or a file.
struct SyncAvatarPicker: View {
    @ObservedObject private var avatar = SyncAvatar.shared
    private let engine = SheepTermSync.shared.engine

    var body: some View {
        VStack {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 8), spacing: 8) {
                if engine.accountPicture != nil {
                    cell(selected: avatar.choice == "google", help: "Google account photo") {
                        avatar.choose("google")
                    } content: {
                        if let photo = avatar.googlePhoto {
                            Image(nsImage: photo).resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.crop.circle")
                        }
                    }
                }
                ForEach(SyncAvatar.landAnimals + SyncAvatar.seaAnimals, id: \.0) { face, hex in
                    cell(selected: avatar.choice == "emoji:\(face)", help: nil) {
                        avatar.choose("emoji:\(face)")
                    } content: {
                        ZStack {
                            Circle().fill(Color(hex: hex))
                            Text(face).font(.system(size: 17))
                        }
                    }
                }
                ForEach(SyncAvatar.figures, id: \.self) { name in
                    cell(selected: avatar.choice == "symbol:\(name)", help: nil) {
                        avatar.choose("symbol:\(name)")
                    } content: {
                        ZStack {
                            Circle().fill(Color.accentColor.opacity(0.35))
                            Image(systemName: name).font(.system(size: 14)).foregroundStyle(.white)
                        }
                    }
                }
                cell(selected: avatar.choice == "file", help: "Choose a picture…") {
                    avatar.chooseFile()
                } content: {
                    if let photo = avatar.customPhoto {
                        Image(nsImage: photo).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Circle().fill(Color.secondary.opacity(0.2))
                            Image(systemName: "photo.badge.plus").font(.system(size: 12))
                        }
                    }
                }
            }
        }
    }

    private func cell(selected: Bool, help: String?, action: @escaping () -> Void,
                      @ViewBuilder content: () -> some View) -> some View {
        Button(action: action) {
            content()
                .frame(width: 28, height: 28)
                .clipShape(Circle())
                .overlay(Circle().stroke(selected ? Color.accentColor : .clear, lineWidth: 2).padding(-2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
    }
}

private extension Color {
    /// "#RRGGBB" — only for the avatar backgrounds above.
    init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0x8FB8DE
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}


/// The account card: a borderless panel that rises just above the account
/// button, left edges aligned, no arrow. (A popover was tried first: the
/// button sits at the window's — usually the screen's — left edge, so the
/// popover was pushed against that edge and its arrow either missed the
/// avatar or fell on the rounded corner as a swollen bulge.) Closes on a
/// click elsewhere or Esc; stays open while its own Reset confirmation or
/// the picture chooser is up.
@MainActor
final class AccountCardPanel: NSObject, NSWindowDelegate {
    static let shared = AccountCardPanel()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { close() }
    }

    private var panel: Panel?
    private var monitor: Any?

    /// `SHEEPTERM_CARDLOG=1`: trace open/close/resign to stderr (the way
    /// SHEEPTERM_CLICKLOG traces the sidebar) — for timing bugs nobody can see.
    private static let trace = ProcessInfo.processInfo.environment["SHEEPTERM_CARDLOG"] == "1"
    private func log(_ text: @autoclosure () -> String) {
        if Self.trace { FileHandle.standardError.write(Data("card: \(text())\n".utf8)) }
    }

    func toggle(above anchor: NSView?) {
        log("toggle panel=\(panel != nil) visible=\(panel?.isVisible ?? false) anchor=\(anchor != nil) window=\(anchor?.window != nil)")
        if let panel, panel.isVisible { close(); return }
        show(above: anchor)
    }

    private func show(above anchor: NSView?) {
        guard let anchor, let window = anchor.window else { return }
        let inset: CGFloat = 6
        let margin = AccountCard.margin
        let measure = NSHostingView(rootView: AccountCard(tipX: 0, onHeight: { _ in }))
        measure.layoutSubtreeIfNeeded()
        let cardWidth = measure.fittingSize.width - 2 * margin   // the fitting size includes the margins

        // The window is tall from the start and the card sits at its bottom:
        // the card grows UPWARD inside it (SwiftUI animates that), so the
        // tail never moves and nothing resizes the window mid-animation —
        // resizing it did, frame by frame, and the bottom edge flickered.
        // The empty part above the card is transparent.
        let inWindow = anchor.convert(anchor.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var origin = NSPoint(x: onScreen.minX - inset - margin, y: onScreen.maxY + 1)
        origin.x = min(max(origin.x, visible.minX + 4 - margin), visible.maxX - cardWidth - margin - 4)
        let height = min(Self.maxHeight, visible.maxY - origin.y - 4)
        let size = NSSize(width: cardWidth + 2 * margin, height: height)

        let panel = Panel(contentRect: NSRect(origin: origin, size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false            // the card draws its own
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        // The tail leans to wherever the button's centre falls inside the card.
        let host = NSHostingView(rootView: AccountCard(tipX: onScreen.midX - (origin.x + margin),
                                                       onHeight: { [weak self] in self?.cardHeight = $0 }))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(NSRect(origin: origin, size: size), display: false)

        window.addChildWindow(panel, ordered: .above)
        // Rises from the button: fades in while sliding up a few points.
        let final = panel.frame
        panel.alphaValue = 0
        panel.setFrame(final.offsetBy(dx: 0, dy: -8), display: false)
        panel.makeKeyAndOrderFront(nil)
        log("shown frame=\(final) card=\(cardWidth) key=\(panel.isKeyWindow)")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
        self.panel = panel
        self.anchor = anchor

        // A click anywhere else in the app closes it — including one on the
        // transparent part of this window above the card.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window === panel {
                let point = event.locationInWindow
                let inCard = point.y <= self.cardHeight
                    && point.x >= margin && point.x <= panel.frame.width - margin
                if !inCard { self.close() }
            } else if let anchor = self.anchor, event.window === anchor.window,
                      anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
                // The account button itself: its own action toggles the card
                // closed. Closing here too made that toggle open it again.
            } else if event.window?.sheetParent !== panel, !(event.window is NSOpenPanel) {
                self.close()
            }
            return event
        }
    }

    /// Room for the card at its tallest (the picture picker open).
    static let maxHeight: CGFloat = 760
    static let resizeDuration: Double = 0.22
    /// The card's current height inside the panel, from its own layout.
    private var cardHeight: CGFloat = 0
    private weak var anchor: NSView?

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard let panel else { return }
        log("close")
        self.panel = nil
        // Sinks back into the button: fade out while sliding down a little.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: -6), display: true)
        }, completionHandler: {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        })
    }

    /// The left button is down over the account button right now.
    private func pressIsOnAnchor() -> Bool {
        guard NSEvent.pressedMouseButtons & 1 != 0,
              let anchor, let window = anchor.window else { return false }
        let onScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        return onScreen.contains(NSEvent.mouseLocation)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Not while its own confirmation sheet or the picture chooser holds
        // the key — those are part of using the card.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.log("resignKey key=\(panel.isKeyWindow) app.key=\(String(describing: NSApp.keyWindow)) onAnchor=\(self.pressIsOnAnchor())")
            if panel.isKeyWindow || panel.attachedSheet != nil { return }
            if let key = NSApp.keyWindow, key.sheetParent === panel || key is NSOpenPanel { return }
            if NSApp.isActive, NSApp.keyWindow == nil { return }
            // A press on the account button took the key: its own action
            // (on mouse-up) toggles the card closed. Closing here first made
            // that toggle open it again — the card never closed.
            if self.pressIsOnAnchor() { return }
            self.close()
        }
    }
}

/// The card's look: the account panel on the popover material, rounded,
/// with a tail whose base sits on the straight part of the bottom edge
/// (clear of the corner) and whose tip leans over to the avatar's centre.
private struct AccountCard: View {
    let tipX: CGFloat
    /// The card's height, whenever it changes (for "was that click on it?").
    let onHeight: (CGFloat) -> Void
    static let tail: CGFloat = 9
    /// Room around the card for its shadow.
    static let margin: CGFloat = 18

    var body: some View {
        let shape = CardBubble(tipX: tipX, tail: Self.tail, radius: 14)
        SyncAccountPanel()
            .padding(.bottom, Self.tail)
            .background(.regularMaterial, in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
            .compositingGroup()
            .shadow(color: .black.opacity(0.35), radius: 12, y: 3)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { onHeight($0) }
            .padding(.horizontal, Self.margin)
            // Pinned to the bottom: a taller card grows upward only.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .preferredColorScheme(.dark)
    }
}

/// A rounded rectangle with a slanted tail under it.
nonisolated struct CardBubble: Shape {
    let tipX: CGFloat
    let tail: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tail)
        // The base: just past the corner's curve, 18 pt wide — the tip may
        // lie left of it (the avatar is nearer the edge than the corner).
        let baseLeft = body.minX + radius + 4
        let baseRight = baseLeft + 18
        let tip = CGPoint(x: min(max(rect.minX + 2, tipX), baseRight), y: rect.maxY)
        var path = Path()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        path.addArc(center: CGPoint(x: body.maxX - radius, y: body.minY + radius), radius: radius,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
        path.addArc(center: CGPoint(x: body.maxX - radius, y: body.maxY - radius), radius: radius,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: baseRight, y: body.maxY))
        path.addQuadCurve(to: tip, control: CGPoint(x: baseRight - 6, y: body.maxY + 2))
        path.addQuadCurve(to: CGPoint(x: baseLeft, y: body.maxY), control: CGPoint(x: baseLeft - 1, y: body.maxY + 1))
        path.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
        path.addArc(center: CGPoint(x: body.minX + radius, y: body.maxY - radius), radius: radius,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
        path.addArc(center: CGPoint(x: body.minX + radius, y: body.minY + radius), radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Holds the NSView behind a SwiftUI view (for placing a panel next to it).
final class AnchorBox {
    weak var view: NSView?
}

struct AnchorReader: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}
