//
//  SoakChurnTests.swift — the churn half of the soak: everything that INVALIDATES a cache,
//  repeated for a long time. The steady-stream soak only ever grows the grid; this one resizes,
//  toggles the alternate screen, bumps the provider revision, clears the scrollback and changes
//  the search term, which is what a real day of `less`, `vi`, window drags and vendor switches
//  looks like.
//
//  What it is actually hunting: a cache whose *invalidation* path leaks. `HighlightOverlay` keeps
//  two dictionaries — `entries` (head line → paragraph) and `headOfLine` (member line → head) —
//  and only `drop(head:)` removes anything from `headOfLine`, using the CURRENT entry's row count.
//  A paragraph that shrinks strands the member lines it no longer covers. `trim(rows:)` walks
//  `entries` only, so a stranded key is never swept. This test measures the two counts against
//  each other over tens of thousands of invalidations.
//
//  Enabled by SHEEPVT_SOAK=1, like the rest.
//

import Foundation
import Metal
import Testing

@testable import SheepVT
@testable import SheepVTRender


// MARK: - metrics (file-private copies; `private` at file scope is fileprivate in Swift)

private nonisolated func soakResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return ok == KERN_SUCCESS ? info.resident_size : 0
}

private nonisolated func soakFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return ok == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

private nonisolated func soakThreadCount() -> Int {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
    for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
    vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
    return Int(count)
}

private nonisolated func soakStoredValue(_ subject: Any, _ label: String) -> Any? {
    for child in Mirror(reflecting: subject).children where child.label == label { return child.value }
    return nil
}

private nonisolated func soakStoredCount(_ subject: Any, _ label: String) -> Int {
    guard let v = soakStoredValue(subject, label) else { return -1 }
    return Mirror(reflecting: v).children.count
}

/// Entries of a reflected Dictionary as (key, value) pairs.
private nonisolated func soakDictValues(_ dictionary: Any) -> [Any] {
    Mirror(reflecting: dictionary).children.map { pair in
        let parts = Mirror(reflecting: pair.value).children.map { $0.value }
        return parts.count >= 2 ? parts[1] : pair.value
    }
}

private nonisolated var churnSoakEnabled: Bool { ProcessInfo.processInfo.environment["SHEEPVT_SOAK"] == "1" }

private nonisolated func soakEmit(_ line: String) {
    FileHandle.standardError.write(("SOAK," + line + "\n").data(using: .utf8)!)
}

@Suite(.serialized) struct SoakChurnTests {

