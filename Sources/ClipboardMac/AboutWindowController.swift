import AppKit
import Foundation

private struct ReleaseVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = normalized.split(separator: ".")
        guard parts.count == 3, let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        self.major = major; self.minor = minor; self.patch = patch
    }

    var description: String { "\(major).\(minor).\(patch)" }
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

@MainActor final class AboutWindowController: NSObject, NSWindowDelegate {
    private static let repository = "DimonSmart/ClipboardMac"
    private static let bundleID = "local.clipboardmac.ClipboardMac"
    private let currentVersion = ReleaseVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
    private let window: NSWindow
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let updateButton = NSButton(title: "Update Now", target: nil, action: nil)
    private let releaseButton = NSButton(title: "Open Release Page", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private var release: ReleaseInfo?
    private var task: Task<Void, Never>?
    private var busy = false

    private struct ReleaseInfo {
        let version: ReleaseVersion
        let page: URL
        let archive: URL
    }

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "About ClipboardMac"
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildContent()
    }

    private func buildContent() {
        let title = NSTextField(labelWithString: "ClipboardMac")
        title.font = .boldSystemFont(ofSize: 22)
        let versionLabel = NSTextField(labelWithString: "Version \(currentVersion?.description ?? "Unknown")")
        versionLabel.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.style = .spinning; progress.controlSize = .small
        let statusRow = NSStackView(views: [progress, status])
        statusRow.orientation = .horizontal; statusRow.alignment = .centerY; statusRow.spacing = 8

        updateButton.target = self; updateButton.action = #selector(updateNow); updateButton.isHidden = true
        releaseButton.target = self; releaseButton.action = #selector(openRelease); releaseButton.isHidden = true
        closeButton.target = self; closeButton.action = #selector(closeWindow); closeButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [releaseButton, updateButton, closeButton])
        buttons.orientation = .horizontal; buttons.spacing = 8
        let spacer = NSView()
        let content = NSStackView(views: [title, versionLabel, statusRow, spacer, buttons])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        let root = window.contentView!
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusRow.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
            spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 6)
        ])
    }

    func present() {
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if task == nil { checkForUpdates() }
    }

    private func checkForUpdates() {
        status.stringValue = "Checking for updates…"; progress.isHidden = false; progress.startAnimation(nil)
        updateButton.isHidden = true; releaseButton.isHidden = true; release = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil; self.progress.stopAnimation(nil); self.progress.isHidden = true }
            guard let current = self.currentVersion,
                  let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest") else {
                self.status.stringValue = "Unable to determine the installed version."; return
            }
            do {
                var request = URLRequest(url: url); request.timeoutInterval = 10
                request.setValue("ClipboardMac/\(current)", forHTTPHeaderField: "User-Agent")
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    self.status.stringValue = "Unable to check for updates."; return
                }
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                guard !release.draft, !release.prerelease,
                      let version = ReleaseVersion(release.tagName),
                      let page = URL(string: release.htmlURL), page.scheme == "https", page.host == "github.com",
                      page.path == "/\(Self.repository)/releases/tag/v\(version)" else {
                    self.status.stringValue = "Unable to read the latest release."; return
                }
                guard let current = self.currentVersion, version > current else {
                    self.status.stringValue = "You're up to date."; return
                }
                guard let asset = release.assets.first(where: { $0.name == "ClipboardMac-macos.zip" }),
                      let archive = URL(string: asset.browserDownloadURL), archive.scheme == "https",
                      archive.host == "github.com",
                      archive.path == "/\(Self.repository)/releases/download/v\(version)/ClipboardMac-macos.zip" else {
                    self.release = ReleaseInfo(version: version, page: page, archive: page)
                    self.status.stringValue = "Version \(version) is available. Its update package is not published yet."
                    self.releaseButton.isHidden = false; return
                }
                self.release = ReleaseInfo(version: version, page: page, archive: archive)
                self.status.stringValue = "Version \(version) is available."
                self.updateButton.isHidden = false; self.releaseButton.isHidden = false
            } catch {
                self.status.stringValue = "Unable to check for updates. Check your internet connection and try again."
            }
        }
    }

    @objc private func updateNow() {
        guard !busy, let release else { return }
        busy = true; updateButton.isHidden = true; releaseButton.isEnabled = false
        closeButton.title = "Please Wait"; closeButton.isEnabled = false
        status.stringValue = "Downloading ClipboardMac \(release.version)…"
        progress.isHidden = false; progress.startAnimation(nil)
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil; self.busy = false; self.progress.stopAnimation(nil); self.progress.isHidden = true
                self.closeButton.title = "Close"; self.closeButton.isEnabled = true; self.releaseButton.isEnabled = true }
            do {
                let (temporaryArchive, response) = try await URLSession.shared.download(from: release.archive)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateError.download }
                let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardMac-Update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempRoot) }
                let archive = tempRoot.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: temporaryArchive, to: archive)
                try run("/usr/bin/ditto", ["-x", "-k", archive.path, tempRoot.path])
                let extracted = tempRoot.appendingPathComponent("ClipboardMac.app")
                let info = Bundle(url: extracted)?.infoDictionary
                guard info?["CFBundleIdentifier"] as? String == Self.bundleID,
                      let installedVersion = ReleaseVersion(info?["CFBundleShortVersionString"] as? String ?? ""),
                      installedVersion >= release.version else { throw UpdateError.invalidPackage }
                try self.replaceCurrentApplication(with: extracted, staging: tempRoot)
                self.status.stringValue = "Update installed. Restarting ClipboardMac…"
                let result = await Self.launchUpdatedApp(at: Bundle.main.bundleURL)
                if result { NSApp.terminate(nil) }
                else { throw UpdateError.restart }
            } catch {
                self.status.stringValue = error.localizedDescription
                self.updateButton.isHidden = false
            }
        }
    }

    private func replaceCurrentApplication(with extracted: URL, staging: URL) throws {
        let destination = Bundle.main.bundleURL
        let manager = FileManager.default
        guard manager.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { throw UpdateError.notWritable }
        let staged = staging.appendingPathComponent("ClipboardMac-install.app")
        let backup = staging.appendingPathComponent("ClipboardMac-previous.app")
        try manager.moveItem(at: extracted, to: staged)
        try manager.moveItem(at: destination, to: backup)
        do { try manager.moveItem(at: staged, to: destination) }
        catch {
            try? manager.moveItem(at: backup, to: destination)
            throw error
        }
    }

    private static func launchUpdatedApp(at url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", url.path]
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.invalidPackage }
    }

    @objc private func openRelease() { if let url = release?.page { NSWorkspace.shared.open(url) } }
    @objc private func closeWindow() { if !busy { window.close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }

    private enum UpdateError: LocalizedError {
        case download, invalidPackage, notWritable, restart
        var errorDescription: String? {
            switch self {
            case .download: return "The update download failed. Try again later."
            case .invalidPackage: return "The downloaded update package is invalid."
            case .notWritable: return "ClipboardMac is in a protected location. Move it to a writable Applications folder and try again."
            case .restart: return "The update was installed, but ClipboardMac could not restart. Open it again from Applications."
            }
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    struct Asset: Decodable { let name: String; let browserDownloadURL: String
        enum CodingKeys: String, CodingKey { case name; case browserDownloadURL = "browser_download_url" }
    }
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", draft, prerelease, assets
    }
}
