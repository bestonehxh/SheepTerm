// SheepVTRender — the find bar.
//
// A small panel the terminal view floats at its top-trailing corner: a search
// field, the three option toggles every macOS find bar has (Aa = case, .* =
// regular expression, ab = whole word), "n of m", ‹ ›, and a close button.
// It owns no search state — it reports what the user asked for and the view
// drives `SearchEngine`.
//
// Typing is debounced (50 ms) so a 10,000-line scrollback is not searched once
// per keystroke; setting `searchText` in code applies at once.

import AppKit

public final class FindBar: NSView, NSSearchFieldDelegate {

    /// Natural height of the bar; the view uses it to place itself.
    public static let barHeight: CGFloat = 30
    /// Natural width. Wide enough for a search field and the controls.
    public static let barWidth: CGFloat = 340

    // MARK: - Callbacks

    /// The term or the options changed (already debounced).
    public var onChange: ((FindBar) -> Void)?
    public var onNext: ((FindBar) -> Void)?
    public var onPrevious: ((FindBar) -> Void)?
    /// Esc or the close button: hide me and give the terminal the keyboard back.
    public var onClose: ((FindBar) -> Void)?

    // MARK: - State

    public var searchText: String {
        get { field.stringValue }
        set {
            guard newValue != field.stringValue else { return }
            field.stringValue = newValue
            fireChange()
        }
    }

    public var options: SearchOptions {
        get {
            SearchOptions(caseSensitive: caseButton.state == .on,
                          regex: regexButton.state == .on,
                          wholeWord: wordButton.state == .on)
        }
        set {
            caseButton.state = newValue.caseSensitive ? .on : .off
            regexButton.state = newValue.regex ? .on : .off
            wordButton.state = newValue.wholeWord ? .on : .off
        }
    }

    /// How long typing waits before the search runs. Tests set it to 0.
    public var debounceInterval: TimeInterval = 0.05

    // MARK: - Subviews

