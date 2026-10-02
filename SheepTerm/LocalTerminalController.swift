import AppKit
import Foundation
import SheepVTRender

/// Owns one local shell session: the SheepVT view plus the pty-backed process.
/// The view is created once and kept alive for the lifetime of its tab so the
/// scrollback and running programs survive tab switches.
final class LocalTerminalController: NSObject {
    /// The view and its fading scroller. SafePaste is off for a local shell:
    /// it exists for device CLIs, where a multi-line paste is a configuration
    /// change; a shell pastes the way every other macOS terminal does.
    let terminalHost = SessionTerminalHost(safePaste: false)
    var terminalView: TerminalView { terminalHost.terminalView }
    /// Set in `init` — `LocalProcess` needs its delegate, which is `self`.
    private var process: LocalProcess!

    var onTitleChange: ((String) -> Void)?
    var onExit: ((Int32?) -> Void)?

    override init() {
        super.init()
        process = LocalProcess(delegate: self)
        Theme.apply(to: terminalView)
        terminalView.delegate = self
    }

    func start() {
        let shell = Self.userShell()
        let shellName = (shell as NSString).lastPathComponent

        var environment: [String] = []
        var seen = Set<String>()
        for (key, value) in ProcessInfo.processInfo.environment {
            if key == "TERM" || key == "COLORTERM" || key == "TERM_PROGRAM" { continue }
            environment.append("\(key)=\(value)")
            seen.insert(key)
        }
        environment.append("TERM=xterm-256color")
        environment.append("COLORTERM=truecolor")
        // Identifies us as Terminal.app to the stock /etc/zshrc hooks. Those
        // emit OSC 7 cwd reports; nothing reads them since 4.1 (37) — a new
        // local tab starts at home instead of inheriting (AppModel.newLocalTab).
        environment.append("TERM_PROGRAM=Apple_Terminal")
        environment.append("TERM_PROGRAM_VERSION=453")
        if !seen.contains("LANG") { environment.append("LANG=en_US.UTF-8") }

        // Leading dash marks the shell as a login shell, same as Terminal.app.
        let started = process.start(
            executable: shell,
            args: [],
            environment: environment,
            execName: "-\(shellName)",
            cols: terminalView.cols,
            rows: terminalView.rows
        )
        if !started {
            // pty/fd exhaustion or a missing shell: never a silent blank tab.
            terminalView.feed("\r\n\u{1b}[91mcould not start \(shell)\u{1b}[0m\r\n")
            onExit?(nil)
        }
    }

    func detach() {
        // Kill the shell first — closing a tab must not leave an orphaned
        // process holding a pty and eating CPU in the background.
        //
        // `terminate()` reaps the child itself: it leaves the exit source
        // armed, SIGHUPs the whole process group, escalates to SIGKILL after a
        // second and waitpid's from the same path a child that quit on its own
        // takes. 2.x needed a separate zombie reaper here because SwiftTerm's
        // terminate() cancelled its own exit monitor first.
        process.terminate()
        onTitleChange = nil
        onExit = nil
    }

    static func userShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }
}

// The pty's reads and the child's exit both arrive on the main queue, in
// order, so there is nothing left to hop.
extension LocalTerminalController: LocalProcessDelegate {
    func dataReceived(_ process: LocalProcess, bytes: [UInt8]) {
        terminalView.feed(bytes)
    }

    func processTerminated(_ process: LocalProcess, exitCode: Int32?) {
        onExit?(exitCode)
    }
}

extension LocalTerminalController: TerminalViewDelegate {
    func send(_ view: TerminalView, bytes: [UInt8]) {
        process.send(bytes)
    }

    func sizeChanged(_ view: TerminalView, cols: Int, rows: Int) {
        process.resize(cols: cols, rows: rows)
    }

    func titleChanged(_ view: TerminalView, title: String) {
        onTitleChange?(title)
    }

    func bell(_ view: TerminalView) {
        NSSound.beep()
    }

    /// OSC 52: only when the user turned it on in Settings → Clipboard.
    func allowsClipboardWrite(_ view: TerminalView) -> Bool {
        SessionTerminalHost.clipboardWriteAllowed
    }

    /// Said out loud because nothing else on screen changes when the program
    /// sets (or is refused) the clipboard; the host records a write so the
    /// next paste of that text asks first.
    func clipboardWrite(_ view: TerminalView, outcome: ClipboardWriteOutcome) {
        // No printNotice here — a local shell has no notice channel; the same
        // grey line goes straight into the terminal it came from.
        guard let text = terminalHost.clipboardWriteNotice(outcome, source: "program") else { return }
        terminalView.feed("\r\n\u{1b}[90m\(text)\u{1b}[0m\r\n")
    }

    func openLink(_ view: TerminalView, url: String) {
        // ⌘-click on an OSC 8 hyperlink; web links only.
        guard let link = URL(string: url), let scheme = link.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        NSWorkspace.shared.open(link)
    }

    func shouldPaste(_ view: TerminalView, text: String) -> Bool {
        terminalHost.shouldPaste(text)
    }
}
