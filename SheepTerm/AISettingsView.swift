import SwiftUI

/// Settings ▸ AI: one row per provider (status + one action), the default
/// provider and each provider's model. Status checks run off the main thread.
struct AISettingsView: View {
    @ObservedObject private var ai = AIPanelModel.shared
    @AppStorage(AIPanelModel.providerKey) private var defaultProvider = AIProvider.claude.rawValue

    var body: some View {
        Form {
            Section {
                ForEach(AIProvider.allCases) { provider in
                    row(provider)
                }
            } header: {
                HStack {
                    Text("Accounts")
                    Spacer()
                    if ai.checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            ai.refreshStatus()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Check again")
                    }
                }
            }
            Section {
                Picker("Default", selection: $defaultProvider) {
                    ForEach(AIProvider.allCases) { Text($0.label).tag($0.rawValue) }
                }
                // The same model choices the chat header offers, per provider.
                ForEach(AIProvider.allCases) { provider in
                    Picker("\(provider.label) model", selection: Binding(get: { ai.model(for: provider) },
                                                                        set: { ai.setModel($0, for: provider) })) {
                        ForEach(AICLI.models(for: provider), id: \.self) {
                            Text(AICLI.modelTitle($0, for: provider)).tag($0)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(4)
        .onAppear { ai.refreshStatus() }
    }

    private func row(_ provider: AIProvider) -> some View {
        let status = ai.status[provider]
        return LabeledContent {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Circle().fill(color(status)).frame(width: 7, height: 7)
                    Text(label(status))
                        .foregroundStyle(.secondary)
                }
                switch status {
                case .notInstalled?:
                    Button("Install…") { ai.openInstallPage(provider) }
                        .help(provider.installPage)
                case .signedOut?, .apiKey?, .unknown?:
                    // "Unknown" is often "installed, not signed in yet" (a
                    // provider whose auth file we cannot read): the one useful
                    // action there is signing in, so offer it.
                    Button("Sign In…") { ai.signIn(provider) }
                        .help(signInHelp(provider))
                case .signedIn?, nil:
                    EmptyView()
                }
            }
        } label: {
            Text(provider.label)
        }
    }

    /// The tooltip for the Sign In button. Gemini has no login subcommand —
    /// the CLI itself opens the Google sign-in flow — so the command shown is
    /// just the binary name.
    private func signInHelp(_ provider: AIProvider) -> String {
        let arguments = provider.loginArguments.joined(separator: " ")
        let command = arguments.isEmpty ? provider.binaryName : "\(provider.binaryName) \(arguments)"
        return String(localized: "Runs `\(command)` in a new terminal tab")
    }

    private func label(_ status: AIAccountStatus?) -> String {
        switch status {
        case nil: return String(localized: "Checking…")
        case .notInstalled?: return String(localized: "Not installed")
        case .signedOut?: return String(localized: "Installed — signed out")
        case .apiKey?: return String(localized: "API key — sign in with your account")
        case .signedIn?: return String(localized: "Signed in")
        case .unknown(let why)?: return String(localized: "Unknown (\(AIFailureText.unknownReason(why)))")
        }
    }

    private func color(_ status: AIAccountStatus?) -> Color {
        switch status {
        case .signedIn?: return Theme.ok
        case .signedOut?, .apiKey?: return Theme.warn
        case .notInstalled?: return Theme.destructive
        default: return Theme.dimText
        }
    }
}
