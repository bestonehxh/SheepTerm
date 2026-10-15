import AppKit
import SwiftUI

/// The AI panel: a column to the right of the workspace (every pane),
/// View ▸ Show AI Panel (⌥⌘A) or the button after "+" in the tab bar.
/// Quiet on purpose: provider + New Chat, the conversation, the composer.

extension View {
    /// The one attachment point in DetailPane: the workspace, then the panel.
    func aiPanel() -> some View {
        HStack(spacing: 0) {
            self
            AIPanelColumn()
        }
    }
}

/// Tab-bar button right after "+": same size and colour as the bar's other icons.
struct AIPanelToggleButton: View {
    @ObservedObject private var ai = AIPanelChrome.shared
    @State private var hovering = false

    var body: some View {
        Button {
            ai.toggle()
        } label: {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: 13))
                .foregroundStyle(ai.shown ? Theme.accent : (hovering ? Theme.tabText : Theme.dimText))
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Show AI Panel")
    }
}

struct AIPanelColumn: View {
    @ObservedObject private var ai = AIPanelChrome.shared

    var body: some View {
        if ai.shown {
            HStack(spacing: 0) {
                AIPanelResizeHandle()
                AIPanelView()
                    .frame(width: ai.width)
            }
        }
    }
}

/// Same shape as `SidebarResizeHandle`: 1 pt line, 9 pt grab strip, the
/// cursor pushed/popped in pairs, persisted once per drag.
private struct AIPanelResizeHandle: View {
    @ObservedObject private var ai = AIPanelChrome.shared
    @State private var start: CGFloat?
    @State private var cursorPushed = false
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        Rectangle()
            .fill(Theme.chromeLine)
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                dragging = true
                                let base = start ?? ai.width
                                if start == nil { start = base }
                                ai.width = min(max(base - value.translation.width, AIPanelModel.widthRange.lowerBound),
                                               AIPanelModel.widthRange.upperBound)
                            }
                            .onEnded { _ in
                                dragging = false
                                start = nil
                                if !hovering, cursorPushed { NSCursor.pop(); cursorPushed = false }
                                UserDefaults.standard.set(ai.width, forKey: AIPanelModel.widthKey)
                            }
                    )
                    .onHover { inside in
                        hovering = inside
                        if inside, !cursorPushed {
                            NSCursor.resizeLeftRight.push(); cursorPushed = true
                        } else if !inside, cursorPushed, !dragging {
                            NSCursor.pop(); cursorPushed = false
                        }
                    }
            )
            .onDisappear {
                if cursorPushed { NSCursor.pop(); cursorPushed = false }
            }
    }
}

struct AIPanelView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var ai = AIPanelModel.shared

    var body: some View {
        VStack(spacing: 0) {
            if let session = model.selectedID {
                let conversation = ai.conversation(for: session)
                header(session, conversation)
                Rectangle().fill(Theme.chromeLine).frame(height: 1)
                AIConversationView(session: session, conversation: conversation)
                AIComposer(session: session, conversation: conversation)
            } else {
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.dimText.opacity(0.5))
                Spacer()
            }
        }
        // The whole column, not just the content's height (an empty panel
        // painted only a stripe).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ChromeBackground(zone: .sidebar) }
    }

    private func header(_ session: UUID, _ conversation: AIConversation) -> some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(AIProvider.allCases) { provider in
                    Button(provider.label) { ai.setProvider(provider, for: session) }
                }
            } label: {
                Text(conversation.provider.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tabText.opacity(0.9))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            Spacer()
            Button {
                ai.newChat(for: session)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.dimText)
            .accessibilityLabel("New Chat")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }
}

// MARK: - Conversation

