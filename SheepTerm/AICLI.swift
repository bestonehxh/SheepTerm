import Foundation

/// AI panel: how the vendors' own CLIs are invoked and how their output is
/// read. Pure and Foundation only (`sharedSources`): the Mac runner
/// (`AIRunner.swift`) and the Windows one spawn processes with exactly these
/// arguments and feed every stdout line through these parsers.
///
/// The prompt is NEVER an argument (a process listing would show device
/// output): it goes on stdin.

/// One thing a stream line means for the conversation.
public nonisolated enum AIStreamEvent: Equatable, Sendable {
    /// Append to the answer being streamed.
    case delta(String)
    /// A complete message (Codex has no deltas; Claude's final `result` when
    /// no delta arrived).
    case message(String)
    /// The conversation id to resume next turn (Codex `thread_id`).
    case session(String)
    /// The run failed; a short line for the user.
    case failure(String)
    /// Safety check failed — stop the process now.
    case abort(String)
    /// The turn ended normally.
    case done
}

public nonisolated enum AICLI {
    // MARK: Binary resolution

    /// Where each CLI's official installers put it, in the order tried
    /// (before asking the login shell's PATH once).
    public static func candidatePaths(for binary: String, home: String) -> [String] {
        var paths = [
            "\(home)/.local/bin/\(binary)",
            "/opt/homebrew/bin/\(binary)",
            "/usr/local/bin/\(binary)",
            "\(home)/.npm-global/bin/\(binary)",
        ]
        if binary == "claude" { paths.append("\(home)/.claude/local/claude") }
        return paths
    }

    /// The login-shell probe, run once: `command -v <binary>`.
    public static func shellProbeArguments(for binary: String) -> [String] {
        ["-lc", "command -v \(binary)"]
    }

    /// First absolute path in the probe's output.
    public static func parseProbe(_ output: String) -> String? {
        output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("/") }
    }

    // MARK: Environment

    /// The variables that would hand a CLI an API key instead of the user's
    /// subscription login.
    public static let apiKeyVariables = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY"]

    /// The child's environment: API keys removed (the user's subscription
    /// login is the only credential), auto-update off, PATH as given.
    /// The keys are matched case-insensitively: Windows environment names
    /// are (`Openai_Api_Key` IS `OPENAI_API_KEY` to the child there), so
    /// every spelling goes — on the Mac too.
    public static func childEnvironment(_ base: [String: String], provider: AIProvider, path: String?, tmpdir: String?) -> [String: String] {
        let refused = Set(apiKeyVariables)
        var env = base.filter { !refused.contains($0.key.uppercased()) }
        // Set a variable replacing any other spelling of its name: Windows names are case-insensitive, and a `Path`
        // left beside a new `PATH` gave the child two (which one wins is up to the C runtime).
        func set(_ name: String, _ value: String) {
            for key in env.keys where key.uppercased() == name.uppercased() && key != name { env.removeValue(forKey: key) }
            env[name] = value
        }
        if provider == .claude { set("DISABLE_AUTOUPDATER", "1") }
        if let path { set("PATH", path) }
        if let tmpdir { set("TMPDIR", tmpdir) }
        return env
    }

    // MARK: Claude

    public static let claudeModels = ["sonnet", "opus", "haiku"]
    public static let defaultClaudeModel = "sonnet"

    /// `claude -p …`: no tools, no MCP, no slash commands, no customisation,
    /// streamed JSON. `resume` false = first turn (`--session-id`).
    public static func claudeArguments(systemPromptFile: String, model: String, sessionID: String, resume: Bool) -> [String] {
        let alias = claudeModels.contains(model) ? model : defaultClaudeModel
        return [
            "-p", "--safe-mode",
            "--tools", "",
            "--disallowedTools", "*",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--permission-mode", "dontAsk",
            "--system-prompt-file", systemPromptFile,
            "--model", alias,
            "--max-turns", "3",
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            resume ? "--resume" : "--session-id", sessionID,
        ]
    }

    public static let claudeStatusArguments = ["auth", "status"]

    /// `claude auth status` (JSON, exit 0 = logged in). An API-key login is
    /// refused: the panel is for the user's subscription.
    public static func claudeStatus(exitCode: Int32, output: String) -> AIAccountStatus {
        let json = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any]
        let method = json?["authMethod"] as? String
        if let method, method == "api_key" || method == "api_key_helper" { return .apiKey }
        guard exitCode == 0 else { return .signedOut }
        if method == "none" { return .signedOut }
        return .signedIn
    }

    // MARK: Codex

    /// `codex exec …` reading the prompt from stdin (`-`). Later turns:
    /// `codex exec … resume <thread> -`. The exec options go BEFORE `resume`
    /// (they are `exec`'s); one live check pending, see ARCHITECTURE.md.
    public static func codexArguments(threadID: String?) -> [String] {
        var args = ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only",
                    "--ignore-user-config", "--ignore-rules"]
        if let threadID { args += ["resume", threadID] }
        args.append("-")
        return args
    }

    public static let codexStatusArguments = ["login", "status"]

    public static func codexStatus(exitCode: Int32, output: String) -> AIAccountStatus {
        let lower = output.lowercased()
        if lower.contains("api key") { return .apiKey }
        guard exitCode == 0 else { return .signedOut }
        if lower.contains("not logged in") { return .signedOut }
        return .signedIn
    }

    // MARK: Stream parsing

    static func object(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]
    }

    /// Short and single-line, for the panel.
    public static func shortError(_ text: String, limit: Int = 200) -> String {
        let one = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return one.count > limit ? String(one.prefix(limit)) + "…" : one
    }
}

