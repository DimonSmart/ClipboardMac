import AppKit
import Carbon
import ServiceManagement
import HistoryInfrastructure

@MainActor final class ShortcutRecorder: NSButton {
    var onRecord: ((Shortcut?) -> Void)?
    var recorded: Shortcut? { didSet { title = recorded?.label ?? "Choose shortcut…" } }
    private var recording = false
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { begin() }
    override func performClick(_ sender: Any?) { begin() }
    private func begin() {
        recording = true; title = "Press shortcut (Esc to cancel)"
        window?.makeFirstResponder(self)
        setAccessibilityLabel("Open History shortcut. Press a key combination.")
    }
    override func keyDown(with event: NSEvent) {
        if !recording {
            if event.keyCode == 49 || event.keyCode == 36 { begin() }
            else { super.keyDown(with: event) }
            return
        }
        if event.keyCode == 53 { recording = false; title = recorded?.label ?? "Choose shortcut…"; return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              ![36, 48, 51, 76, 117, 123, 124, 125, 126].contains(Int(event.keyCode)),
              !(event.keyCode == 9 && flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option)) else {
            title = "Unavailable — use Ctrl/Option + a key"; return
        }
        var modifiers: UInt32 = 0, label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        label += event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
        recording = false
        onRecord?(Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label))
        title = recorded?.label ?? "Choose shortcut…"
    }
}

@MainActor final class SettingsController: NSWindowController {
    let preferences: Preferences
    let clipboard: SystemClipboard
    var changeShortcut: ((Shortcut?) throws -> Void)?
    var changeLimit: ((Int) async throws -> Void)?
    var changePause: ((Bool) -> Void)?
    var changeExclusions: (([String]) -> Void)?
    var clear: ((Bool) async throws -> Void)?
    var reportError: ((Error) -> Void)?
    private let recorder = ShortcutRecorder()
    private let clipboardStatus = NSTextField(wrappingLabelWithString: "")
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let login = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
    private let pause = NSButton(checkboxWithTitle: "Pause clipboard capture", target: nil, action: nil)
    private let limit = NSTextField(string: "500")
    private let exclusions = NSTextView()
    private let limitStatus = NSTextField(labelWithString: "")

