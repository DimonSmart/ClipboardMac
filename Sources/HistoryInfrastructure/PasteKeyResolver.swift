import AppKit
@preconcurrency import Carbon

/// Resolve Command-V in the active layout, including layouts that remap Command.
@MainActor public enum PasteKeyResolver {
    public static func current() -> CGKeyCode? {
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        return keyCode(in: source)
    }
    public static func keyCode(in source: TISInputSource) -> CGKeyCode? {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for key in UInt16(0)..<UInt16(128) {
            var deadKey: UInt32 = 0
            var length: Int = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let result = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown), UInt32(cmdKey >> 8), UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey, 8, &length, &characters)
            if result == noErr, length == 1, characters[0] == 118 || characters[0] == 86 { return key }
        }
        return nil
    }
}
