import Foundation
import HistoryCore

public enum ClipboardPermission: Sendable { case allowed, requiresAccess }
public struct ClipboardSample: Sendable {
    public let change: Int
    public let text: String?
    public let source: String?
    public let protected: Bool
    public init(change: Int, text: String?, source: String? = nil, protected: Bool = false) {
        self.change = change; self.text = text; self.source = source; self.protected = protected
    }
}

@MainActor public protocol ClipboardPort: AnyObject {
    var changeCount: Int { get }
    var permission: ClipboardPermission { get }
    func read() -> ClipboardSample
    func write(_ text: String) throws -> Int
}

@MainActor public final class CaptureService {
    private let clipboard: any ClipboardPort
    private let history: any HistoryRepository
    private var observed: Int
    private var inFlight = false
    public var paused = false { didSet { observed = clipboard.changeCount } }
    public var excludedSources: Set<String> = []
    public var limit = 500

    public init(clipboard: any ClipboardPort, history: any HistoryRepository) {
        self.clipboard = clipboard; self.history = history; observed = clipboard.changeCount
    }
    public func tick(sourceFallback: String?) async throws -> Bool {
        guard !paused, !inFlight, clipboard.permission == .allowed else { return false }
        let change = clipboard.changeCount
        guard change != observed else { return false }
        inFlight = true
        defer { inFlight = false }
        let sample = clipboard.read()
        // Never accept a mixed snapshot when another process changes the pasteboard during a read.
        guard sample.change == change, clipboard.changeCount == change else { return false }
        observed = change
        let source = sample.source ?? sourceFallback
        guard !sample.protected, let text = sample.text, HistoryRules.eligible(text),
              source.map({ !excludedSources.contains($0) }) ?? true else { return false }
        do { try await history.record(text, source: source, at: Date(), limit: limit) }
        catch { if observed == change { observed = change - 1 }; throw error }
        return true
    }
    public func isCurrentChange(_ change: Int) -> Bool { clipboard.changeCount == change }
    @discardableResult public func copy(_ text: String) throws -> Int {
        // The adapter returns the count belonging to its own write, not a later external change.
        let ownChange = try clipboard.write(text)
        observed = ownChange
        return ownChange
    }
}
