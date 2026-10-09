import SwiftUI

/// What ⌘Y opens: the current tab and the key its history is filed under.
struct HistoryRequest: Identifiable {
    let id = UUID()
    let tabID: UUID
    let key: String
    let title: String
}

/// Session → Command History… (⌘Y): the lines typed in this host's sessions,
/// newest first. Type to filter, ↑/↓ to move, Return or a double-click types
/// the line into the session WITHOUT Return — the user runs it. Esc closes.
struct CommandHistorySheet: View {
    let request: HistoryRequest
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var all: [String] { model.historyStore.commands(for: request.key) }

    private var filtered: [String] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return all }
        return all.filter { line in
            let lower = line.lowercased()
            return words.allSatisfy { lower.contains($0) }
        }
    }

    var body: some View {
        let lines = filtered
        VStack(alignment: .leading, spacing: 10) {
            Text("Command History · \(request.title)")
                .font(.headline)
                .lineLimit(1)

            TextField("Filter", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .noAutoFill()
                .onKeyPress(.downArrow) { move(1, count: lines.count) }
                .onKeyPress(.upArrow) { move(-1, count: lines.count) }
                .onSubmit { pick(at: selection, in: lines) }
                .onChange(of: query) { selection = 0 }

            if lines.isEmpty {
                Text(all.isEmpty ? "Nothing recorded for this host yet" : "No match")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(index == selection ? Theme.accent.opacity(0.28) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { pick(at: index, in: lines) }
                                    .onTapGesture { selection = index }
                                    .id(index)
                                    .help(line)
                            }
                        }
                    }
                    .frame(height: 260)
                    .onChange(of: selection) { proxy.scrollTo(selection) }
                }
            }

            HStack {
                Button("Remove History for This Host", role: .destructive) {
                    dismiss()
                    DispatchQueue.main.async { model.clearCommandHistoryForCurrentHost() }
                }
                .foregroundStyle(Theme.destructive)
                .disabled(all.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Type It") { pick(at: selection, in: lines) }
                    .disabled(lines.isEmpty)
                    .help("Types the line into the session; press Return there to run it")
            }
        }
        .padding(20)
        .frame(width: 560)
        .sheepSheetChrome()
        .onAppear { focused = true }
    }

    private func move(_ delta: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .handled }
        selection = min(max(selection + delta, 0), count - 1)
        return .handled
    }

    private func pick(at index: Int, in lines: [String]) {
        guard lines.indices.contains(index) else { return }
        let line = lines[index]
        dismiss()
        // After the sheet is gone, so the keyboard is back in the terminal.
        DispatchQueue.main.async { model.typeHistoryCommand(line, into: request.tabID) }
    }
}
