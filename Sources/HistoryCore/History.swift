import Foundation

public struct HistoryEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public var copiedAt: Date
    public var source: String?
    public var pinnedAt: Date?

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date(), copiedAt: Date = Date(), source: String? = nil, pinnedAt: Date? = nil) {
        self.id = id; self.text = text; self.createdAt = createdAt
        self.copiedAt = copiedAt; self.source = source; self.pinnedAt = pinnedAt
    }
}

public enum HistoryRules {
    public static let maximumBytes = 1_048_576
    public static func eligible(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= maximumBytes }
    public static func limit(_ value: Int) -> Int { min(2000, max(50, value)) }
    public static func display(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
        filterPreservingOrder(entries, query: query)
            .sorted {
                switch ($0.pinnedAt, $1.pinnedAt) {
                case let (a?, b?) where a != b: return a > b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return $0.copiedAt == $1.copiedAt ? $0.id.uuidString < $1.id.uuidString : $0.copiedAt > $1.copiedAt
                }
            }
    }
    public static func filterPreservingOrder(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
        entries.filter {
            query.isEmpty || $0.text.range(of: query, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) != nil
        }
    }
}

public protocol HistoryRepository: Sendable {
    func entries() async throws -> [HistoryEntry]
    func record(_ text: String, source: String?, at: Date, limit: Int) async throws
    func setPinned(_ id: UUID, pinned: Bool, at: Date, limit: Int) async throws
    func delete(_ id: UUID) async throws
    func clear(includingPins: Bool) async throws
    func applyLimit(_ limit: Int) async throws
    func maintain() async throws
}
