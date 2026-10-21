import Foundation

/// Local tabs on macOS 27+ (ARCHITECTURE.md §23). macOS 27 hides link-layer addresses and the neighbour tables from
/// every program started inside an app without an Apple Developer ID — `ifconfig` in a local tab printed
/// 02:00:00:00:00:00 and `arp -an` nothing. With the user's consent (Settings ▸ General ▸ Terminal, on by default), a
/// zsh local tab starts with ZDOTDIR pointing at the bundle's `ShellIntegration/zsh`: those files load the user's own
/// dotfiles unchanged and then put `ShellIntegration/bin` (ifconfig, arp, ndp, netstat, networksetup) first in PATH;
/// each wrapper runs the REAL command as a launchd job, where it sees the real values. Nothing is edited in the output.
enum ShellIntegration {
    static let defaultsKey = "localTabRealNetworkInfo"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
    /// Only macOS 27 and later redact, and only for an app without a Developer ID team: a Developer ID build (5.0 (36)
    /// on) keeps the plain shell and hides the switch; a self-signed / ad-hoc build (a public clone, or after the
    /// membership lapses) gets the launchd route back by itself.
    static var isNeeded: Bool {
        isNeeded(osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, teamID: CodeIdentity.ownTeamID)
    }

    static func isNeeded(osMajor: Int, teamID: String?) -> Bool {
        osMajor >= 27 && (teamID ?? "").isEmpty
    }

    /// What a local shell's environment gains, or nil (feature off, not needed, not zsh, files missing).
    /// A user who keeps their dotfiles in their own ZDOTDIR gets it back through SHEEPTERM_USER_ZDOTDIR.
    static func environment(shell: String, base: [String: String], resources: URL?, enabled: Bool, needed: Bool,
                            fileExists: (String) -> Bool) -> [String: String]? {
        guard enabled, needed, let resources, (shell as NSString).lastPathComponent == "zsh" else { return nil }
        let dir = resources.appendingPathComponent("ShellIntegration")
        let zdot = dir.appendingPathComponent("zsh").path
        let bin = dir.appendingPathComponent("bin").path
        guard fileExists(zdot + "/.zshenv"), fileExists(bin + "/ifconfig") else { return nil }
        var env = ["ZDOTDIR": zdot, "SHEEPTERM_SHELL_BIN": bin]
        // A ZDOTDIR that is ANOTHER copy's integration dir (SheepTerm started from a tab of a different build) is not
        // the user's: handing it on made the two bundles source each other.
        if let user = base["ZDOTDIR"], !user.isEmpty, user != zdot, !isIntegrationDir(user) {
            env["SHEEPTERM_USER_ZDOTDIR"] = user
        } else if let inherited = base["SHEEPTERM_USER_ZDOTDIR"], !inherited.isEmpty, !isIntegrationDir(inherited) {
            env["SHEEPTERM_USER_ZDOTDIR"] = inherited
        }
        return env
    }

    static func isIntegrationDir(_ path: String) -> Bool {
        (path as NSString).standardizingPath.hasSuffix("/ShellIntegration/zsh")
    }

    /// Integration variables a parent tab may have left in this process's environment; a local shell never inherits
    /// them (they are set again by `environment` when the feature applies).
    static let inheritedKeys = ["SHEEPTERM_USER_ZDOTDIR", "SHEEPTERM_SHELL_BIN"]
}
