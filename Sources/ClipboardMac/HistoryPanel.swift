import AppKit
import HistoryCore

@MainActor private final class HistoryWindow: NSPanel {
    var handleKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor private final class SelectionRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

@MainActor final class HistoryPanel: NSObject, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private enum Row { case heading(String), entry(HistoryEntry) }
    private let panel: HistoryWindow
    private let search = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "Copy text to start your history")
    private var rows: [Row] = []
    private var entries: [HistoryEntry] = []
    private var searchTask: Task<Void, Never>?
    var onAction: ((HistoryEntry, Bool) -> Void)?
    var onPin: ((HistoryEntry) -> Void)?
    var onDelete: ((HistoryEntry) -> Void)?
    var onSettings: (() -> Void)?
    var onDismiss: (() -> Void)?
    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = HistoryWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.title = "Clipboard History"; panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.handleKey = { [weak self] in self?.handle($0) ?? false }
        let root = NSVisualEffectView()
        root.material = .popover; root.blendingMode = .behindWindow; root.state = .active
        panel.contentView = root
        let title = NSTextField(labelWithString: "Clipboard History")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!, target: self, action: #selector(openSettings))
        settings.bezelStyle = .accessoryBarAction
        let header = NSStackView(views: [title, NSView(), settings]); header.distribution = .fill
        search.placeholderString = "Search your clipboard…"
        search.setAccessibilityLabel("Search clipboard history")
        search.delegate = self; search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.width = 600; column.resizingMask = .autoresizingMask
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.frame = NSRect(x: 0, y: 0, width: 600, height: 0)
        table.autoresizingMask = [.width]
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 66
        table.style = .plain; table.intercellSpacing = NSSize(width: 0, height: 4)
        table.backgroundColor = .clear
        table.delegate = self; table.dataSource = self
        table.target = self; table.action = #selector(clicked)
        table.setAccessibilityLabel("Clipboard history entries")
        let menu = NSMenu(); menu.delegate = self; table.menu = menu
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.borderType = .noBorder
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        empty.textColor = .secondaryLabelColor; empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        let footer = NSTextField(labelWithString: "↑↓ Navigate   ↩ Paste   ⌘↩ Copy   ⌘P Pin   ⌘⌫ Delete   ⌘Y Preview")
        footer.font = .systemFont(ofSize: 10); footer.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [header, search, status, scroll, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack); root.addSubview(empty)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        for view in [header, search, status, scroll, footer] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        search.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }
    func open(entries: [HistoryEntry], status: String) {
        self.entries = entries; self.status.stringValue = status
        search.stringValue = ""
        updateRows(HistoryRules.display(entries, query: ""), preserving: nil)
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let screen {
            let visible = screen.visibleFrame
            let size = NSSize(width: min(640, visible.width - 32), height: min(500, visible.height - 32))
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: false)
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        table.sizeLastColumnToFit()
        NSApp.activate(); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(search)
    }
    func hide() { panel.orderOut(nil) }
    func refresh(entries: [HistoryEntry], status: String) {
        self.entries = entries; self.status.stringValue = status
        filter(preserving: selected?.id)
    }
    private var selected: HistoryEntry? {
        guard table.selectedRow >= 0, table.selectedRow < rows.count, case let .entry(entry) = rows[table.selectedRow] else { return nil }
        return entry
    }
    func controlTextDidChange(_ notification: Notification) { filter(preserving: nil) }
    private func filter(preserving id: UUID?) {
        searchTask?.cancel()
        let current = entries, query = search.stringValue
        searchTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { HistoryRules.display(current, query: query) }.value
            guard !Task.isCancelled else { return }
            self?.updateRows(result, preserving: id)
        }
    }
    private func updateRows(_ result: [HistoryEntry], preserving id: UUID?) {
        rows = []
        let pinned = result.filter { $0.pinnedAt != nil }, recent = result.filter { $0.pinnedAt == nil }
        if !pinned.isEmpty { rows.append(.heading("Pinned · \(pinned.count)")); rows += pinned.map(Row.entry) }
        if !recent.isEmpty { rows.append(.heading("Recent · \(recent.count)")); rows += recent.map(Row.entry) }
        empty.stringValue = search.stringValue.isEmpty ? "Copy text to start your history" : "No matches"
        empty.isHidden = !result.isEmpty
        table.reloadData()
        let match = rows.firstIndex { if case let .entry(entry) = $0 { return id == nil || entry.id == id }; return false }
        let first = rows.firstIndex { if case .entry = $0 { return true }; return false }
        if let row = match ?? first { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRow() }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .heading = rows[row] { return 24 }; return 66 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .entry = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .heading(let text):
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = .secondaryLabelColor
            return label
        case .entry(let entry):
            let cell = NSTableCellView()
            // Limit rendering cost; the complete UTF-8 value stays in the repository.
            let preview = NSTextField(wrappingLabelWithString: String(entry.text.prefix(260)))
            preview.maximumNumberOfLines = 2; preview.lineBreakMode = .byTruncatingTail
            preview.font = .systemFont(ofSize: 13)
            let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .abbreviated
            let context = NSTextField(labelWithString: [entry.source, formatter.localizedString(for: entry.copiedAt, relativeTo: Date())].compactMap { $0 }.joined(separator: " · "))
            context.font = .systemFont(ofSize: 10); context.textColor = .secondaryLabelColor
            context.lineBreakMode = .byTruncatingMiddle
            let pin = NSButton(image: NSImage(systemSymbolName: entry.pinnedAt == nil ? "pin" : "pin.fill", accessibilityDescription: entry.pinnedAt == nil ? "Pin entry" : "Unpin entry")!, target: self, action: #selector(pinClicked(_:)))
            pin.tag = row; pin.bezelStyle = .accessoryBarAction
            pin.widthAnchor.constraint(equalToConstant: 28).isActive = true
            let text = NSStackView(views: [preview, context]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 4
            let stack = NSStackView(views: [text, pin]); stack.spacing = 10; stack.distribution = .fill
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            pin.setContentHuggingPriority(.required, for: .horizontal)
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                preview.widthAnchor.constraint(equalTo: text.widthAnchor), context.widthAnchor.constraint(equalTo: text.widthAnchor)
            ])
            return cell
        }
    }
    @objc private func clicked() {
        guard isVisible, table.clickedRow >= 0, table.clickedRow < rows.count,
              case let .entry(entry) = rows[table.clickedRow] else { return }
        onAction?(entry, false)
    }
    @objc private func pinClicked(_ button: NSButton) {
        guard button.tag < rows.count, case let .entry(entry) = rows[button.tag] else { return }
        onPin?(entry)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if table.clickedRow >= 0, table.clickedRow < rows.count, case .entry = rows[table.clickedRow] {
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        }
        menu.removeAllItems()
        guard let selected else { return }
        for (title, selector) in [("Paste", #selector(pasteSelection)), ("Copy Only", #selector(copySelection)), (selected.pinnedAt == nil ? "Pin" : "Unpin", #selector(pinSelection)), ("Show Full Content", #selector(previewSelection)), ("Delete", #selector(deleteSelection))] {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: ""); item.target = self
        }
    }
    private func handle(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: dismiss(); return true
        case 125, 126:
            let direction = event.keyCode == 125 ? 1 : -1
            var row = table.selectedRow + direction
            while rows.indices.contains(row) {
                if case .entry = rows[row] { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row); break }
                row += direction
            }
            return true
        case 36, 76: if let selected { onAction?(selected, command) }; return true
        case 35 where command: pinSelection(); return true
        case 51 where command: deleteSelection(); return true
        case 16 where command: previewSelection(); return true
        default: return false
        }
    }
    @objc private func pasteSelection() { if let selected { onAction?(selected, false) } }
    @objc private func copySelection() { if let selected { onAction?(selected, true) } }
    @objc private func pinSelection() { if let selected { onPin?(selected) } }
    @objc private func deleteSelection() { if let selected { onDelete?(selected) } }
    @objc private func openSettings() { dismiss(); onSettings?() }
    @objc private func previewSelection() {
        guard let selected else { return }
        let alert = NSAlert(); alert.messageText = "Full Content"; alert.addButton(withTitle: "Close")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = selected.text; text.isVerticallyResizable = true
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("Full clipboard entry, read only")
        scroll.documentView = text; alert.accessoryView = scroll
        alert.beginSheetModal(for: panel)
    }
    private func dismiss() { hide(); onDismiss?() }
    func windowDidResignKey(_ notification: Notification) {
        guard panel.attachedSheet == nil, panel.isVisible else { return }
        dismiss()
    }
}
