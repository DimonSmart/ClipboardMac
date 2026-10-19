import Foundation

public struct Shortcut: Codable, Sendable, Equatable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let label: String
    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
}

@MainActor public final class Preferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var limit: Int {
        get { defaults.object(forKey: "historyLimit") == nil ? 500 : min(2000, max(50, defaults.integer(forKey: "historyLimit"))) }
        set { defaults.set(min(2000, max(50, newValue)), forKey: "historyLimit") }
    }
    public var paused: Bool { get { defaults.bool(forKey: "paused") } set { defaults.set(newValue, forKey: "paused") } }
    public var exclusions: [String] { get { defaults.stringArray(forKey: "exclusions") ?? [] } set { defaults.set(newValue, forKey: "exclusions") } }
    public var welcomed: Bool { get { defaults.bool(forKey: "welcomed") } set { defaults.set(newValue, forKey: "welcomed") } }
    public var shortcut: Shortcut? {
        get { defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "shortcut") }
            else { defaults.removeObject(forKey: "shortcut") }
        }
    }
}
