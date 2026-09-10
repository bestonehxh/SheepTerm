//
//  SoakTests.swift — long-running drift hunt (NOT part of the normal suite).
//
//  Every other test in this package finishes in seconds. These do not: they run for tens of
//  minutes and answer one question only — does anything grow monotonically that shouldn't.
//
//  They are skipped unless SHEEPVT_SOAK=1 is set, so `./Tests/run.sh vt` is unaffected.
//
//  Environment:
//    SHEEPVT_SOAK=1              enable
//    SHEEPVT_SOAK_MINUTES=45     duration of the steady-stream soak
//    SHEEPVT_SOAK_REPLAY=<dir>   directory of captured device logs to replay (copies, read-only)
//    SHEEPVT_SOAK_CYCLES=400     LocalProcess open/close cycles
//    SHEEPVT_SOAK_LINES=3000000  lines for the scrollback-cap soak
//
//  Everything is reported as CSV on stderr with a `SOAK,` prefix so the run can be plotted.
//

import Foundation
import Metal
import Testing

@testable import SheepVT
@testable import SheepVTRender

// MARK: - process metrics

private nonisolated func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return ok == KERN_SUCCESS ? info.resident_size : 0
}

/// `phys_footprint` — what the memory limit and Instruments' "Memory" column actually track.
private nonisolated func footprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return ok == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

private nonisolated func openDescriptorCount() -> Int {
    var count = 0
    let limit = min(getdtablesize(), 8192)
    for fd in 0..<limit where fcntl(fd, F_GETFD) != -1 { count += 1 }
    return count
}

private nonisolated func liveThreadCount() -> Int {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
    for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
    vm_deallocate(mach_task_self_,
                  vm_address_t(UInt(bitPattern: list)),
                  vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
    return Int(count)
}

/// Number of entries in a (possibly `private`) stored dictionary/array property. Access control is
/// not reflection's business, which is the only reason these caches can be measured at all.
private nonisolated func storedCount(_ subject: Any, _ label: String) -> Int {
    for child in Mirror(reflecting: subject).children where child.label == label {
        return Mirror(reflecting: child.value).children.count
    }
    return -1
}

private nonisolated func storedValue(_ subject: Any, _ label: String) -> Any? {
    for child in Mirror(reflecting: subject).children where child.label == label {
        return child.value
    }
    return nil
}

private nonisolated func emit(_ line: String) {
    FileHandle.standardError.write(("SOAK," + line + "\n").data(using: .utf8)!)
}

private nonisolated var soakEnabled: Bool { ProcessInfo.processInfo.environment["SHEEPVT_SOAK"] == "1" }

private let soakSearchLimit = 500

private nonisolated func envInt(_ key: String, _ fallback: Int) -> Int {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init) ?? fallback
}

// MARK: - the stream

/// Chunks of a realistic device stream: the captured logs (LF → CRLF, as a pty would), plus
/// synthetic SGR-coloured output so the row builder, the colour-source bits and the highlight
/// overlay all see real work. Logs are read from a COPY; nothing under ~/Documents is touched.
private nonisolated func soakCorpus() -> [[UInt8]] {
    var out: [[UInt8]] = []
    if let dir = ProcessInfo.processInfo.environment["SHEEPVT_SOAK_REPLAY"],
       let names = try? FileManager.default.contentsOfDirectory(atPath: dir) {
        for name in names.sorted() where name.hasSuffix(".log") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + name), !data.isEmpty else { continue }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(data.count + data.count / 20)
            var previous: UInt8 = 0
            for b in data {
                if b == 0x0A && previous != 0x0D { bytes.append(0x0D) }
                bytes.append(b)
                previous = b
            }
            // 4 KiB chunks, the size a pty read hands over.
            var i = 0
            while i < bytes.count {
                let end = min(i + 4096, bytes.count)
                out.append(Array(bytes[i..<end]))
                i = end
            }
        }
    }
    // Synthetic vendor-ish output with SGR, so ~a third of the stream carries device colours.
    var synthetic = ""
    for i in 0..<200 {
        synthetic += "\u{1B}[1;32mGigabitEthernet1/0/\(i % 48)\u{1B}[0m  is \u{1B}[31mdown\u{1B}[0m, line protocol is up\r\n"
        synthetic += "  Internet address is 10.\(i % 250).\(i % 199).1/24  MTU 1500 bytes, BW 1000000 Kbit/sec\r\n"
        synthetic += "  \u{1B}[33m\(i) packets input, \(i * 7919) bytes, 0 no buffer\u{1B}[0m\r\n"
        if i % 7 == 0 {
            synthetic += "  a long unwrapped line that will soft-wrap at 200 columns: " +
                String(repeating: "x", count: 420) + "\r\n"
        }
    }
    let sbytes = Array(synthetic.utf8)
    var i = 0
    while i < sbytes.count {
        let end = min(i + 4096, sbytes.count)
        out.append(Array(sbytes[i..<end]))
        i = end
    }
    return out
}

