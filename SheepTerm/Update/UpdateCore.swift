import CryptoKit
import Foundation

// The in-app updater's pure half: everything that can be decided without a
// window, a network or a running app — and therefore everything
// `Tests/run.sh tests` checks (Tests/tests/UpdaterTests.swift).
//
// GENERIC on purpose (the Sheep family will share it): nothing in this folder
// names SheepTerm or any of its types. Whatever is app-specific arrives in one
// `UpdateConfig` value, built in the app's own small file
// (SheepTerm/SheepTermUpdate.swift here). No AppKit, so the harness can
// compile it on its own; ARCHITECTURE.md "In-app updater" has the whole design.

/// Everything that makes the updater one app's updater.
nonisolated struct UpdateConfig: Sendable {
    /// How a release tag and its zip are named — `.ship.conf` VERSION_SCHEME.
    enum TagScheme: Sendable {
        /// `v5.0-1`, `App-5.0-1.zip`; marketing version first, then build
        /// (the build resets when the marketing version moves).
        case build
        /// `v3.7`, `App-3.7.zip`; the dotted marketing version orders them.
        case semver
    }

    /// The bundle's name without `.app`, and the zip's prefix.
    var appName: String
    /// `owner/repo` of the PUBLIC repository whose latest Release is the update.
    var repository: String
    var tagScheme: TagScheme
    /// Base64 of the 32-byte raw Ed25519 public key (CryptoKit
    /// `Curve25519.Signing.PublicKey.rawRepresentation`). Its private half
    /// lives only in the release machine's login Keychain under
    /// `signingKeychainService` (documented here, used by Tools/sign-update.swift).
    var publicKeyBase64: String
    var signingKeychainService: String

    var latestReleaseAPI: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }
    var releasesPage: URL {
        URL(string: "https://github.com/\(repository)/releases/latest")!
    }
    var userAgent: String { "\(appName)-Updater" }
}

/// A version as the updater orders it.
nonisolated struct UpdateVersion: Equatable, Sendable, CustomStringConvertible {
    var marketing: String
    /// nil under `.semver`, where the tag carries none.
    var build: Int?

    var description: String { build.map { "\(marketing) (\($0))" } ?? marketing }
}

/// One thing that went wrong, worded for the user.
nonisolated enum UpdateError: Error, Equatable, Sendable {
    case rateLimited
    case noRelease
    case badStatus(Int)
    case unreadableRelease
    case unrecognisedTag(String)
    case missingAsset(String)
    case missingSignature(String)
    case untrustedURL(String)
    case tooLarge(String)
    case badSignature
    case badArchive(String)
    case notInstallable(String)

    var message: String {
        switch self {
        case .rateLimited:
            return "GitHub is limiting update checks from this network for now. Try again in an hour."
        case .noRelease:
            return "No release has been published yet."
        case .badStatus(let code):
            return "GitHub answered with status \(code)."
        case .unreadableRelease:
            return "The release information from GitHub could not be read."
        case .unrecognisedTag(let tag):
            return "The latest release is tagged \"\(tag)\", which is not a version this app understands."
        case .missingAsset(let name):
            return "The latest release has no \(name) to download."
        case .missingSignature(let name):
            return "The latest release has no signature (\(name)), so it cannot be verified. Nothing was installed."
        case .untrustedURL(let url):
            return "The release points somewhere this app does not download from (\(url)). Nothing was installed."
        case .tooLarge(let name):
            return "\(name) is larger than an update can be. Nothing was installed."
        case .badSignature:
            return "The download does not match its signature. It may have been damaged or tampered with, so it was not installed."
        case .badArchive(let why):
            return "The downloaded update is not usable: \(why). Nothing was installed."
        case .notInstallable(let why):
            return why
        }
    }
}

/// A newer release, with the two files the updater would fetch.
nonisolated struct UpdateOffer: Equatable, Sendable {
    var version: UpdateVersion
    var tag: String
    var zipName: String
    var zipURL: URL
    var zipSize: Int
    var signatureURL: URL
    var notes: String
    var page: URL
}

/// What a check should do with the latest release.
nonisolated enum UpdateDecision: Equatable, Sendable {
    case offer
    case upToDate
    /// Newer, but the user said "Skip This Version" to it (or to a later one).
    case skipped
}

/// GitHub's `releases/latest` — only the fields the updater reads.
nonisolated struct GitHubRelease: Decodable, Equatable, Sendable {
    struct Asset: Decodable, Equatable, Sendable {
        var name: String
        var browserDownloadURL: String
        var size: Int
        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }
    var tagName: String
    var htmlURL: String?
    var body: String?
    var draft: Bool?
    var prerelease: Bool?
    var assets: [Asset]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body, draft, prerelease, assets
    }
}

