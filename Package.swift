// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClipboardMac",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "ClipboardMac", targets: ["ClipboardMac"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "HistoryCore"),
        .target(name: "HistoryServices", dependencies: ["HistoryCore"]),
        .target(name: "HistoryInfrastructure", dependencies: ["HistoryCore", "HistoryServices", "CSQLite"]),
        .executableTarget(name: "ClipboardMac", dependencies: ["HistoryCore", "HistoryServices", "HistoryInfrastructure"]),
        .testTarget(name: "HistoryTests", dependencies: ["HistoryCore", "HistoryServices", "HistoryInfrastructure"])
    ]
)
