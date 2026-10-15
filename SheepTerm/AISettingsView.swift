import SwiftUI

/// Settings ▸ AI: one row per provider (status + one button), the default
/// provider and Claude's model. Status checks run off the main thread.
struct AISettingsView: View {
    @ObservedObject private var ai = AIPanelModel.shared
    @AppStorage(AIPanelModel.providerKey) private var defaultProvider = AIProvider.claude.rawValue
    @AppStorage(AIPanelModel.claudeModelKey) private var claudeModel = AICLI.defaultClaudeModel

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
                Picker("Claude model", selection: $claudeModel) {
                    ForEach(AICLI.claudeModels, id: \.self) { Text($0.capitalized).tag($0) }
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
                case .signedOut?, .apiKey?:
                    Button("Sign In…") { ai.signIn(provider) }
                        .help("Runs `\(provider.binaryName) \(provider.loginArguments.joined(separator: " "))` in a new terminal tab")
                case .signedIn?, .unknown?, nil:
                    EmptyView()
                }
            }
        } label: {
            Text(provider.label)
        }
    }

    private func label(_ status: AIAccountStatus?) -> String {
        switch status {
        case nil: return "Checking…"
        case .notInstalled?: return "Not installed"
        case .signedOut?: return "Installed — signed out"
        case .apiKey?: return "API key — sign in with your account"
        case .signedIn?: return "Signed in"
        case .unknown(let why)?: return "Unknown (\(why))"
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