nonisolated enum UpdateCore {
    // MARK: Limits

    /// Delay between launch and the first automatic check: the window is up,
    /// session restore has run, and the request is not in launch's way.
    static let launchDelay: TimeInterval = 5
    /// While the app stays open, the next automatic check is this long after
    /// the previous one.
    static let checkInterval: TimeInterval = 24 * 60 * 60
    /// The largest zip an update may be (the app is ~10 MB).
    static let maxZipBytes = 300 * 1024 * 1024
    /// A base64 Ed25519 signature is 88 characters; anything past this is not one.
    static let maxSignatureBytes = 1024
    static let notesMaxCharacters = 4000
    static let notesMaxLines = 60

    // MARK: UserDefaults keys (the app's own domain, so no prefix is needed)

    static let autoCheckKey = "checkForUpdatesAutomatically"
    static let skippedTagKey = "skippedUpdateTag"

    // MARK: Tags and versions

    /// `v4.2-10` → 5.0 (1) under `.build`; `v3.7` → 3.7 under `.semver`.
    /// Anything else is nil — the updater never guesses at a tag.
    static func parseTag(_ tag: String, scheme: UpdateConfig.TagScheme) -> UpdateVersion? {
        guard tag.hasPrefix("v") else { return nil }
        let rest = tag.dropFirst()
        switch scheme {
        case .build:
            let parts = rest.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, isDotted(String(parts[0])),
                  let build = positiveInt(String(parts[1])) else { return nil }
            return UpdateVersion(marketing: String(parts[0]), build: build)
        case .semver:
            guard isDotted(String(rest)) else { return nil }
            return UpdateVersion(marketing: String(rest), build: nil)
        }
    }

    /// The running app's version from its Info.plist values.
    static func currentVersion(shortVersion: String?, bundleVersion: String?,
                               scheme: UpdateConfig.TagScheme) -> UpdateVersion? {
        guard let shortVersion, isDotted(shortVersion) else { return nil }
        switch scheme {
        case .build:
            guard let bundleVersion, let build = positiveInt(bundleVersion) else { return nil }
            return UpdateVersion(marketing: shortVersion, build: build)
        case .semver:
            return UpdateVersion(marketing: shortVersion, build: bundleVersion.flatMap(positiveInt))
        }
    }

    static func tag(for version: UpdateVersion, scheme: UpdateConfig.TagScheme) -> String {
        switch scheme {
        case .build: return "v\(version.marketing)-\(version.build ?? 0)"
        case .semver: return "v\(version.marketing)"
        }
    }

    static func zipName(for version: UpdateVersion, config: UpdateConfig) -> String {
        switch config.tagScheme {
        case .build: return "\(config.appName)-\(version.marketing)-\(version.build ?? 0).zip"
        case .semver: return "\(config.appName)-\(version.marketing).zip"
        }
    }

    /// Strictly newer. The dotted marketing version decides first, compared
    /// numerically component by component (5.10 > 5.9, 5.0 == 5.0.0); under
    /// `.build` the build number breaks a tie. The build number RESETS when
    /// the marketing version moves (4.2 (9) → 5.0 (1)), so it is never the
    /// ordering key on its own: 5.0 (1) is newer than 4.2 (9), 5.1 (1) than
    /// 5.0 (30), and 4.2 (9) is not newer than 5.0 (1).
    static func isNewer(_ candidate: UpdateVersion, than current: UpdateVersion,
                        scheme: UpdateConfig.TagScheme) -> Bool {
        switch compareDotted(candidate.marketing, current.marketing) {
        case .orderedDescending: return true
        case .orderedAscending: return false
        case .orderedSame:
            switch scheme {
            case .build:
                guard let a = candidate.build, let b = current.build else { return false }
                return a > b
            case .semver:
                return false
            }
        }
    }

    static func compareDotted(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func isDotted(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.count <= 4
            && parts.allSatisfy { !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    private static func positiveInt(_ s: String) -> Int? {
        guard !s.isEmpty, s.count <= 9, s.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(s), n > 0 else { return nil }
        return n
    }

    // MARK: When to check, what to offer

    /// Seconds until the next AUTOMATIC check, or nil for none. Every launch
    /// checks (after `launchDelay`); while the app stays open, the next one is
    /// `checkInterval` after the previous one — measured within this run only,
    /// nothing is carried across launches. Never while one is in flight (the
    /// caller asks again when it finishes). A manual check does not come
    /// through here: it always runs.
    static func nextAutoCheckDelay(enabled: Bool, inFlight: Bool,
                                   lastCheckThisRun: Date?, now: Date) -> TimeInterval? {
        guard enabled, !inFlight else { return nil }
        guard let last = lastCheckThisRun else { return launchDelay }
        let elapsed = now.timeIntervalSince(last)
        // A clock that jumped backwards leaves a future timestamp: check now
        // rather than wait out a day plus the jump.
        if elapsed < 0 { return 0 }
        return max(0, checkInterval - elapsed)
    }

    /// Offer, report up to date, or stay quiet about a skipped version. A
    /// MANUAL check ignores the skip: the user asked.
    static func decide(latest: UpdateVersion, current: UpdateVersion, skippedTag: String?,
                       manual: Bool, scheme: UpdateConfig.TagScheme) -> UpdateDecision {
        guard isNewer(latest, than: current, scheme: scheme) else { return .upToDate }
        if !manual, let skippedTag, let skipped = parseTag(skippedTag, scheme: scheme),
           !isNewer(latest, than: skipped, scheme: scheme) {
            return .skipped
        }
        return .offer
    }

    // MARK: Reading the release

    /// `nil` for a status the release can be read from.
    static func statusError(_ status: Int) -> UpdateError? {
        switch status {
        case 200..<300: return nil
        case 403, 429: return .rateLimited
        case 404: return .noRelease
        default: return .badStatus(status)
        }
    }

    static func decodeRelease(_ data: Data) throws(UpdateError) -> GitHubRelease {
        do { return try JSONDecoder().decode(GitHubRelease.self, from: data) }
        catch { throw .unreadableRelease }
    }

    /// The release's version, or the reason it has none.
    static func version(of release: GitHubRelease, config: UpdateConfig) throws(UpdateError) -> UpdateVersion {
        guard let version = parseTag(release.tagName, scheme: config.tagScheme) else {
            throw .unrecognisedTag(release.tagName)
        }
        return version
    }

    /// The zip and its `.sig`, chosen by EXACT name from the tag — never "the
    /// first .zip" — with download URLs that must stay inside this
    /// repository's releases on github.com over https.
    static func offer(from release: GitHubRelease, config: UpdateConfig) throws(UpdateError) -> UpdateOffer {
        let version = try version(of: release, config: config)
        let zipName = zipName(for: version, config: config)
        let sigName = zipName + ".sig"
        guard let zip = release.assets.first(where: { $0.name == zipName }) else { throw .missingAsset(zipName) }
        guard let sig = release.assets.first(where: { $0.name == sigName }) else { throw .missingSignature(sigName) }
        guard zip.size > 0, zip.size <= maxZipBytes else { throw .tooLarge(zipName) }
        guard sig.size <= maxSignatureBytes else { throw .tooLarge(sigName) }
        guard let zipURL = trustedDownloadURL(zip.browserDownloadURL, config: config) else {
            throw .untrustedURL(zip.browserDownloadURL)
        }
        guard let sigURL = trustedDownloadURL(sig.browserDownloadURL, config: config) else {
            throw .untrustedURL(sig.browserDownloadURL)
        }
        return UpdateOffer(version: version, tag: release.tagName, zipName: zipName, zipURL: zipURL,
                           zipSize: zip.size, signatureURL: sigURL,
                           notes: capNotes(release.body ?? ""),
                           page: releasePage(release.htmlURL, config: config))
    }

    /// `https://github.com/<owner>/<repo>/releases/download/…` and nothing else
    /// (GitHub redirects from there to its CDN; URLSession follows).
    /// Path components are compared, not a string prefix, so
    /// `/owner/repoEvil` cannot pass as `/owner/repo`.
    static func trustedDownloadURL(_ string: String, config: UpdateConfig) -> URL? {
        guard let url = URL(string: string), url.scheme == "https",
              url.host?.lowercased() == "github.com", url.user == nil, url.port == nil
        else { return nil }
        let expected = config.repository.split(separator: "/").map(String.init) + ["releases", "download"]
        let components = Array(url.pathComponents.dropFirst())
        guard components.count > expected.count,
              zip(components, expected).allSatisfy({ $0.lowercased() == $1.lowercased() }),
              !components.contains("..")
        else { return nil }
        return url
    }

    /// The release's own page when it is an https page of this repository,
    /// else the repository's latest-release page. The JSON's `html_url` goes
    /// to NSWorkspace.open, which honours `file://` and custom schemes.
    static func releasePage(_ string: String?, config: UpdateConfig) -> URL {
        guard let string, let url = URL(string: string), url.scheme == "https",
              url.host?.lowercased() == "github.com", url.user == nil
        else { return config.releasesPage }
        let expected = config.repository.split(separator: "/").map(String.init)
        let components = Array(url.pathComponents.dropFirst())
        guard components.count >= expected.count,
              zip(components, expected).allSatisfy({ $0.lowercased() == $1.lowercased() })
        else { return config.releasesPage }
        return url
    }

    /// Release notes as plain text for the alert: the generic install footer
    /// (everything from a line that is exactly `---`) dropped, control
    /// characters other than newline and tab removed, and capped at
    /// `maxLines` lines / `maxCharacters` characters with a marker saying so.
    static func capNotes(_ body: String, maxCharacters: Int = notesMaxCharacters,
                         maxLines: Int = notesMaxLines) -> String {
        var lines: [String] = []
        for raw in body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            lines.append(String(String.UnicodeScalarView(line.unicodeScalars.filter {
                $0 == "\t" || !(CharacterSet.controlCharacters.contains($0))
            })))
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        var truncated = false
        if lines.count > maxLines { lines = Array(lines.prefix(maxLines)); truncated = true }
        var text = lines.joined(separator: "\n")
        if text.count > maxCharacters { text = String(text.prefix(maxCharacters)); truncated = true }
        if truncated { text += "\n… (the full notes are on the release page)" }
        return text
    }

    // MARK: Integrity

    /// Ed25519 over the EXACT zip bytes. `signatureText` is the `.sig` file:
    /// base64 of the raw 64-byte signature, surrounding whitespace allowed.
    /// Anything malformed is simply "not verified".
    static func verifySignature(of data: Data, signatureText: Data, publicKeyBase64: String) -> Bool {
        guard signatureText.count <= maxSignatureBytes,
              let text = String(data: signatureText, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let signature = Data(base64Encoded: text), signature.count == 64,
              let keyData = Data(base64Encoded: publicKeyBase64), keyData.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return key.isValidSignature(signature, for: data)
    }

    /// After `ditto -x -k` into a fresh directory: exactly one entry, and it
    /// is `<appName>.app` — a real directory, not a link — whose Info.plist
    /// names the running app's bundle identifier and the advertised version,
    /// which must be newer than the running one.
    static func inspectExtracted(at dir: URL, config: UpdateConfig, bundleIdentifier: String,
                                 current: UpdateVersion, advertised: UpdateVersion,
                                 fileManager: FileManager = .default) throws(UpdateError) -> URL {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else {
            throw .badArchive("it could not be unpacked")
        }
        let expected = config.appName + ".app"
        guard entries == [expected] else {
            throw .badArchive("expected only \(expected) inside, found \(entries.sorted().prefix(5).joined(separator: ", "))")
        }
        let app = dir.appendingPathComponent(expected, isDirectory: true)
        guard let type = try? fileManager.attributesOfItem(atPath: app.path)[.type] as? FileAttributeType,
              type == .typeDirectory else {
            throw .badArchive("\(expected) is not a folder")
        }
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        else { throw .badArchive("it has no readable Info.plist") }
        guard plist["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw .badArchive("it is a different app (\(plist["CFBundleIdentifier"] as? String ?? "no identifier"))")
        }
        guard let version = currentVersion(shortVersion: plist["CFBundleShortVersionString"] as? String,
                                           bundleVersion: plist["CFBundleVersion"] as? String,
                                           scheme: config.tagScheme)
        else { throw .badArchive("its version cannot be read") }
        guard isNewer(version, than: current, scheme: config.tagScheme) else {
            throw .badArchive("it is \(version), not newer than \(current)")
        }
        var sameAsAdvertised = compareDotted(version.marketing, advertised.marketing) == .orderedSame
        if config.tagScheme == .build { sameAsAdvertised = sameAsAdvertised && version.build == advertised.build }
        guard sameAsAdvertised else {
            throw .badArchive("it is \(version), but the release says \(advertised)")
        }
        guard let exe = plist["CFBundleExecutable"] as? String,
              fileManager.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/\(exe)").path)
        else { throw .badArchive("it has no executable") }
        return app
    }

    // MARK: Installing

    /// Where the update may be installed: the running bundle itself, and only
    /// when it sits in /Applications (directly or in a subfolder) and both it
    /// and its folder are writable — the helper RENAMES the old bundle aside,
    /// which needs the folder. nil means "reveal the verified zip instead".
    static func installTarget(bundleURL: URL, fileManager: FileManager = .default) -> URL? {
        let resolved = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let path = resolved.path
        guard path.hasPrefix("/Applications/"), path.hasSuffix(".app"),
              !path.contains("/AppTranslocation/") else { return nil }
        let parent = resolved.deletingLastPathComponent().path
        guard fileManager.isWritableFile(atPath: parent),
              fileManager.isWritableFile(atPath: path) else { return nil }
        return resolved
    }

    /// Next to the target, on the same volume, so moving it aside is a rename.
    static func backupPath(for target: URL, stamp: String) -> String {
        target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.deletingPathExtension().lastPathComponent)-previous-\(stamp).app").path
    }

    /// The detached /bin/sh helper that swaps the bundle once the app has
    /// exited. Arguments: PID TARGET NEW BACKUP WORKDIR LOG.
    ///   1. waits for PID to exit (up to SHEEP_UPDATE_WAIT_TENTHS × 0.1 s,
    ///      default 30 min — Quit may sit on a log-flush report while the user
    ///      is away; gives up and changes nothing if it never exits);
    ///   2. refuses unless NEW and TARGET are real directories and BACKUP is free;
    ///   3. renames TARGET → BACKUP, then NEW → TARGET;
    ///   4. success: strips com.apple.quarantine, deletes BACKUP and WORKDIR,
    ///      relaunches TARGET;
    ///   5. failure: removes whatever half-copy is at TARGET, renames BACKUP
    ///      back and relaunches the OLD app (exit 70); if even that fails, the
    ///      old bundle is left at BACKUP and the log says so (exit 71).
    /// Every exit after the arguments were accepted (65–70) also deletes
    /// WORKDIR (zip + extracted app, tens of MB) — except 71, where the new
    /// bundle may be all that is left.
    /// SHEEP_UPDATE_OPEN replaces /usr/bin/open (the harness uses it to see
    /// the relaunch without launching anything). The app starts it with an
    /// explicit, minimal environment.
    static let helperScript = #"""
    #!/bin/sh
    # Sheep updater install helper (generated by UpdateCore.helperScript).
    PID="$1"; TARGET="$2"; NEW="$3"; BACKUP="$4"; WORK="$5"; LOG="${6:-/dev/null}"
    OPEN="${SHEEP_UPDATE_OPEN:-/usr/bin/open}"
    WAIT="${SHEEP_UPDATE_WAIT_TENTHS:-18000}"
    say() { echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }
    drop_work() { case "$WORK" in /?*/?*) /bin/rm -rf "$WORK" ;; esac; }
    case "$PID" in ''|*[!0-9]*) say "bad pid '$PID'"; exit 64;; esac
    for p in "$TARGET" "$NEW" "$BACKUP"; do
      case "$p" in /?*) ;; *) say "not an absolute path: '$p'"; exit 64;; esac
    done
    n=0
    while /bin/kill -0 "$PID" 2>/dev/null; do
      n=$((n + 1))
      if [ "$n" -gt "$WAIT" ]; then say "pid $PID is still running - nothing changed"; drop_work; exit 65; fi
      /bin/sleep 0.1
    done
    if [ ! -d "$NEW" ] || [ -L "$NEW" ]; then say "new bundle missing: $NEW - nothing changed"; drop_work; exit 66; fi
    if [ ! -d "$TARGET" ] || [ -L "$TARGET" ]; then say "target missing: $TARGET - nothing changed"; drop_work; exit 66; fi
    if [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then say "backup path already exists: $BACKUP - nothing changed"; drop_work; exit 67; fi
    if ! /bin/mv "$TARGET" "$BACKUP"; then
      say "could not move the old bundle aside - nothing changed"
      drop_work
      "$OPEN" "$TARGET"
      exit 68
    fi
    if /bin/mv "$NEW" "$TARGET"; then
      /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
      /bin/rm -rf "$BACKUP"
      drop_work
      say "installed $TARGET"
      "$OPEN" "$TARGET"
      exit 0
    fi
    say "moving the new bundle in failed - restoring the old one"
    if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then /bin/rm -rf "$TARGET"; fi
    if /bin/mv "$BACKUP" "$TARGET"; then
      say "restored $TARGET"
      drop_work
      "$OPEN" "$TARGET"
      exit 70
    fi
    say "RESTORE FAILED - the old app is at $BACKUP"
    exit 71
    """#
}
