import SheepVT

extension OutputExport {
    /// The rows `text(rows:)` takes, from a SheepVT buffer, oldest first. A
    /// blank line is often no row at all (`row(line:)` is nil for a slot
    /// never written) — it is still a line of the output, so it counts as an
    /// empty, unwrapped row (review 5.0 (22): Copy All Output dropped every
    /// blank line between paragraphs).
    static func rows(of buffer: Buffer) -> [(text: String, wrapped: Bool)] {
        guard buffer.lineCount > 0 else { return [] }
        var rows: [(text: String, wrapped: Bool)] = []
        rows.reserveCapacity(buffer.lineCount)
        for line in buffer.firstLine...buffer.lastLine {
            rows.append(buffer.row(line: line).map { ($0.string(trimRight: false), $0.wrapped) } ?? ("", false))
        }
        return rows
    }
}
