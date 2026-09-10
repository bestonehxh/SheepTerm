// SheepVTDemo — a window with a SheepVTRender.TerminalView on a local shell.
// `swift run -c release SheepVTDemo [--shot path.png] [--feed file]`
//   --shot: after 1.5 s capture the window to a PNG (via screencapture) and quit.
//   --feed: feed a file's bytes instead of starting a shell (device log replay).
import AppKit
import SheepVTRender

/// Stand-in for the app's Highlighter: colours a few network keywords so the
/// overlay path can be seen end to end.
final class DemoHighlighter: HighlightProvider {
    let revision: UInt64 = 1
    let words: [(String, UInt32, Bool)] = [("up", 0x7DD98C, true), ("down", 0xED7A7A, true), ("interface", 0x6CA9E0, false),
                                           ("Interface", 0x6CA9E0, false), ("error", 0xED7A7A, true), ("Vlan", 0xE8D06B, false)]
    func spans(in paragraph: [UInt8]) -> [HighlightSpan] {
        var out: [HighlightSpan] = []
        for (word, rgb, bold) in words {
            let w = Array(word.utf8)
            guard paragraph.count >= w.count else { continue }
            var i = 0
            while i + w.count <= paragraph.count {
                if Array(paragraph[i..<i + w.count]) == w,
                   i == 0 || !isWord(paragraph[i - 1]), i + w.count == paragraph.count || !isWord(paragraph[i + w.count]) {
                    out.append(HighlightSpan(range: i..<(i + w.count), rgb: rgb, bold: bold)); i += w.count
                } else { i += 1 }
            }
        }
        return out
    }
    func isWord(_ b: UInt8) -> Bool { (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F }
}

final class Demo: NSObject, NSApplicationDelegate, TerminalViewDelegate, LocalProcessDelegate {
    var window: NSWindow!
    var view: TerminalView!
    var process: LocalProcess?
    let shot = CommandLine.arguments.firstIndex(of: "--shot").map { CommandLine.arguments[$0 + 1] }
    let feedFile = CommandLine.arguments.firstIndex(of: "--feed").map { CommandLine.arguments[$0 + 1] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 100, y: 100, width: 900, height: 560)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "SheepVT demo"
        view = TerminalView(frame: NSRect(origin: .zero, size: frame.size), cols: 80, rows: 24, scrollback: 10_000)
        view.autoresizingMask = [.width, .height]
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        view.delegate = self
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        if let feedFile, CommandLine.arguments.contains("--stream"),
           let data = FileManager.default.contents(atPath: feedFile) {
            // Feed like an SSH session would: 1 KB every 3 ms.
            view.highlightProvider = DemoHighlighter()
            var bytes = [UInt8](data)
            var out = [UInt8](); var prev: UInt8 = 0
            for b in bytes { if b == 0x0A && prev != 0x0D { out.append(0x0D) }; out.append(b); prev = b }
            bytes = out
            var offset = 0
            let t0 = CFAbsoluteTimeGetCurrent()
            let chunks = bytes
            // SHEEPVT_STREAM_CHUNK / SHEEPVT_STREAM_MS tune the pace (default 1024 B every 3 ms).
            let chunkSize = Int(ProcessInfo.processInfo.environment["SHEEPVT_STREAM_CHUNK"] ?? "") ?? 1024
            let chunkMs = Double(ProcessInfo.processInfo.environment["SHEEPVT_STREAM_MS"] ?? "") ?? 3
            func pump() {
                let end = min(offset + chunkSize, chunks.count)
                view.feed(Array(chunks[offset..<end]))
                offset = end
                if offset >= chunks.count {
                    print("streamed \(chunks.count) bytes in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + chunkMs / 1000) { pump() }
                }
            }
            pump()
        } else if let feedFile, let data = FileManager.default.contents(atPath: feedFile) {
            view.highlightProvider = DemoHighlighter()
            view.highlightEnabled = true
            let t0 = CFAbsoluteTimeGetCurrent()
            var bytes = [UInt8](data)
            if CommandLine.arguments.contains("--crlf") {   // raw logs are LF-only
                var out = [UInt8](); out.reserveCapacity(bytes.count + bytes.count / 40)
                var prev: UInt8 = 0
                for b in bytes { if b == 0x0A && prev != 0x0D { out.append(0x0D) }; out.append(b); prev = b }
                bytes = out
            }
            view.feed(bytes)
            print("fed \(data.count) bytes in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms; lines \(view.terminal.buffer.lineCount)")
            if CommandLine.arguments.contains("--scrollup") { view.scrollViewport(by: -40) }
        } else {
            let p = LocalProcess(delegate: self)
            var env = ProcessInfo.processInfo.environment.filter { !["TERM", "COLORTERM"].contains($0.key) }
                .map { "\($0.key)=\($0.value)" }
            env += ["TERM=xterm-256color", "COLORTERM=truecolor"]
            // --shell /bin/sh: a shell without a line editor echoes typed
            // characters raw through the tty, the way a network device does.
            let shell = CommandLine.arguments.firstIndex(of: "--shell").map { CommandLine.arguments[$0 + 1] } ?? "/bin/zsh"
            // --args a b c: arguments for the program (e.g. --shell /usr/bin/ssh --args admin@host).
            var args: [String] = []
            if let i = CommandLine.arguments.firstIndex(of: "--args") { args = Array(CommandLine.arguments[(i + 1)...]).filter { !$0.hasPrefix("--") } }
            p.start(executable: shell, args: args, environment: env, execName: (shell as NSString).lastPathComponent, cols: view.cols, rows: view.rows)
            // SHEEPVT_DEMO_PASSWORD: typed into the pty 2 s after start (a test
            // device's password prompt), never printed anywhere.
            if let pw = ProcessInfo.processInfo.environment["SHEEPVT_DEMO_PASSWORD"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { p.send(Array((pw + "\n").utf8)) }
            }
            process = p
            if shell == "/bin/zsh" { p.send(Array("printf '\\e[1;31mbold red\\e[0m \\e[32mgreen\\e[0m \\e[4munderline\\e[0m \\e[7minverse\\e[0m 漢字 ไทย 😀\\n'; ls -G /Applications | head -8\n".utf8)) }
        }
        if CommandLine.arguments.contains("--resize") {
            // Animated frame change = many setFrameSize calls on main, like the
            // full-screen transition: exercises the synchronous present path.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                var f = window.frame; f.size = CGSize(width: 1300, height: 800); f.origin.x = 60
                window.setFrame(f, display: true, animate: true)
            }
        }
        if let shot {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in
                let id = CGWindowID(window.windowNumber)
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-x", "-o", "-l", String(id), shot]
                try? task.run(); task.waitUntilExit()
                print("stats:", view.renderer?.lastFrameStats ?? (0, 0, 0))
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func send(_ view: TerminalView, bytes: [UInt8]) { process?.send(bytes) }
    func sizeChanged(_ view: TerminalView, cols: Int, rows: Int) { process?.resize(cols: cols, rows: rows) }
    func titleChanged(_ view: TerminalView, title: String) { window.title = title }
    func workingDirectoryChanged(_ view: TerminalView, url: String?) {}
    func scrolled(_ view: TerminalView) {}
    func bell(_ view: TerminalView) { NSSound.beep() }
    func openLink(_ view: TerminalView, url: String) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
    func shouldPaste(_ view: TerminalView, text: String) -> Bool { true }

    func dataReceived(_ process: LocalProcess, bytes: [UInt8]) { view.feed(bytes) }
    func processTerminated(_ process: LocalProcess, exitCode: Int32?) { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let demo = Demo()
app.delegate = demo
app.run()
