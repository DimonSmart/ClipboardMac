import AppKit
import Carbon

private func hotkeyHandler(_: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let instance = Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { instance.onPress?() }
    return noErr
}

@MainActor public final class GlobalShortcut {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    public var onPress: (() -> Void)?
    public init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotkeyHandler, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    isolated deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
    public func register(_ shortcut: Shortcut?) throws {
        guard let shortcut else {
            if let reference { UnregisterEventHotKey(reference) }; reference = nil; return
        }
        guard shortcut.modifiers & UInt32(cmdKey | controlKey | optionKey) != 0,
              !(shortcut.keyCode == 9 && shortcut.modifiers & UInt32(cmdKey) != 0 && shortcut.modifiers & UInt32(controlKey | optionKey) == 0),
              !(shortcut.modifiers == UInt32(cmdKey) && [0, 6, 7, 8, 12, 13, 17, 31, 35, 37, 45, 46].contains(shortcut.keyCode)) else {
            throw StorageError(message: "Choose a shortcut with Command, Control or Option. Command-V is reserved for Paste.")
        }
        var next: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x434C4950, id: 1), GetApplicationEventTarget(), 0, &next)
        guard result == noErr else { throw StorageError(message: "This shortcut is unavailable. Choose another combination.") }
        if let reference { UnregisterEventHotKey(reference) }
        reference = next
    }
}