private struct AIConversationView: View {
    let session: UUID
    let conversation: AIConversation

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(conversation.messages) { message in
                        AIMessageView(session: session, message: message,
                                      streaming: conversation.running && message.id == conversation.messages.last?.id)
                            .equatable()
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.automatic)
            .onChange(of: conversation.messages.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: conversation.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

/// Equatable: a delta re-renders only the row whose text changed, not every
/// message on screen.
private struct AIMessageView: View, Equatable {
    let session: UUID
    let message: AIMessage
    let streaming: Bool

    nonisolated static func == (a: AIMessageView, b: AIMessageView) -> Bool {
        a.session == b.session && a.message == b.message && a.streaming == b.streaming
    }

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .leading, spacing: 6) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.tabText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(message.attachments) { attachment in
                    AIAttachmentChip(attachment: attachment, onRemove: nil)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { ControlFill(zone: .sidebar, cornerRadius: 8) }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                Text(message.provider.label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.dimText)
                ForEach(Array(AIAnswerRenderCache.shared.rendered(message).enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let text):
                        Text(text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.tabText.opacity(0.92))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    case .code(let body, let configChange):
                        AICodeBlock(session: session, code: body, configChange: configChange)
                    }
                }
                if streaming && message.text.isEmpty {
                    ProgressView().controlSize(.small)
                }
                if let failure = message.failure {
                    Text(failure)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.destructive)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if message.stopped {
                    Text("Stopped")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dimText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

/// Parsed answers, kept per (message id, text length): a streaming answer is
/// parsed once per flush, a finished one once — never on every render.
@MainActor
final class AIAnswerRenderCache {
    static let shared = AIAnswerRenderCache()

    enum Segment {
        case text(AttributedString)
        case code(String, configChange: Bool)
    }

    private var entries: [UUID: (length: Int, segments: [Segment])] = [:]
    static let capacity = 400

    func rendered(_ message: AIMessage) -> [Segment] {
        let length = message.text.utf8.count
        if let hit = entries[message.id], hit.length == length { return hit.segments }
        let segments = AIAnswerParser.segments(message.text).map { segment -> Segment in
            switch segment {
            case .text(let text): return .text(Self.markdown(text))
            case .code(_, let body, let configChange): return .code(body, configChange: configChange)
            }
        }
        if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
        entries[message.id] = (length, segments)
        return segments
    }

    /// Inline markdown (bold, italics, `code`) with the line breaks kept.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct AICodeBlock: View {
    let session: UUID
    let code: String
    /// Marked "CONFIG CHANGE:" by the model: amber outline and edge, no caption.
    var configChange = false
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.tabText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .padding(.trailing, 44)
            }
            HStack(spacing: 2) {
                iconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                iconButton("arrow.down.to.line", help: "Paste into Tab (no Return)") {
                    AIPanelModel.shared.paste(code, into: session)
                }
            }
            .padding(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.tabActive))
        .overlay {
            if configChange {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.warn.opacity(0.75), lineWidth: 1)
            }
        }
        .overlay(alignment: .leading) {
            if configChange {
                UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6)
                    .fill(Theme.warn)
                    .frame(width: 3)
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.dimText)
        .accessibilityLabel(help)
    }
}

/// "N lines · K secrets removed"; click to see exactly what is sent.
struct AIAttachmentChip: View {
    let attachment: AIAttachment
    let onRemove: (() -> Void)?
    @State private var expanded = Self.startExpanded

    private static var startExpanded: Bool {
        #if DEBUG
        AIPanelDemo.chipsStartExpanded
        #else
        false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 10)
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10))
                Text(attachment.summary)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove")
                }
            }
            .foregroundStyle(Theme.dimText)
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            if expanded {
                ScrollView([.vertical, .horizontal]) {
                    Text(attachment.text)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.tabText.opacity(0.85))
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.tabActive))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background { ControlFill(zone: .sidebar, cornerRadius: 6) }
    }
}

// MARK: - Composer

private struct AIComposer: View {
    let session: UUID
    let conversation: AIConversation
    @ObservedObject private var ai = AIPanelModel.shared
    @State private var height: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(conversation.pending) { attachment in
                AIAttachmentChip(attachment: attachment) {
                    ai.removeAttachment(attachment.id, from: session)
                }
            }
            if let notice = conversation.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dimText)
                    .padding(.horizontal, 2)
            }
            VStack(spacing: 4) {
                ZStack(alignment: .topLeading) {
                    if conversation.draft.isEmpty {
                        Text("Ask \(conversation.provider.label)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.dimText.opacity(0.8))
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    AIComposerTextView(
                        text: Binding(get: { conversation.draft }, set: { ai.setDraft($0, for: session) }),
                        height: $height,
                        onSend: { ai.send(for: session) })
                        .frame(height: min(max(height, 18), 120))
                        .id(session)
                }
                HStack(spacing: 2) {
                    iconButton("selection.pin.in.out", help: "Attach Selection") { ai.attachSelection(for: session) }
                    iconButton("text.append", help: "Attach New Output") { ai.attachTail(for: session) }
                    Spacer()
                    if conversation.running {
                        iconButton("stop.circle.fill", help: "Stop", size: 17, tint: Theme.tabText) { ai.stop(for: session) }
                    } else {
                        iconButton("arrow.up.circle.fill", help: "Send (Return)", size: 17,
                                   tint: ai.canSend(session) ? Theme.accent : Theme.dimText.opacity(0.5)) {
                            ai.send(for: session)
                        }
                        .disabled(!ai.canSend(session))
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(ControlFill(zone: .sidebar, cornerRadius: 9))
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    private func iconButton(_ symbol: String, help: String, size: CGFloat = 12.5, tint: Color = Theme.dimText,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(tint)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
    }
}

/// Multi-line field: Return sends, ⇧Return (or ⌥Return) is a new line.
private struct AIComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 12.5)
        textView.textColor = NSColor(Theme.tabText)
        textView.insertionPointColor = NSColor(Theme.accent)
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.textContainer?.lineFragmentPadding = 5
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.measure()
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIComposerTextView
        weak var textView: NSTextView?

        init(_ parent: AIComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            measure()
        }

        func measure() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let h = layout.usedRect(for: container).height + 2
            if abs(h - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = h }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if textView.hasMarkedText() { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.onSend()
            return true
        }
    }
}
