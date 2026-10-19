import Foundation

@MainActor public protocol PasteTargetPort: AnyObject {
    associatedtype Target
    func snapshot() -> Target?
    func restoreAndConfirm(_ target: Target) async -> Bool
    func postPaste(_ target: Target) -> Bool
}

public enum PasteOutcome: Sendable { case shortcutSent, copiedOnly }

@MainActor public final class PasteService<Port: PasteTargetPort> {
    private let capture: CaptureService
    private let port: Port
    private var target: Port.Target?
    public private(set) var busy = false
    public init(capture: CaptureService, port: Port) { self.capture = capture; self.port = port }
    public func prepare() { guard !busy else { return }; target = port.snapshot() }
    public func perform(_ text: String, copyOnly: Bool, hide: () -> Void) async throws -> PasteOutcome? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false; target = nil }
        let original = target
        hide()
        let revision = try capture.copy(text)
        guard !copyOnly, let original, await port.restoreAndConfirm(original), capture.isCurrentChange(revision), port.postPaste(original) else { return .copiedOnly }
        return .shortcutSent
    }
}
