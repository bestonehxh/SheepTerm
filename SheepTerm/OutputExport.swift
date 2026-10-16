import Foundation

// Copy All Output (5.0 (22)): everything a session's terminal still holds —
// scrollback and screen — as plain text. Foundation only and in
// `sharedSources` (root Package.swift): Windows builds the same text.

public nonisolated enum OutputExport {
    /// `rows` oldest first, each with whether it CONTINUES the row before it
    /// (a soft wrap at the window's edge). A wrapped run becomes one line
    /// again, the row before a wrap is not right-trimmed (its blanks are text
    /// in the middle of the line), every other row is; blank rows at the end
    /// (the empty screen under the prompt) and at the start (a fresh
    /// terminal's top) are dropped, blank rows in between stay. Nothing else is
    /// touched: no colour ever reaches here, and the text is what the screen
    /// shows.
    public static func text(rows: [(text: String, wrapped: Bool)]) -> String {
        var lines: [String] = []
        var current = ""
        for (index, row) in rows.enumerated() {
            let continues = index + 1 < rows.count && rows[index + 1].wrapped
            current += continues ? row.text : trimmedRight(row.text)
            if !continues {
                lines.append(current)
                current = ""
            }
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        let first = lines.firstIndex { !$0.isEmpty } ?? lines.endIndex
        lines.removeFirst(first)
        return lines.joined(separator: "\n")
    }

    static func trimmedRight(_ text: String) -> String {
        var out = Substring(text)
        while let last = out.last, last == " " || last == "\u{0}" { out.removeLast() }
        return String(out)
    }
}
