import AppKit

/// One row of a drop-down list (address suggestions, saved logins, tab search).
/// SheepWeb (from another Sheep app): SheepTerm's web-tab URL field uses the same list.
public struct SuggestionItem {
    public var symbol: String?
    public var image: NSImage?
    public var title: String
    public var detail: String?
    /// Small grey text at the right ("Switch to Tab", "Favorite").
    public var badge: String?
    /// A second line under the title (saved logins: the site).
    public var subtitle: String?
    /// The icon sits in a rounded tile (saved logins, as Safari).
    public var tiled = false
    /// A section title ("Open Tabs"), not a choice.
    public var isSection = false

    public static func section(_ title: String) -> SuggestionItem {
        var item = SuggestionItem(title: title)
        item.isSection = true
        return item
    }

    public init(symbol: String? = nil, image: NSImage? = nil, title: String, detail: String? = nil, badge: String? = nil,
         subtitle: String? = nil, tiled: Bool = false) {
        self.symbol = symbol
        self.image = image
        self.title = title
        self.detail = detail
        self.badge = badge
        self.subtitle = subtitle
        self.tiled = tiled
    }
}

/// A glass drop-down that floats under a field without taking the keyboard from it. The field keeps
/// typing; the owner moves the selection with ↑/↓ and picks with Return, or the user clicks a row.
public final class SuggestionPanel: NSPanel {
    public var onPick: ((Int) -> Void)?
    public private(set) var items: [SuggestionItem] = []
    public private(set) var selectedIndex: Int?
    private let glass = NSGlassEffectView()
    private let stack = NSStackView()
    private var rows: [SuggestionRow] = []
    public var footer: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            rebuild()
        }
    }
    /// Above the rows (the tab search field), with its height.
    public var header: (view: NSView, height: CGFloat)? {
        didSet {
            oldValue?.view.removeFromSuperview()
            rebuild()
        }
    }
    /// Takes the keyboard (the tab search panel types into its own field).
    public var keyable = false
    public var onClose: (() -> Void)?

    public init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .utilityWindow

        glass.cornerRadius = 16
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The list fills the glass, and the glass fills the panel.
        let inner = NSView()
        inner.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            stack.topAnchor.constraint(equalTo: inner.topAnchor),
        ])
        glass.contentView = inner
        // The window is rectangular; clip it to the glass's rounded shape so the system's border and shadow
        // follow the rounded panel (a key panel showed a black square frame otherwise).
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)
        contentView = container
    }

    public override var canBecomeKey: Bool { keyable }

    public override func resignKey() {
        super.resignKey()
        guard keyable else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isKeyWindow else { return }
            self.hide()
            self.onClose?()
        }
    }

    public override func cancelOperation(_ sender: Any?) {
        hide()
        onClose?()
    }
    public override var canBecomeMain: Bool { false }

    public var isShowing: Bool { isVisible && !items.isEmpty }

    /// Shows the list under `anchor` (a rect in screen coordinates) with the given width.
    public func show(_ items: [SuggestionItem], below anchor: NSRect, width: CGFloat, parent: NSWindow, select: Int? = 0) {
        self.items = items
        selectedIndex = items.isEmpty ? nil : select
        guard !items.isEmpty || footer != nil || header != nil else { return hide() }
        if let select, items.indices.contains(select), items[select].isSection {
            selectedIndex = items.indices.dropFirst(select).first { !items[$0].isSection }
        }
        rebuild()
        let height = CGFloat(rows.count) * 1 + rows.reduce(0) { $0 + $1.height } + (footer != nil ? 34 : 0)
            + (header?.height ?? 0) + 12
        setFrame(NSRect(x: anchor.minX, y: anchor.minY - 6 - height, width: width, height: height), display: true)
        glass.frame = contentView?.bounds ?? .zero
        contentView?.displayIfNeeded()
        invalidateShadow()
        if parent.childWindows?.contains(self) != true { parent.addChildWindow(self, ordered: .above) }
        orderFront(nil)
    }

    public func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
        items = []
        selectedIndex = nil
    }

    public func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        var next = selectedIndex ?? (delta > 0 ? -1 : items.count)
        for _ in items.indices {
            next = (next + delta + items.count) % items.count
            if !items[next].isSection { break }
        }
        selectedIndex = next
        rows.enumerated().forEach { $0.element.isSelected = $0.offset == selectedIndex }
    }

    fileprivate func hover(_ row: SuggestionRow) {
        guard let index = rows.firstIndex(of: row), items.indices.contains(index), !items[index].isSection else { return }
        selectedIndex = index
        rows.enumerated().forEach { $0.element.isSelected = $0.offset == index }
    }

    fileprivate func pick(_ row: SuggestionRow) {
        guard let index = rows.firstIndex(of: row), items.indices.contains(index), !items[index].isSection else { return }
        onPick?(index)
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let header {
            stack.addArrangedSubview(header.view)
            header.view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
            header.view.heightAnchor.constraint(equalToConstant: header.height).isActive = true
        }
        rows = items.enumerated().map { index, item in
            let row = SuggestionRow(item: item, panel: self)
            row.isSelected = index == selectedIndex
            return row
        }
        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
        }
        if let footer {
            stack.addArrangedSubview(footer)
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
        }
    }
}