public nonisolated enum AIAccountStatus: Equatable, Sendable {
    case notInstalled
    case signedOut
    case signedIn
    /// Logged in with an API key, which the panel does not use.
    case apiKey
    case unknown(String)
}

/// Claude Code `--output-format stream-json --verbose --include-partial-messages`.
public nonisolated struct ClaudeStreamParser: Sendable {
    public private(set) var sawDelta = false
    public private(set) var finished = false

    public init() {}

    public mutating func consume(_ line: String) -> [AIStreamEvent] {
        guard let obj = AICLI.object(line), let type = obj["type"] as? String else { return [] }
        switch type {
        case "system":
            guard (obj["subtype"] as? String) == "init" else { return [] }
            if let tools = obj["tools"] as? [Any], !tools.isEmpty {
                return [.abort("Claude started with tools enabled — stopped. Update Claude Code and try again.")]
            }
            if let servers = obj["mcp_servers"] as? [Any], !servers.isEmpty {
                return [.abort("Claude started with MCP servers — stopped.")]
            }
            if let source = obj["apiKeySource"] as? String, Self.isAPIKeySource(source) {
                return [.abort("Claude is using an API key, not your Claude account — Settings ▸ AI ▸ Sign In.")]
            }
            return []
        case "stream_event":
            guard let event = obj["event"] as? [String: Any],
                  (event["type"] as? String) == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  (delta["type"] as? String) == "text_delta",
                  let text = delta["text"] as? String else { return [] }
            sawDelta = true
            return [.delta(text)]
        case "result":
            finished = true
            let subtype = obj["subtype"] as? String ?? ""
            let isError = obj["is_error"] as? Bool ?? false
            if isError || subtype.hasPrefix("error") {
                var message = (obj["result"] as? String) ?? ""
                if let errors = obj["errors"] as? [Any], let first = errors.first {
                    message = (first as? String) ?? ((first as? [String: Any])?["message"] as? String) ?? message
                }
                if message.isEmpty { message = subtype.isEmpty ? "Claude returned an error." : "Claude stopped: \(subtype)" }
                return [.failure(AICLI.shortError(message))]
            }
            if !sawDelta, let text = obj["result"] as? String, !text.isEmpty { return [.message(text), .done] }
            return [.done]
        default:
            return []
        }
    }

    /// `apiKeySource` values that mean an API key, not a claude.ai login.
    static func isAPIKeySource(_ source: String) -> Bool {
        let lower = source.lowercased()
        if lower == "none" || lower.isEmpty { return false }
        return lower.contains("api_key") || lower.contains("apikey") || lower.contains("anthropic")
    }
}

/// `codex exec --json` JSONL.
public nonisolated struct CodexStreamParser: Sendable {
    public private(set) var finished = false

    public init() {}

    public mutating func consume(_ line: String) -> [AIStreamEvent] {
        guard let obj = AICLI.object(line), let type = obj["type"] as? String else { return [] }
        switch type {
        case "thread.started":
            if let id = obj["thread_id"] as? String, !id.isEmpty { return [.session(id)] }
            return []
        case "item.completed":
            guard let item = obj["item"] as? [String: Any] else { return [] }
            let kind = (item["type"] as? String) ?? (item["item_type"] as? String) ?? ""
            guard kind == "agent_message" || kind == "assistant_message",
                  let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.message(text)]
        case "turn.completed":
            finished = true
            return [.done]
        case "turn.failed":
            finished = true
            let message = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "ChatGPT returned an error."
            return [.failure(AICLI.shortError(message))]
        case "error":
            let message = (obj["message"] as? String) ?? ((obj["error"] as? [String: Any])?["message"] as? String) ?? "ChatGPT returned an error."
            return [.failure(AICLI.shortError(message))]
        default:
            return []
        }
    }
}

