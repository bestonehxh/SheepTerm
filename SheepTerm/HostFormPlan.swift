import Foundation

// The rules Edit Host (`HostEditSheet`) and New SSH / Add Host
// (`QuickConnectSheet`) share for what Save writes — one place, so the two
// doors cannot drift apart again (review 6.1 (62): Edit wrote a dead
// credential id back, saved a password the Agent choice had hidden, and kept
// Save enabled under a red jump-host line; Add did not). Pure, so the harness
// holds both forms to it (Tests/tests/SheetFixTests.swift).

enum HostFormPlan {
    /// The picked credential while it still exists, else nil. What Save
    /// writes, and what the picker is reset to when the credential list
    /// changes under an open form (deleted here or by Sync): a stale id would
    /// render the popup blank and be written straight back, and Sync would
    /// spread it to every Mac. Same rule as `GroupCredentialSheet`.
    static func liveSelection(_ selection: UUID?, in credentials: [Credential]) -> UUID? {
        guard let selection, credentials.contains(where: { $0.id == selection }) else { return nil }
        return selection
    }

    /// Authentication ▸ Key logs in with a credential's key: no Save until
    /// one that exists, and has a key, is picked.
    static func keyBlocksSave(_ method: SSHAuthMethod, selection: UUID?, in credentials: [Credential]) -> Bool {
        guard method == .key else { return false }
        guard let selection, let credential = credentials.first(where: { $0.id == selection }) else { return true }
        return credential.publicKey == nil
    }

    /// A password typed beside "enter manually" becomes a new credential only
    /// while that field is on screen: the method can use a password and no
    /// live credential is picked. Typed, then hidden by switching to Agent
    /// (or Key), it is not saved and not attached.
    static func savesTypedPassword(_ password: String, method: SSHAuthMethod, credentialResolves: Bool) -> Bool {
        !password.isEmpty && !credentialResolves && method.allowsPassword
    }

    /// Any red line under "Via jump host" greys Save out — a dead or looping
    /// saved bastion as well as typed text that does not parse. The error is
    /// `JumpTarget.fieldError`, so what blocks is exactly what is shown.
    static func jumpBlocksSave(fieldError: String?) -> Bool { fieldError != nil }
}