    private let field = NSSearchField()
    private let caseButton = FindBar.toggle(title: "Aa", tip: "Match case")
    private let regexButton = FindBar.toggle(title: ".*", tip: "Regular expression")
    private let wordButton = FindBar.toggle(title: "ab", tip: "Whole word")
    private let countLabel = NSTextField(labelWithString: "")
    /// Wide enough for the longest thing the label can ever say, measured in
    /// the font it is drawn in rather than guessed. It was a hardcoded 62,
    /// which fitted every state that existed at the time and then silently
    /// clipped "not supported" (68.2 pt) when the regex messages were added —
    /// a defect no test can see and every user can. Deriving it from the words
    /// themselves means the next message cannot reintroduce it.
    private static let countWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: 10)
        let widest = ["not found", "not supported", "bad pattern", "too complex",
                      "1000+ found", "1000 of 1000+"]
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 62
        return ceil(widest) + 2      // the label is right-aligned; 2 pt of air
    }()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    private var pendingChange: DispatchWorkItem?

    // MARK: - Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private static func toggle(title: String, tip: String) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.setButtonType(.pushOnPushOff)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        b.toolTip = tip
        return b
    }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = false
        field.controlSize = .small
        field.font = .systemFont(ofSize: 11)
        field.placeholderString = "Find"
        field.delegate = self
        field.target = self
        field.action = #selector(searchFieldAction(_:))
        addSubview(field)

        for b in [caseButton, regexButton, wordButton] {
            b.target = self
            b.action = #selector(optionToggled(_:))
            addSubview(b)
        }

        countLabel.font = .systemFont(ofSize: 10)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        addSubview(countLabel)

        configure(previousButton, symbol: "chevron.left", fallback: "‹",
                  tip: "Previous match", action: #selector(previousAction(_:)))
        configure(nextButton, symbol: "chevron.right", fallback: "›",
                  tip: "Next match", action: #selector(nextAction(_:)))
        configure(closeButton, symbol: "xmark", fallback: "✕",
                  tip: "Close", action: #selector(closeAction(_:)))
    }

    private func configure(_ button: NSButton, symbol: String, fallback: String,
                           tip: String, action: Selector) {
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.title = fallback
        }
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.isBordered = false
        button.toolTip = tip
        button.target = self
        button.action = action
        addSubview(button)
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        let h: CGFloat = 20
        let y = (bounds.height - h) / 2
        let pad: CGFloat = 6
        var x = bounds.width - pad

        for button in [closeButton, nextButton, previousButton] {
            let w: CGFloat = 20
            x -= w
            button.frame = CGRect(x: x, y: y, width: w, height: h)
            x -= 2
        }
        let countWidth = FindBar.countWidth
        x -= countWidth
        countLabel.frame = CGRect(x: x, y: y - 1, width: countWidth, height: h)
        x -= 4
        for button in [wordButton, regexButton, caseButton] {
            let w: CGFloat = 26
            x -= w
            button.frame = CGRect(x: x, y: y, width: w, height: h)
            x -= 2
        }
        field.frame = CGRect(x: pad, y: y, width: max(40, x - pad - 2), height: h)
    }

    // MARK: - Status

    /// "3 of 27", or "not found" / "" when there is nothing to say.
    ///
    /// `problem` is one of two states that are not about counting: the pattern
    /// was refused, so "not found" would be a lie — nobody looked.
    ///
    /// `incomplete` is the other, and it is the same lie one step later: the
    /// engine bounds its work per line, so a pattern that costs too much stops
    /// PART WAY THROUGH and the rest of the text is never examined. With no
    /// match found so far that reads "not found" — about text the search never
    /// reached (`a{1000}b` over 200,000 `a`s followed by a `b` really does
    /// match). It reuses the "too complex" wording the compile-time refusal
    /// uses, because it is the same thing said at a different moment and the
    /// advice is the same. With some matches found it keeps the count and the
    /// "+", which already means "at least this many".
    public func setMatchCount(current: Int?, total: Int, limited: Bool = false,
                              problem: LinearRegex.Failure? = nil,
                              incomplete: Bool = false) {
        if searchText.isEmpty {
            countLabel.stringValue = ""
        } else if let problem {
            switch problem {
            case .unsupported:
                countLabel.stringValue = "not supported"
                // Says what to do instead, because the answer is nearly always
                // the same one: `\b` does what a negative lookahead is used for
                // in a search box (`Gi0/1\b` rather than `Gi0/1(?!\d)`).
                countLabel.toolTip = "Backreferences (\\1) and lookaround ((?=, (?!, (?<=, (?<!) "
                    + "are not supported. Word boundaries (\\b) cover most uses: "
                    + "Gi0/1\\b instead of Gi0/1(?!\\d)."
            case .tooBig:
                countLabel.stringValue = "too complex"
                countLabel.toolTip = "This pattern expands to more steps than a search may take. "
                    + "Shorten a repetition count."
            case .malformed:
                // NOT "not found": nothing was searched for. A stray "[" used
                // to read as "your text is not here".
                countLabel.stringValue = "bad pattern"
                countLabel.toolTip = "This is not a valid regular expression."
            }
        } else if total == 0 && incomplete {
            // Nothing found in the part that WAS searched, and the search did
            // not finish — the one case where "not found" is not an answer.
            countLabel.stringValue = "too complex"
            countLabel.toolTip = "This pattern costs more steps than a search may take, so it "
                + "stopped before the end of the text. Matches beyond that point were not "
                + "looked for. Shorten a repetition count or search for something simpler."
        } else if total == 0 {
            countLabel.stringValue = "not found"
        } else if let current {
            countLabel.stringValue = "\(current) of \(total)\(limited || incomplete ? "+" : "")"
        } else {
            countLabel.stringValue = "\(total)\(limited || incomplete ? "+" : "") found"
        }
        if problem == nil && !(total == 0 && incomplete) { countLabel.toolTip = nil }
    }

    /// Room the count label has, so a test can prove no message clips.
    public var countLabelWidth: CGFloat { countLabel.frame.width }

    /// What the count label currently reads (tests, accessibility).
    public var statusText: String { countLabel.stringValue }

    /// The explanation behind the current status, when there is one.
    public var statusTooltip: String? { countLabel.toolTip }

    public func focusSearchField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    // MARK: - Actions

    @objc private func optionToggled(_ sender: NSButton) { fireChange() }

    @objc private func searchFieldAction(_ sender: Any?) {
        // Return in the field = find next.
        flushPendingChange()
        onNext?(self)
    }

    @objc private func nextAction(_ sender: Any?) { onNext?(self) }
    @objc private func previousAction(_ sender: Any?) { onPrevious?(self) }
    @objc private func closeAction(_ sender: Any?) { onClose?(self) }

    public override func cancelOperation(_ sender: Any?) { onClose?(self) }

    // MARK: - NSSearchFieldDelegate

    public func controlTextDidChange(_ obj: Notification) {
        scheduleChange()
    }

    public func control(_ control: NSControl,
                        textView: NSTextView,
                        doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?(self)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // A pending edit lands on the first match by itself; a second
            // "next" here would skip it.
            if !flushPendingChange() { onNext?(self) }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            if !flushPendingChange() { onPrevious?(self) }
            return true
        default:
            return false
        }
    }

    // MARK: - Debounce

    private func scheduleChange() {
        pendingChange?.cancel()
        guard debounceInterval > 0 else { fireChange(); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingChange = nil
            self.onChange?(self)
        }
        pendingChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Run a pending debounced search right now (Return must not wait 50 ms).
    /// Runs a debounced edit now. Returns true when there was one.
    @discardableResult
    public func flushPendingChange() -> Bool {
        guard let work = pendingChange else { return false }
        work.cancel()
        pendingChange = nil
        onChange?(self)
        return true
    }

    private func fireChange() {
        pendingChange?.cancel()
        pendingChange = nil
        onChange?(self)
    }
}