private final class SuggestionRow: NSView {
    private weak var panel: SuggestionPanel?
    let isTwoLine: Bool
    let isSection: Bool
    var height: CGFloat { isSection ? 30 : isTwoLine ? 44 : 30 }
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    var isSelected = false { didSet { update() } }

    init(item: SuggestionItem, panel: SuggestionPanel) {
        self.panel = panel
        isTwoLine = item.subtitle != nil
        isSection = item.isSection
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        if let image = item.image {
            icon.image = image
        } else if let symbol = item.symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.stringValue = item.title
        title.font = .systemFont(ofSize: 13, weight: item.subtitle == nil ? .regular : .semibold)
        title.lineBreakMode = .byTruncatingTail
        detail.stringValue = item.subtitle ?? item.detail.map { "— " + $0 } ?? ""
        detail.font = .systemFont(ofSize: 12.5)
        detail.lineBreakMode = .byTruncatingTail
        badge.stringValue = item.badge ?? ""
        badge.font = .systemFont(ofSize: 11.5, weight: .medium)
        for view in [icon, title, detail, badge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        if item.isSection {
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            title.textColor = .secondaryLabelColor
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 30),
                title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            ])
            return
        } else if item.subtitle != nil {
            // Two lines (a saved login): a tiled icon, the user name over the site.
            let size: CGFloat = item.tiled ? 30 : 20
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 44),
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: size),
                icon.heightAnchor.constraint(equalToConstant: size),
                title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
                title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
                title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
                detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
                detail.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
                badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            detail.font = .systemFont(ofSize: 11.5)
            if item.tiled {
                icon.wantsLayer = true
                icon.layer?.cornerRadius = 8
                icon.layer?.cornerCurve = .continuous
                icon.layer?.masksToBounds = true
            }
        } else {
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 30),
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
                title.centerYAnchor.constraint(equalTo: centerYAnchor),
                detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 5),
                detail.centerYAnchor.constraint(equalTo: centerYAnchor),
                detail.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
                title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
                detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
                badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        guard !isSection else { return }
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : nil
        title.textColor = isSelected ? .white : .labelColor
        detail.textColor = isSelected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        badge.textColor = isSelected ? NSColor.white.withAlphaComponent(0.85) : .tertiaryLabelColor
        icon.contentTintColor = isSelected ? .white : .secondaryLabelColor
    }

    override func mouseEntered(with event: NSEvent) { panel?.hover(self) }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { panel?.pick(self) }
    }
}
