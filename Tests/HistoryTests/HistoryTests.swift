import Foundation
import Testing
import HistoryCore
import HistoryServices
import HistoryInfrastructure

@Test func exactTextPersistenceAndSearch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("history.sqlite").path
    let database = try SQLiteHistory(path: path)
    let values = ["Привет 👋\n", "Привет 👋\n ", "Hello", "hello", "café", "\t \r\n", "a\0b", "é", "e\u{301}"]
    for (index, value) in values.enumerated() {
        try await database.record(value, source: "test.app", at: Date(timeIntervalSince1970: Double(index)), limit: 50)
    }
    let entries = try await database.entries()
    #expect(entries.count == values.count)
    #expect(Set(entries.map { Data($0.text.utf8) }) == Set(values.map { Data($0.utf8) }))
    let pinned = try #require(entries.first { $0.text == "Hello" })
    try await database.setPinned(pinned.id, pinned: true, at: Date(), limit: 50)
    try await database.record("Hello", source: "new.app", at: Date(), limit: 50)
    let reopened = try SQLiteHistory(path: path)
    let restored = try await reopened.entries()
    #expect(restored.count == values.count)
    #expect(restored.first?.id == pinned.id)
    #expect(restored.first?.source == "new.app")
    #expect(restored.first?.pinnedAt != nil)
    #expect(HistoryRules.display(restored, query: "ПРИВЕТ").count == 2)
    #expect(HistoryRules.display(restored, query: "HELLO").count == 2)
    #expect(HistoryRules.display(restored, query: "CAFÉ").count == 1)
    #expect(HistoryRules.display(restored, query: "missing").isEmpty)
    let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o700)
}

@Test func retentionPinClearAndUnpin() async throws {
    let database = try SQLiteHistory(path: ":memory:")
    try await database.record("pinned", source: nil, at: .distantPast, limit: 50)
    let pin = try #require(try await database.entries().first)
    try await database.setPinned(pin.id, pinned: true, at: Date(), limit: 50)
    for index in 0..<60 {
        try await database.record("item \(index)", source: nil, at: Date(timeIntervalSince1970: Double(index)), limit: 50)
    }
    #expect(try await database.entries().count == 51)
    try await database.setPinned(pin.id, pinned: false, at: Date(), limit: 50)
    #expect(try await database.entries().count == 50)
    #expect(try await database.entries().allSatisfy { $0.id != pin.id })
    let newPin = try #require(try await database.entries().first)
    try await database.setPinned(newPin.id, pinned: true, at: Date(), limit: 50)
    try await database.clear(includingPins: false)
    #expect(try await database.entries().map(\.id) == [newPin.id])
    try await database.delete(newPin.id)
    #expect(try await database.entries().isEmpty)
    try await database.record("one", source: nil, at: Date(), limit: 50)
    let last = try #require(try await database.entries().first)
    try await database.setPinned(last.id, pinned: true, at: Date(), limit: 50)
    try await database.clear(includingPins: true)
    #expect(try await database.entries().isEmpty)
}

@Test func storageFillClearAndReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("history.sqlite").path
    let database = try SQLiteHistory(path: path)
    for _ in 0..<2 {
        for index in 0..<2005 {
            try await database.record("\(index) " + String(repeating: "text ", count: 30), source: nil, at: Date(timeIntervalSince1970: Double(index)), limit: 2000)
        }
        #expect(try await database.entries().count == 2000)
        let reopened = try SQLiteHistory(path: path)
        #expect(try await reopened.entries().count == 2000)
        try await database.applyLimit(500)
        let entries = try await database.entries()
        #expect(entries.count == 500)
        let start = ContinuousClock.now
        for _ in 0..<100 { _ = HistoryRules.display(entries, query: "TEXT") }
        #expect(start.duration(to: .now) < .seconds(2))
        try await database.clear(includingPins: true)
        try await database.maintain()
        #expect(try await reopened.entries().isEmpty)
    }
    let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber
    #expect((size?.intValue ?? .max) < 100_000)
}

@MainActor final class FakeClipboard: ClipboardPort {
    var changeCount = 0
    var permission: ClipboardPermission = .allowed
    var text: String? = "value"
    var source: String?
    var protected = false
    var reads = 0
    var raceOnRead = false
    var raceOnWrite = false
    func read() -> ClipboardSample {
        reads += 1
        let old = changeCount
        if raceOnRead { changeCount += 1; raceOnRead = false }
        return ClipboardSample(change: old, text: text, source: source, protected: protected)
    }
    func write(_ text: String) throws -> Int {
        self.text = text; changeCount += 1
        let own = changeCount
        if raceOnWrite { self.text = "external"; changeCount += 1 }
        return own
    }
    func external(_ text: String) { self.text = text; changeCount += 1 }
}