/// The macOS sandbox (`sandbox-exec -p`) Codex runs under. Codex's own
/// read-only sandbox still lets the model READ any file, and device output
/// can carry planted instructions — so file reads are denied everywhere but
/// the system, Codex's own install, CODEX_HOME and the empty work directory.
/// Network stays open (Codex has to reach OpenAI). macOS only; Windows needs
/// its own equivalent (see ARCHITECTURE.md "AI panel").
public nonisolated enum CodexSandbox {
    /// System locations any process needs to start, resolve names and
    /// verify TLS. No user data lives here.
    public static let systemReadPaths = [
        "/System", "/usr", "/bin", "/sbin", "/Library/Apple", "/Library/Preferences",
        "/Library/Keychains", "/Library/Security", "/private/etc", "/private/var/db/timezone",
        "/private/var/db/mds", "/private/var/select", "/dev",
    ]

    /// `/var`, `/tmp`, `/etc` are symlinks into `/private`: resolving a path
    /// through one needs the link's metadata.
    public static let systemSymlinks = ["/var", "/tmp", "/etc"]

    /// The install roots to allow for a binary at `resolved` (symlinks
    /// already resolved): a whole Homebrew prefix (its formulae link each
    /// other's libraries), a `node_modules` tree, or else — an unknown
    /// layout — only the binary's own directory plus `../lib` / `../libexec`
    /// when they exist. Never `/`, `$HOME`, `~/.local`, `~/Library` or any
    /// ancestor of `$HOME`: `~/bin/codex` must not open the whole home.
    public static func installRoots(forResolved resolved: String, home: String = NSHomeDirectory(),
                                    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        for prefix in ["/opt/homebrew", "/usr/local"] where resolved.hasPrefix(prefix + "/") {
            return [prefix]
        }
        if let range = resolved.range(of: "/node_modules/") {
            let root = String(resolved[..<range.upperBound].dropLast())
            if !isForbiddenRoot(root, home: home) { return [root] }
        }
        let dir = (resolved as NSString).deletingLastPathComponent
        let parent = (dir as NSString).deletingLastPathComponent
        // A binary sitting directly in a forbidden directory gets nothing:
        // its siblings would be the home's (or `/Users`') children.
        guard !isForbiddenRoot(dir, home: home) else { return [] }
        var out = [dir]
        for sibling in ["lib", "libexec"] {
            let path = (parent as NSString).appendingPathComponent(sibling)
            if path != dir, exists(path), !isForbiddenRoot(path, home: home) { out.append(path) }
        }
        return out
    }

    /// Too broad to hand a model as a read root.
    public static func isForbiddenRoot(_ path: String, home: String) -> Bool {
        let p = standardised(path), h = standardised(home)
        if p.isEmpty || p == "/" { return true }
        if p == h || h.hasPrefix(p + "/") { return true }   // home or an ancestor of it
        let broad = [".local", "Library", ".config", "Documents", "Desktop", "Downloads"].map { (h as NSString).appendingPathComponent($0) }
        return broad.contains(p)
    }

    static func standardised(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// SBPL string literal.
    static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The profile. `readRoots` = install roots (Codex and, for the npm
    /// package, Node); `writeRoots` = CODEX_HOME, the work dir, the child's
    /// TMPDIR. Everything written is readable too.
    /// Every ancestor directory of `paths`, for `getcwd` (which reads each
    /// parent): those directories only, not what is below them.
    public static func ancestors(of paths: [String]) -> [String] {
        var out: [String] = []
        for path in paths {
            var dir = (path as NSString).deletingLastPathComponent
            while dir != "/" && !dir.isEmpty {
                if !out.contains(dir) { out.append(dir) }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        return out
    }

    /// All paths must already be canonical (`/private/var/…`, not `/var/…`):
    /// the sandbox matches real paths.
    public static func profile(readRoots: [String], writeRoots: [String]) -> String {
        // Not the write roots' ancestors: `file-read*` on (literal "$HOME")
        // would let `ls ~` list the home (CODEX_HOME is ~/.codex). They get
        // metadata only, below — enough for getcwd and path resolution.
        let reads = (systemReadPaths + readRoots + writeRoots).map { "(subpath \(quote($0)))" }
        // Metadata (stat, existence) only along the way to what is readable:
        // the ancestors of every root, as literals — not the whole disk.
        let metaParents = ancestors(of: systemReadPaths + readRoots + writeRoots).filter { dir in
            !(systemReadPaths + readRoots + writeRoots).contains { dir == $0 || dir.hasPrefix($0 + "/") }
        }.map { "(literal \(quote($0)))" } + systemSymlinks.map { "(literal \(quote($0)))" }
        let writes = (["/dev"] + writeRoots).map { "(subpath \(quote($0)))" }
        return """
        (version 1)
        (allow default)
        (deny file-read*)
        (deny file-write*)
        (allow file-read* (literal "/") \(reads.joined(separator: " ")))
        (allow file-read-metadata (literal "/") \(metaParents.joined(separator: " ")))
        (allow file-write* \(writes.joined(separator: " ")))
        (allow network*)
        """
    }
}
