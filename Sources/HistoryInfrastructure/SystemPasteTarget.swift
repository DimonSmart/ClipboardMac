import AppKit
@preconcurrency import ApplicationServices
import HistoryServices

@MainActor public final class SystemPasteTarget: PasteTargetPort {
    public struct Target {
        let app: NSRunningApplication
        let element: AXUIElement
        let window: AXUIElement
    }
    public init() {}
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    public static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func focus(_ app: NSRunningApplication) -> (AXUIElement, AXUIElement)? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let element = attribute(application, kAXFocusedUIElementAttribute),
              let window = attribute(application, kAXFocusedWindowAttribute) else { return nil }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role) == .success,
           role as? String == kAXSecureTextFieldSubrole { return nil }
        return (element, window)
    }
    public func snapshot() -> Target? {
        guard Self.accessibilityGranted, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let (element, window) = focus(app) else { return nil }
        return Target(app: app, element: element, window: window)
    }
    private func confirms(_ target: Target) -> Bool {
        guard Self.accessibilityGranted, !target.app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app.processIdentifier,
              let (element, window) = focus(target.app) else { return false }
        return CFEqual(element, target.element) && CFEqual(window, target.window)
    }
    public func restoreAndConfirm(_ target: Target) async -> Bool {
        guard Self.accessibilityGranted, !target.app.isTerminated else { return false }
        // A different external application means the user deliberately changed targets.
        if let current = NSWorkspace.shared.frontmostApplication,
           current.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           current.processIdentifier != target.app.processIdentifier { return false }
        // Never force an old element/window back into focus: changed focus is a fallback.
        guard let (element, window) = focus(target.app), CFEqual(element, target.element), CFEqual(window, target.window) else { return false }
        guard target.app.activate() else { return false }
        for attempt in 0..<8 {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
            if attempt >= 3 && confirms(target) { return true }
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != target.app.processIdentifier,
               front.processIdentifier != ProcessInfo.processInfo.processIdentifier { return false }
        }
        return false
    }
    public func postPaste(_ target: Target) -> Bool {
        guard confirms(target), let key = PasteKeyResolver.current(), let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        // Revalidate immediately before the single normal system paste shortcut.
        guard confirms(target) else { return false }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }
}