    @Test(.enabled(if: churnSoakEnabled)) func soakCacheChurn() async throws {
        let minutes = Double(ProcessInfo.processInfo.environment["SHEEPVT_CHURN_MINUTES"].flatMap(Double.init) ?? 12)
        let cols = 120, rows = 40
        let terminal = Terminal(cols: cols, rows: rows, scrollback: 10_000)
        let search = SearchEngine(terminal: terminal)
        let provider = ChurnProvider()
        let overlay = HighlightOverlay(provider: provider)

        soakEmit("header,phase,t_s,rss_mb,footprint_mb,threads,lines,trimmed,ovlEntries,ovlEntryRows,ovlHeadOfLine,stranded,srchRowCache,srchLineEntries,srchLineSigRows,srchSpanEntries,srchSpanSigRows,resizes,altToggles,revBumps,clears,termChanges")

        var resizes = 0, altToggles = 0, revBumps = 0, clears = 0, termChanges = 0
        var peakStranded = 0

        // Paragraphs that change length: at 120 columns the long one wraps over four rows, the
        // short one over one. Alternating them at the same line numbers is the shrink path.
        let longPara = "interface GigabitEthernet1/0/7 is up, line protocol is up, " +
            String(repeating: "z", count: 380) + "\r\n"
        let shortPara = "vlan 10 up\r\n"
        let mixed = "\u{1B}[32mport 12 up\u{1B}[0m 10.1.1.1 packets input\r\n"

        func sample(_ phase: String, _ t: Double) {
            var entryRows = 0
            if let entries = soakStoredValue(overlay, "entries") {
                for entry in soakDictValues(entries) { entryRows += max(soakStoredCount(entry, "rows"), 0) }
            }
            let heads = soakStoredCount(overlay, "headOfLine")
            let stranded = heads - entryRows
            peakStranded = max(peakStranded, stranded)
            soakEmit([
                "sample", phase, String(format: "%.0f", t),
                String(format: "%.1f", Double(soakResidentBytes()) / 1_048_576),
                String(format: "%.1f", Double(soakFootprintBytes()) / 1_048_576),
                "\(soakThreadCount())",
                "\(terminal.buffer.lines.count)", "\(terminal.buffer.lines.trimmed)",
                "\(soakStoredCount(overlay, "entries"))", "\(entryRows)", "\(heads)", "\(stranded)",
                "\(soakStoredCount(search, "rowCache"))",
                "\(search.lineCacheEntryCount)", "\(search.lineCacheSignatureRows)",
                "\(search.spanCacheEntryCount)", "\(search.spanCacheSignatureRows)",
                "\(resizes)", "\(altToggles)", "\(revBumps)", "\(clears)", "\(termChanges)",
            ].joined(separator: ","))
        }

        let start = Date()
        let deadline = start.addingTimeInterval(minutes * 60)
        var nextSample = start.addingTimeInterval(30)
        var iteration = 0
        let terms = ["up", "down", "packets", "10.1", "Gigabit"]

        while Date() < deadline {
            iteration += 1

            // Output whose paragraph lengths alternate.
            for k in 0..<12 {
                terminal.feed((iteration + k) % 3 == 0 ? longPara : ((iteration + k) % 3 == 1 ? shortPara : mixed))
            }

            // Ask the overlay for the whole viewport, as the renderer does every frame.
            for r in 0..<rows {
                _ = overlay.overrides(line: terminal.buffer.lineNumber(ofViewportRow: r), in: terminal)
            }
            // And for a screen of scrollback above it, so `trim` has something to walk.
            let top = max(terminal.buffer.firstLine, terminal.buffer.lastLine - rows * 3)
            for l in top..<min(top + rows, terminal.buffer.lastLine) {
                _ = overlay.overrides(line: l, in: terminal)
            }

            if iteration % 5 == 0 {
                search.term = terms[iteration % terms.count]
                termChanges += 1
                _ = search.findAll(limit: 300)
            }
            if iteration % 11 == 0 {
                // A resize: reflow renumbers everything and shrinks/grows every paragraph.
                resizes += 1
                terminal.resize(cols: [80, 100, 120, 160][resizes % 4], rows: rows)
                overlay.invalidate()
            }
            if iteration % 17 == 0 {
                // `less` opening and closing.
                altToggles += 1
                terminal.feed("\u{1B}[?1049h")
                terminal.feed("paging\r\n")
                for r in 0..<rows { _ = overlay.overrides(line: terminal.buffer.lineNumber(ofViewportRow: r), in: terminal) }
                terminal.feed("\u{1B}[?1049l")
            }
            if iteration % 29 == 0 {
                // A vendor switch.
                revBumps += 1
                provider.revision &+= 1
            }
            if iteration % 401 == 0 {
                // Clear Scrollback (ED 3).
                clears += 1
                terminal.feed("\u{1B}[3J")
            }

            if Date() >= nextSample {
                nextSample = Date().addingTimeInterval(30)
                sample("run", Date().timeIntervalSince(start))
                await Task.yield()
            }
        }

        sample("end", Date().timeIntervalSince(start))
        soakEmit("summary,churn,iterations,\(iteration),resizes,\(resizes),altToggles,\(altToggles),revBumps,\(revBumps),clears,\(clears),termChanges,\(termChanges),peakStranded,\(peakStranded)")
    }
}

private final class ChurnProvider: HighlightProvider {
    var revision: UInt64 = 1
    private let words: [[UInt8]] = ["up", "down", "packets", "port", "vlan"].map { Array($0.utf8) }
    func spans(in paragraph: [UInt8]) -> [HighlightSpan] {
        var out: [HighlightSpan] = []
        for word in words where paragraph.count >= word.count {
            var i = 0
            while i <= paragraph.count - word.count {
                var hit = true
                for k in 0..<word.count where paragraph[i + k] != word[k] { hit = false; break }
                if hit { out.append(HighlightSpan(range: i..<(i + word.count), rgb: 0x66AAFF, bold: false)); i += word.count }
                else { i += 1 }
            }
        }
        return out
    }
}