/// Stands in for the app's `Highlighter`: a handful of keywords over paragraph bytes.
private final class SoakProvider: HighlightProvider {
    var revision: UInt64 = 1
    private let words: [[UInt8]] = ["up", "down", "Ethernet", "packets", "Internet", "SOAKMARK"].map { Array($0.utf8) }
    private(set) var calls = 0

    func spans(in paragraph: [UInt8]) -> [HighlightSpan] {
        calls += 1
        var out: [HighlightSpan] = []
        guard !paragraph.isEmpty else { return out }
        for word in words where paragraph.count >= word.count {
            var i = 0
            while i <= paragraph.count - word.count {
                var hit = true
                for k in 0..<word.count where paragraph[i + k] != word[k] { hit = false; break }
                if hit {
                    out.append(HighlightSpan(range: i..<(i + word.count), rgb: 0x33CC66, bold: false))
                    i += word.count
                } else {
                    i += 1
                }
            }
        }
        return out
    }
}

/// Renderer + offscreen texture, sized for the soak's grid.
@MainActor private final class SoakRenderer {
    let renderer: MetalRenderer
    let texture: MTLTexture
    let scale: CGFloat = 2

    init?(cols: Int, rows: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        renderer = try MetalRenderer(device: device)
        renderer.fontSet = FontSet(font: .monospacedSystemFont(ofSize: 13, weight: .regular), scale: scale)
        let m = renderer.fontSet.metrics
        let w = max(Int((m.width * CGFloat(cols) * scale).rounded()), 1)
        let h = max(Int((m.height * CGFloat(rows) * scale).rounded()), 1)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalRenderer.pixelFormat,
                                                        width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        texture = t
    }
}

// MARK: - 1 + 4: steady output, search and highlight, for tens of minutes

@Suite(.serialized) struct SoakTests {

