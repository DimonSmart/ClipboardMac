import AppKit
import HistoryCore
import HistoryServices
import HistoryInfrastructure

@MainActor final class AppController: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private let clipboard = SystemClipboard()
    private let shortcut = GlobalShortcut()
    private let targetPort = SystemPasteTarget()
    private var history: SQLiteHistory!
    private var capture: CaptureService!
    private var paste: PasteService<SystemPasteTarget>!
    private var panel: HistoryPanel!
    private var settings: SettingsController!
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var timer: Timer?
    private var entries: [HistoryEntry] = []
    private var lastExternalSource: String?
    private var actionAccepted = false
    private var opening = false
    private var toast: NSPanel?
    private var pauseItem: NSMenuItem!
    private var storagePath = ""
    private var lastError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let bundle = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            existing.activate(); NSApp.terminate(nil); return
        }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            storagePath = support.appendingPathComponent("ClipboardMac/history.sqlite").path
            history = try SQLiteHistory(path: storagePath)
        } catch { showError(error); NSApp.terminate(nil); return }
        capture = CaptureService(clipboard: clipboard, history: history)
        capture.paused = preferences.paused; capture.limit = preferences.limit
        capture.excludedSources = Set(preferences.exclusions)
        paste = PasteService(capture: capture, port: targetPort)
        panel = HistoryPanel()
        panel.onAction = { [weak self] entry, copyOnly in self?.choose(entry, copyOnly: copyOnly) }
        panel.onPin = { [weak self] entry in
            self?.mutate { [weak self] in
                guard let self else { return }
                try await history.setPinned(entry.id, pinned: entry.pinnedAt == nil, at: Date(), limit: preferences.limit)
            }
        }
        panel.onDelete = { [weak self] entry in self?.mutate { [weak self] in try await self?.history.delete(entry.id) } }
        panel.onSettings = { [weak self] in self?.openSettings() }
        settings = SettingsController(preferences: preferences, clipboard: clipboard, storagePath: storagePath)
        settings.reportError = { [weak self] in self?.showError($0) }
        settings.changeShortcut = { [weak self] value in
            guard let self, preferences.shortcut != value else { return }
            try shortcut.register(value); preferences.shortcut = value
        }
        settings.changePause = { [weak self] value in self?.setPaused(value) }
        settings.changeExclusions = { [weak self] values in
            self?.preferences.exclusions = values; self?.capture.excludedSources = Set(values)
        }
        settings.changeLimit = { [weak self] value in
            guard let self else { return }
            try await history.applyLimit(value)
            preferences.limit = value; capture.limit = value
            try await reload()
        }
        settings.clear = { [weak self] all in
            guard let self else { return }
            try await history.clear(includingPins: all); try await reload(); try await history.maintain()
        }
        shortcut.onPress = { [weak self] in self?.toggleHistory() }
        buildMenus()
        do { try shortcut.register(preferences.shortcut) }
        catch { showError(error) }
        recordFrontmost()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshSettings), name: NSApplication.didBecomeActiveNotification, object: nil)
        Task { @MainActor in
            do { try await history.applyLimit(preferences.limit); try await reload(); try await history.maintain() }
            catch { showError(error) }
            timer = Timer(timeInterval: 0.5, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            RunLoop.main.add(timer!, forMode: .common)
            if !preferences.welcomed || ProcessInfo.processInfo.arguments.contains("--settings") { preferences.welcomed = true; openSettings() }
        }
    }
    private var statusText: String {
        if let lastError { return lastError }
        if preferences.paused { return "Capture paused · saved history is available" }
        if clipboard.permission != .allowed { return "Clipboard Access Required · open Settings for guidance" }
        return SystemPasteTarget.accessibilityGranted ? "Local history · automatic paste available" : "Local history · Copy Only available (Accessibility disabled)"
    }
    private func buildMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Open History", action: #selector(toggleHistory), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Quit ClipboardMac", action: #selector(quit), keyEquivalent: "q").target = self
        let editItem = NSMenuItem(); editItem.title = "Edit"; main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (title, selector, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipboardMac")!
        icon.isTemplate = true; statusItem.button?.image = icon
        statusItem.button?.setAccessibilityLabel("ClipboardMac history")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let menu = NSMenu()
        menu.addItem(withTitle: "Open History", action: #selector(toggleHistory), keyEquivalent: "").target = self
        pauseItem = menu.addItem(withTitle: "Pause Capture", action: #selector(togglePause), keyEquivalent: ""); pauseItem.target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Recent History", action: #selector(clearRecent), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ClipboardMac", action: #selector(quit), keyEquivalent: "").target = self
        statusMenu = menu
        updateStatus()
    }
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { toggleHistory(); return }
        if event.type == .rightMouseUp {
            statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
        } else {
            toggleHistory()
        }
    }
    private func updateStatus() {
        pauseItem?.title = preferences.paused ? "Resume Capture" : "Pause Capture"
        statusItem?.button?.toolTip = statusText
    }
    @objc private func tick() {
        updateStatus()
        Task { @MainActor in
            do {
                if try await capture.tick(sourceFallback: lastExternalSource) { lastError = nil; try await reload() }
            } catch { lastError = error.localizedDescription; updateStatus() }
        }
    }
    private func reload() async throws {
        entries = try await history.entries()
        if panel.isVisible { panel.refresh(entries: entries, status: statusText) }
        updateStatus()
    }
    @objc private func toggleHistory() {
        guard !paste.busy, !actionAccepted else { return }
        if panel.isVisible { panel.hide(); return }
        guard !opening else { return }
        opening = true
        // Capture before activating the panel or awaiting storage.
        paste.prepare()
        recordFrontmost()
        Task { @MainActor in
            defer { opening = false }
            do { try await reload(); panel.open(entries: entries, status: statusText) }
            catch { showError(error) }
        }
    }
    private func choose(_ entry: HistoryEntry, copyOnly: Bool) {
        guard panel.isVisible, !actionAccepted else { return }
        actionAccepted = true
        Task { @MainActor in
            defer { actionAccepted = false }
            do {
                if let outcome = try await paste.perform(entry.text, copyOnly: copyOnly, hide: { panel.hide() }), outcome == .copiedOnly {
                    showToast("Copied. Press Cmd+V to paste")
                }
            } catch { showError(error) }
        }
    }
    private func mutate(_ action: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await action(); try await reload() }
            catch { showError(error) }
        }
    }
    @objc private func clearRecent() {
        mutate { [weak self] in
            guard let self else { return }
            try await history.clear(includingPins: false); try await history.maintain()
        }
    }
    @objc private func togglePause() { setPaused(!preferences.paused) }
    private func setPaused(_ value: Bool) { preferences.paused = value; capture.paused = value; updateStatus(); settings.refresh() }
    @objc private func openSettings() { panel?.hide(); settings.open() }
    @objc private func refreshSettings() { settings?.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalSource = app.bundleIdentifier
    }
    private func recordFrontmost() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalSource = app.bundleIdentifier
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if panel != nil { toggleHistory() }; return false
    }
    private func showError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "ClipboardMac"; alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning; alert.runModal()
    }
    private func showToast(_ message: String) {
        toast?.orderOut(nil)
        let toast = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 58), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let root = NSVisualEffectView(); root.material = .hudWindow; root.state = .active
        let text = NSTextField(labelWithString: message); text.alignment = .center
        text.frame = NSRect(x: 12, y: 19, width: 316, height: 20); root.addSubview(text)
        toast.contentView = root; toast.level = .floating; toast.center(); toast.orderFrontRegardless()
        self.toast = toast
        Task { @MainActor [weak self, weak toast] in
            do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
            toast?.orderOut(nil)
            if self?.toast === toast { self?.toast = nil }
        }
    }
}
