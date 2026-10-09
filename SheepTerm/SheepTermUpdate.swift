import AppKit

// SheepTerm's half of the in-app updater: the ONLY file that ties the generic
// updater in SheepTerm/Update/ to this app (ARCHITECTURE.md "In-app updater"). Another
// Sheep app adopts the updater by copying SheepTerm/Update/ unchanged and
// writing its own version of this file.

extension UpdateConfig {
    /// The public key below is the Ed25519 key whose private half is in the
    /// release Mac's login Keychain (service `signingKeychainService`, account
    /// `ed25519`, made once by Tools/update-keygen.sh). `.ship.conf` carries
    /// the same value as UPDATE_SIGN_PUBLIC_KEY, and `Tests/run.sh tests`
    /// fails when the two differ.
    static let sheepTerm = UpdateConfig(
        appName: "SheepTerm",
        repository: "bestonehxh/SheepTerm",
        tagScheme: .build,
        publicKeyBase64: "Ftlm6zeX2l1PFY2Byuh6n3LxEAmF15K8t7l0zZGKH2E=",
        signingKeychainService: "Bestchaan.SheepTerm.update-signing"
    )
}

@MainActor
enum AppUpdater {
    static let shared = Updater(config: .sheepTerm, hooks: UpdateHooks(
        // The same question ⌘Q asks when SSH/serial sessions are live.
        confirmBeforeQuit: { AppDelegate.askAboutLiveSessions() != .cancel },
        // Already answered: applicationShouldTerminate must not ask again,
        // and still runs `shutdownSessionsForQuit` (QuitLogFlush) as a Quit does.
        prepareForQuit: { AppDelegate.quitAlreadyConfirmed = true },
        presenter: SheepAlertUpdatePresenter()
    ))
}

/// The updater's alerts in the app's centred SheepAlert style.
struct SheepAlertUpdatePresenter: UpdateAlertPresenting {
    func present(title: String, message: String, accessory: NSView?, buttons: [UpdateAlertButton]) -> Int {
        let alert = SheepAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = accessory
        for button in buttons { _ = alert.addButton(withTitle: button.title) }
        let response = alert.sheepStyled().runModal()
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}