    init(preferences: Preferences, clipboard: SystemClipboard, storagePath: String) {
        self.preferences = preferences; self.clipboard = clipboard
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 490), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ClipboardMac Settings"
        super.init(window: window)
        window.isReleasedWhenClosed = false
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            tabs.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            tabs.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            tabs.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)
        ])
        recorder.bezelStyle = .rounded; recorder.recorded = preferences.shortcut
        recorder.onRecord = { [weak self] shortcut in
            guard let self else { return }
            do { try changeShortcut?(shortcut); recorder.recorded = shortcut }
            catch { reportError?(error) }
        }
        login.target = self; login.action = #selector(toggleLogin)
        pause.target = self; pause.action = #selector(togglePause)
        limit.setAccessibilityLabel("Recent history limit, 50 to 2000")
        limit.widthAnchor.constraint(equalToConstant: 100).isActive = true
        limit.stringValue = String(preferences.limit)
        addTab(tabs, "General", views: [
            heading("Clipboard history, one shortcut away"),
            note("Copy text as usual. Open history, search and select an entry. Enter pastes; Command-Enter copies without pasting. Everything stays on this Mac."),
            label("Open History shortcut"), recorder,
            button("Remove shortcut", #selector(removeShortcut)), login, pause,
            label("Recent history limit (50–2000; pins are unlimited)"),
            horizontal([limit, button("Apply limit", #selector(saveLimit))]), limitStatus
        ])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = exclusions
        exclusions.isRichText = false; exclusions.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        exclusions.isVerticallyResizable = true; exclusions.isHorizontallyResizable = false
        exclusions.autoresizingMask = [.width]; exclusions.textContainer?.widthTracksTextView = true
        exclusions.setAccessibilityLabel("Excluded source bundle identifiers, one per line")
        scroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        addTab(tabs, "Privacy", views: [
            clipboardStatus, button("Request Clipboard Access Once", #selector(requestClipboard)),
            button("Open Clipboard Privacy Settings", #selector(clipboardSettings)),
            accessibilityStatus, button("Enable Accessibility for Automatic Paste…", #selector(requestAccessibility)),
            note("Without Accessibility, Copy Only remains available. Concealed, transient and generated clipboard items are ignored. No telemetry or network requests."),
            label("Exclude source apps — exact bundle IDs, one per line"), scroll,
            button("Save exclusions", #selector(saveExclusions))
        ])
        addTab(tabs, "Data", views: [
            heading("Local history"),
            note("Stored in your private Application Support folder. History is not encrypted by this app and is not synchronized through iCloud."),
            note(storagePath),
            button("Clear Recent History", #selector(clearRecent)),
            button("Clear All History and Pins…", #selector(clearAll)),
            note("Clear Recent keeps pinned entries. Clear All requires confirmation and removes every saved entry.")
        ])
        refresh()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func open() { refresh(); showWindow(nil); NSApp.activate(); window?.makeKeyAndOrderFront(nil) }
    func refresh() {
        clipboardStatus.stringValue = clipboard.permission == .allowed ? "Clipboard access: Always Allow" : "Clipboard Access Required. Choose Always Allow in System Settings to capture automatically. Ask and Deny never trigger polling prompts."
        accessibilityStatus.stringValue = SystemPasteTarget.accessibilityGranted ? "Accessibility: enabled" : "Accessibility: disabled — Copy Only available"
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        pause.state = preferences.paused ? .on : .off
        exclusions.string = preferences.exclusions.joined(separator: "\n")
        recorder.recorded = preferences.shortcut
    }
    private func addTab(_ tabs: NSTabView, _ title: String, views: [NSView]) {
        let item = NSTabViewItem(identifier: title); item.label = title
        let container = NSView(), stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20)
        ])
        for view in views where view is NSTextField || view is NSScrollView {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        item.view = container; tabs.addTabViewItem(item)
    }
    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
    private func heading(_ text: String) -> NSTextField { let view = label(text); view.font = .systemFont(ofSize: 18, weight: .semibold); return view }
    private func note(_ text: String) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text); view.font = .systemFont(ofSize: 12); view.textColor = .secondaryLabelColor; return view
    }
    private func button(_ title: String, _ selector: Selector) -> NSButton { let view = NSButton(title: title, target: self, action: selector); view.bezelStyle = .rounded; return view }
    private func horizontal(_ views: [NSView]) -> NSStackView { let view = NSStackView(views: views); view.spacing = 10; return view }
    @objc private func removeShortcut() {
        do { try changeShortcut?(nil); recorder.recorded = nil }
        catch { reportError?(error) }
    }
    @objc private func togglePause() { changePause?(pause.state == .on) }
    @objc private func toggleLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { reportError?(error) }
        refresh()
    }
    @objc private func saveLimit() {
        guard let value = Int(limit.stringValue), (50...2000).contains(value) else { limitStatus.stringValue = "Enter a whole number from 50 through 2000."; return }
        Task { @MainActor in
            do { try await changeLimit?(value); limitStatus.stringValue = "Limit saved." }
            catch { reportError?(error) }
        }
    }
    @objc private func saveExclusions() {
        let values = exclusions.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard values.allSatisfy({ $0.range(of: "^[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)+$", options: .regularExpression) != nil }) else {
            reportError?(StorageError(message: "Enter bundle identifiers such as com.apple.Safari, one per line.")); return
        }
        changeExclusions?(Array(Set(values)).sorted())
    }
    @objc private func requestClipboard() { clipboard.requestAccessOnce(); refresh() }
    @objc private func clipboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!)
    }
    @objc private func requestAccessibility() { SystemPasteTarget.requestAccessibility(); refresh() }
    @objc private func clearRecent() { performClear(false) }
    @objc private func clearAll() {
        let alert = NSAlert(); alert.messageText = "Clear all history and pins?"
        alert.informativeText = "This permanently deletes every saved entry."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Clear All")
        if alert.runModal() == .alertSecondButtonReturn { performClear(true) }
    }
    private func performClear(_ all: Bool) {
        Task { @MainActor in
            do { try await clear?(all) }
            catch { reportError?(error) }
        }
    }
}