@Test @MainActor func capturePrivacyPauseEligibilityAndRaces() async throws {
    let database = try SQLiteHistory(path: ":memory:")
    let board = FakeClipboard()
    let service = CaptureService(clipboard: board, history: database)
    board.external("hello")
    #expect(try await service.tick(sourceFallback: "source.app"))
    #expect(!(try await service.tick(sourceFallback: nil)))
    service.paused = true
    board.external("paused")
    #expect(!(try await service.tick(sourceFallback: nil)))
    #expect(board.reads == 1)
    service.paused = false
    #expect(!(try await service.tick(sourceFallback: nil)))
    board.permission = .requiresAccess
    board.external("denied")
    #expect(!(try await service.tick(sourceFallback: nil)))
    #expect(board.reads == 1)
    board.permission = .allowed
    service.excludedSources = ["excluded.app"]
    board.source = "excluded.app"
    #expect(!(try await service.tick(sourceFallback: nil)))
    board.source = nil
    board.protected = true
    board.external("secret")
    #expect(!(try await service.tick(sourceFallback: nil)))
    board.protected = false
    for value in ["", String(repeating: "a", count: HistoryRules.maximumBytes + 1)] {
        board.external(value)
        #expect(!(try await service.tick(sourceFallback: nil)))
    }
    board.external("race")
    board.raceOnRead = true
    #expect(!(try await service.tick(sourceFallback: nil)))
    #expect(try await service.tick(sourceFallback: nil))
    try service.copy("own")
    #expect(!(try await service.tick(sourceFallback: nil)))
    board.raceOnWrite = true
    try service.copy("own")
    #expect(try await service.tick(sourceFallback: nil))
    let entries = try await database.entries()
    #expect(Set(entries.map(\.text)) == ["hello", "race", "external"])
    #expect(HistoryRules.eligible(" \t\n"))
    #expect(HistoryRules.eligible(String(repeating: "é", count: HistoryRules.maximumBytes / 2)))
}

@MainActor final class FakeTarget: PasteTargetPort {
    var valid = true
    var posts = 0
    var snapshots = 0
    func snapshot() -> Int? { snapshots += 1; return 42 }
    func restoreAndConfirm(_ target: Int) async -> Bool {
        do { try await Task.sleep(for: .milliseconds(15)) } catch { return false }
        return valid && target == 42
    }
    func postPaste(_ target: Int) -> Bool { guard valid, target == 42 else { return false }; posts += 1; return true }
}

@Test @MainActor func pasteSingleAcceptanceOriginalTargetAndFallback() async throws {
    let board = FakeClipboard()
    let capture = CaptureService(clipboard: board, history: try SQLiteHistory(path: ":memory:"))
    let target = FakeTarget()
    let paste = PasteService(capture: capture, port: target)
    paste.prepare()
    let first = Task { try await paste.perform("Привет\n", copyOnly: false, hide: {}) }
    await Task.yield()
    #expect(try await paste.perform("duplicate", copyOnly: false, hide: {}) == nil)
    #expect(try await first.value == .shortcutSent)
    #expect(board.text == "Привет\n")
    #expect(target.posts == 1)
    #expect(target.snapshots == 1)
    paste.prepare(); target.valid = false
    #expect(try await paste.perform("fallback", copyOnly: false, hide: {}) == .copiedOnly)
    #expect(board.text == "fallback")
    #expect(target.posts == 1)
    paste.prepare(); target.valid = true
    #expect(try await paste.perform("copy", copyOnly: true, hide: {}) == .copiedOnly)
    #expect(target.posts == 1)
}

@Test @MainActor func externalCopyDuringRestoreNeverSendsPaste() async throws {
    let board = FakeClipboard()
    let capture = CaptureService(clipboard: board, history: try SQLiteHistory(path: ":memory:"))
    let target = FakeTarget()
    let paste = PasteService(capture: capture, port: target)
    paste.prepare()
    let operation = Task { try await paste.perform("selected", copyOnly: false, hide: {}) }
    await Task.yield()
    board.external("new user copy")
    #expect(try await operation.value == .copiedOnly)
    #expect(target.posts == 0)
    #expect(try await capture.tick(sourceFallback: nil))
}