    @Test(.enabled(if: soakEnabled)) func soakSteadyStream() async throws {
        let minutes = Double(envInt("SHEEPVT_SOAK_MINUTES", 45))
        let cols = 200, rows = 50
        let terminal = Terminal(cols: cols, rows: rows, scrollback: 10_000)
        let search = SearchEngine(terminal: terminal)
        let provider = SoakProvider()
        let overlay = HighlightOverlay(provider: provider)
        let renderHarness = try SoakRenderer(cols: cols, rows: rows)
        if renderHarness == nil { emit("note,no Metal device — renderer half of the soak is skipped") }

        let corpus = soakCorpus()
        try #require(!corpus.isEmpty, "no corpus")
        emit("meta,steady,corpusChunks,\(corpus.count),minutes,\(minutes),cols,\(cols),rows,\(rows)")
        emit("header,phase,t_s,rss_mb,footprint_mb,fds,threads,lines,allocRows,trimmed,fedMB,srchRowCache,srchLineEntries,srchLineSigRows,srchSpanEntries,srchSpanSigRows,ovlEntries,ovlHeadOfLine,rendRowCache,glyphCache,matches,markerFailures,markerChecked,rowStringify,logicalMatch")

        // Markers: a token written at a known absolute line, searched for later. This is the
        // correctness half — a match reported at minute 40 must be at the line it says.
        var markers: [(line: Int, token: String)] = []
        var markerChecked = 0
        var markerFailures: [String] = []

        var fed: UInt64 = 0
        var chunkIndex = 0
        var frames = 0
        var lastMatchCount = 0

        let start = Date()
        var nextSample = start.addingTimeInterval(30)
        var nextSearch = start.addingTimeInterval(60)
        var nextMarker = start.addingTimeInterval(5)
        var nextResurvey = start.addingTimeInterval(30)
        var lastRender = Date.distantPast
        var burstStart = start
        let deadline = start.addingTimeInterval(minutes * 60)
        var markerSeq = 0

        func sample(_ phase: String) {
            let matches = search.term.isEmpty ? 0 : lastMatchCount
            let glyphCacheCount: Int = {
                guard let r = renderHarness?.renderer, let gc = storedValue(r, "glyphCache") else { return -1 }
                return storedCount(gc, "cache")
            }()
            emit([
                "sample", phase,
                String(format: "%.0f", Date().timeIntervalSince(start)),
                String(format: "%.1f", Double(residentBytes()) / 1_048_576),
                String(format: "%.1f", Double(footprintBytes()) / 1_048_576),
                "\(openDescriptorCount())", "\(liveThreadCount())",
                "\(terminal.buffer.lines.count)", "\(terminal.buffer.lines.allocatedRowCount)",
                "\(terminal.buffer.lines.trimmed)",
                String(format: "%.1f", Double(fed) / 1_048_576),
                "\(storedCount(search, "rowCache"))",
                "\(search.lineCacheEntryCount)", "\(search.lineCacheSignatureRows)",
                "\(search.spanCacheEntryCount)", "\(search.spanCacheSignatureRows)",
                "\(storedCount(overlay, "entries"))", "\(storedCount(overlay, "headOfLine"))",
                "\(renderHarness.map { storedCount($0.renderer, "rowCache") } ?? -1)",
                "\(glyphCacheCount)",
                "\(matches)", "\(markerFailures.count)", "\(markerChecked)",
                "\(search.rowStringifyCount)", "\(search.logicalMatchCount)",
            ].joined(separator: ","))
        }

        sample("begin")

        // Rate limit, and a duty cycle. Unthrottled this loop does ~130 MB/s, which is not a
        // terminal. A real session is bursty: a command dumps for a few seconds, then the line is
        // idle while the engineer reads. `burst` seconds of output at `bytesPerSecond`, then
        // `idle` seconds of nothing — during which the ring is still and a marker written into it
        // survives long enough to be searched for, which is the correctness half of this soak.
        let bytesPerSecond = Double(envInt("SHEEPVT_SOAK_RATE_KBPS", 2048)) * 1024
        let burst = Double(envInt("SHEEPVT_SOAK_BURST_S", 10))
        let idle = Double(envInt("SHEEPVT_SOAK_IDLE_S", 20))
        var burstBudget: Double = 0        // bytes owed inside the current burst
        var phaseEnd = start.addingTimeInterval(burst)
        var streaming = true

        while Date() < deadline {
            var now = Date()
            if now >= phaseEnd {
                streaming.toggle()
                phaseEnd = now.addingTimeInterval(streaming ? burst : idle)
                if streaming { burstBudget = 0; burstStart = now }
            }

            if streaming {
                for _ in 0..<2 {
                    terminal.feed(corpus[chunkIndex])
                    fed &+= UInt64(corpus[chunkIndex].count)
                    burstBudget += Double(corpus[chunkIndex].count)
                    chunkIndex = (chunkIndex + 1) % corpus.count
                }
                now = Date()
                let owed = burstBudget / bytesPerSecond - now.timeIntervalSince(burstStart)
                if owed > 0.002 { try? await Task.sleep(nanoseconds: UInt64(min(owed, 0.25) * 1_000_000_000)) }
            } else {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            now = Date()

            if now >= nextMarker {
                nextMarker = now.addingTimeInterval(5)
                markerSeq += 1
                let token = "SOAKMARK-\(markerSeq)-END"
                terminal.feed("\r\n" + token + "\r\n")
                // The token sits on the line the cursor was on before the trailing CRLF.
                let line = terminal.buffer.lineNumber(ofScreenRow: terminal.buffer.y) - 1
                markers.append((line, token))
                if markers.count > 2000 { markers.removeFirst(markers.count - 2000) }
                // Verify it at once — the ring can turn over in under a second at these rates.
                let held = search.term
                search.term = token
                let hits = search.findAll(limit: 10)
                markerChecked += 1
                if hits.count != 1 || hits[0].start.line != line {
                    markerFailures.append("write: \(token) expected \(line) got \(hits.map { $0.start.line }) firstLine \(terminal.buffer.firstLine)")
                }
                search.term = held
            }

            // Re-verify every marker still inside the ring, on the sample cadence: this is the
            // "found at minute 40, still at the line it says" check.
            if now >= nextResurvey {
                nextResurvey = now.addingTimeInterval(30)
                let held = search.term
                var survivors = 0
                for marker in markers where marker.line >= terminal.buffer.firstLine && marker.line <= terminal.buffer.lastLine {
                    search.term = marker.token
                    let hits = search.findAll(limit: 10)
                    survivors += 1
                    markerChecked += 1
                    if hits.count != 1 || hits[0].start.line != marker.line {
                        markerFailures.append("resurvey: \(marker.token) expected \(marker.line) got \(hits.map { $0.start.line })")
                    }
                }
                search.term = held
                emit("resurvey,\(String(format: "%.0f", now.timeIntervalSince(start))),survivors,\(survivors),failures,\(markerFailures.count)")
                markers.removeAll { $0.line < terminal.buffer.firstLine }
            }

            if now >= nextSearch {
                nextSearch = now.addingTimeInterval(60)
                // A term that exists on most lines: the match cache is invalidated and rebuilt.
                search.term = "down"
                lastMatchCount = search.findAll(limit: soakSearchLimit).count
                // And an exact-marker search, checked against the line it was written at.
                if let marker = markers.last(where: { $0.line >= terminal.buffer.firstLine + 5 }) {
                    search.term = marker.token
                    let hits = search.findAll(limit: 10)
                    markerChecked += 1
                    if hits.count != 1 || hits[0].start.line != marker.line {
                        markerFailures.append("token \(marker.token) expected line \(marker.line) got \(hits.map { $0.start.line })")
                    }
                }
                search.term = "down"
                lastMatchCount = search.findAll(limit: soakSearchLimit).count
            }

            if let rh = renderHarness, now.timeIntervalSince(lastRender) >= 0.033 {
                lastRender = now
                var frame = FrameOverlay()
                frame.highlight = overlay
                frame.searchMatches = search.term.isEmpty ? [] : search.findAll(limit: soakSearchLimit)
                _ = rh.renderer.render(terminal: terminal, overlay: frame, into: rh.texture, scale: rh.scale)
                frames += 1
            }

            if now >= nextSample {
                nextSample = now.addingTimeInterval(30)
                sample("run")
                await Task.yield()
            }
        }

        // Every marker still inside the ring must still be where it said it was.
        var finalChecked = 0
        for marker in markers where marker.line >= terminal.buffer.firstLine && marker.line <= terminal.buffer.lastLine {
            search.term = marker.token
            let hits = search.findAll(limit: 10)
            finalChecked += 1
            if hits.count != 1 || hits[0].start.line != marker.line {
                markerFailures.append("final: \(marker.token) expected \(marker.line) got \(hits.map { $0.start.line })")
            }
        }
        emit("summary,finalMarkerSweep,checked,\(finalChecked),retainedMarkers,\(markers.count)")
        search.term = "down"
        sample("end")
        emit("summary,steady,frames,\(frames),fedMB,\(String(format: "%.1f", Double(fed) / 1_048_576)),providerCalls,\(provider.calls),markerChecked,\(markerChecked),markerFailures,\(markerFailures.count)")
        for f in markerFailures.prefix(10) { emit("markerFailure,\(f)") }
        #expect(markerFailures.isEmpty, "search reported a marker at the wrong line: \(markerFailures.prefix(3))")
        #expect(markerChecked > 0)
    }

    // MARK: - 2: the scrollback cap and LineRing.trimmed arithmetic

    @Test(.enabled(if: soakEnabled)) func soakScrollbackCap() async throws {
        let target = envInt("SHEEPVT_SOAK_LINES", 3_000_000)
        let cols = 200, rows = 50
        let terminal = Terminal(cols: cols, rows: rows, scrollback: 10_000)
        emit("header,phase,t_s,rss_mb,footprint_mb,lines,trimmed,firstLine,lastLine,allocatedRows,resizes")

        // One line of ~120 printable columns, repeated. 64 lines per feed.
        let unit = Array(("interface Gi1/0/1 is up, line protocol is up, 1500 MTU, " +
                          String(repeating: "y", count: 60) + "\r\n").utf8)
        var block: [UInt8] = []
        for _ in 0..<64 { block.append(contentsOf: unit) }

        let start = Date()
        var produced = 0
        var resizes = 0
        var nextSample = start.addingTimeInterval(30)
        var failures: [String] = []

        func check() {
            let b = terminal.buffer
            let first = b.firstLine, last = b.lastLine
            if first != b.lines.trimmed { failures.append("firstLine \(first) != trimmed \(b.lines.trimmed)") }
            if last - first + 1 != b.lines.count { failures.append("span \(first)...\(last) != count \(b.lines.count)") }
            if b.index(ofLine: first) != 0 { failures.append("index(ofLine:first) = \(String(describing: b.index(ofLine: first)))") }
            if b.index(ofLine: last) != b.lines.count - 1 { failures.append("index(ofLine:last) wrong") }
            if b.index(ofLine: first - 1) != nil { failures.append("index(ofLine:) accepted a trimmed line") }
            if b.lineNumber(atIndex: 0) != first { failures.append("lineNumber(atIndex:0) != firstLine") }
            if b.lines.count > b.lines.maxLength { failures.append("count \(b.lines.count) > maxLength \(b.lines.maxLength)") }
        }

        func sample(_ phase: String) {
            let b = terminal.buffer
            emit([
                "sample", phase,
                String(format: "%.0f", Date().timeIntervalSince(start)),
                String(format: "%.1f", Double(residentBytes()) / 1_048_576),
                String(format: "%.1f", Double(footprintBytes()) / 1_048_576),
                "\(b.lines.count)", "\(b.lines.trimmed)", "\(b.firstLine)", "\(b.lastLine)",
                "\(b.lines.allocatedRowCount)", "\(resizes)",
            ].joined(separator: ","))
        }

        sample("begin")
        while produced < target {
            terminal.feed(block)
            produced += 64
            if produced % 100_000 < 64 {
                check()
                // A resize every ~100k lines: reflow rebuilds the ring, which is where the
                // trimmed arithmetic is easiest to get wrong.
                resizes += 1
                terminal.resize(cols: resizes % 2 == 0 ? cols : cols - 17, rows: rows)
                check()
            }
            if Date() >= nextSample {
                nextSample = Date().addingTimeInterval(30)
                sample("run")
                await Task.yield()
            }
        }
        check()

        // The marker round trip after millions of lines: write a token, read it back by its
        // absolute line number.
        terminal.resize(cols: cols, rows: rows)
        let token = "SOAKMARK-TAIL-\(produced)"
        terminal.feed("\r\n" + token + "\r\n")
        let line = terminal.buffer.lineNumber(ofScreenRow: terminal.buffer.y) - 1
        let search = SearchEngine(terminal: terminal)
        search.term = token
        let hits = search.findAll(limit: 5)
        if hits.count != 1 || hits[0].start.line != line {
            failures.append("tail marker at line \(line), search said \(hits.map { $0.start.line })")
        }
        // And the absolute line number is well past what a 32-bit counter would survive.
        emit("summary,cap,producedLines,\(produced),trimmed,\(terminal.buffer.lines.trimmed),lastLine,\(terminal.buffer.lastLine),failures,\(failures.count)")
        sample("end")
        for f in failures.prefix(20) { emit("capFailure,\(f)") }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }

    // MARK: - 5: repeated open/close of LocalProcess

    @Test(.enabled(if: soakEnabled)) func soakProcessCycles() async throws {
        let cycles = envInt("SHEEPVT_SOAK_CYCLES", 400)
        emit("header,phase,cycle,rss_mb,footprint_mb,fds,threads")

        final class Sink: LocalProcessDelegate {
            var bytes = 0
            var terminations = 0
            func dataReceived(_ process: LocalProcess, bytes: [UInt8]) { self.bytes += bytes.count }
            func processTerminated(_ process: LocalProcess, exitCode: Int32?) { terminations += 1 }
        }

        let env = ["PATH=/usr/bin:/bin", "TERM=xterm-256color"]

        func settle(_ seconds: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            return condition()
        }

        func snapshot(_ phase: String, _ cycle: Int) {
            emit([
                "sample", phase, "\(cycle)",
                String(format: "%.1f", Double(residentBytes()) / 1_048_576),
                String(format: "%.1f", Double(footprintBytes()) / 1_048_576),
                "\(openDescriptorCount())", "\(liveThreadCount())",
            ].joined(separator: ","))
        }

        snapshot("begin", 0)
        var missedExits = 0

        for cycle in 0..<cycles {
            let sink = Sink()
            let process = LocalProcess(delegate: sink)
            if cycle % 4 == 3 {
                // A child that never exits on its own — the terminate()/SIGHUP path.
                let ok = process.start(executable: "/bin/cat", args: ["cat"], environment: env,
                                       execName: nil, cols: 80, rows: 24)
                #expect(ok)
                _ = await settle(2) { process.running }
                process.send(Array("hello\n".utf8))
                _ = await settle(2) { sink.bytes > 0 }
                process.terminate()
            } else {
                let ok = process.start(executable: "/bin/sh",
                                       args: ["sh", "-c", "printf 'sheep %s\\n' 1 2 3"],
                                       environment: env, execName: nil, cols: 80, rows: 24)
                #expect(ok)
            }
            if await settle(5, { sink.terminations == 1 }) == false { missedExits += 1 }
            // Drain any straggling main-queue hops before measuring.
            try? await Task.sleep(nanoseconds: 5_000_000)
            if cycle % 25 == 0 || cycle == cycles - 1 { snapshot("run", cycle) }
        }

        // Let every cancel handler land.
        try? await Task.sleep(nanoseconds: 500_000_000)
        snapshot("end", cycles)

        // Zombies: any child of ours still in Z after everything was reaped.
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "ppid=,stat="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let mypid = ProcessInfo.processInfo.processIdentifier
        var zombies = 0
        for row in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = row.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, Int32(parts[0]) == mypid else { continue }
            if parts[1].hasPrefix("Z") { zombies += 1 }
        }
        emit("summary,cycles,\(cycles),missedExits,\(missedExits),zombies,\(zombies)")
        #expect(zombies == 0)
        #expect(missedExits == 0)
    }
}
