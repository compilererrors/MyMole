// swift-tools-version:6.2
import PackageDescription

// MyMole — a native SwiftUI Mac cleaner. Everything runs on MyMole's own
// engine. In the direct edition, system-level work goes through a privileged
// tool for one request at a time, via an approved service or an administrator
// prompt. The App Store edition has no such tool.
let package = Package(
    name: "MyMole",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "MyMole", targets: ["MyMole"]),
        .library(name: "StorageKit", targets: ["StorageKit"]),
        .library(name: "SystemKit", targets: ["SystemKit"]),
        .library(name: "PrivilegedKit", targets: ["PrivilegedKit"]),
        .executable(name: "MyMoleHelper", targets: ["MyMoleHelper"]),
    ],
    targets: [
        // Disk analysis: parallel bulk-attribute scanner, folder tree, file
        // kinds, chart layouts, snapshots for change tracking, projects,
        // installers, Deep Clean rules, apps and leftovers, Trash + undo,
        // cleanup history.
        .target(
            name: "StorageKit",
            path: "Sources/StorageKit"
        ),
        // Live readings of the Mac itself: CPU, memory, volumes, disk and
        // network throughput, battery and the busiest processes.
        .target(
            name: "SystemKit",
            path: "Sources/SystemKit"
        ),
        // What runs as root, and the contract with it: maintenance tasks,
        // system cache rules, and the request and reply the tool reads and
        // prints (versioned JSON on its command line/output or authenticated XPC).
        .target(
            name: "PrivilegedKit",
            dependencies: ["StorageKit"],
            path: "Sources/PrivilegedKit"
        ),
        // The privileged tool: handles approved requests under a shared lock,
        // as an on-demand service or a one-shot command.
        .executableTarget(
            name: "MyMoleHelper",
            dependencies: ["PrivilegedKit", "StorageKit"],
            path: "Sources/MyMoleHelper"
        ),
        .executableTarget(
            name: "MyMole",
            dependencies: ["StorageKit", "SystemKit", "PrivilegedKit"],
            path: "Sources/MyMole"
        ),
        .testTarget(
            name: "MyMoleTests",
            dependencies: ["MyMole"],
            path: "Tests/MyMoleTests"
        ),
        .testTarget(
            name: "StorageKitTests",
            dependencies: ["StorageKit"],
            path: "Tests/StorageKitTests",
            resources: [.copy("Fixtures/UninstallCorpus.json")]
        ),
        .testTarget(
            name: "PrivilegedKitTests",
            dependencies: ["PrivilegedKit", "StorageKit"],
            path: "Tests/PrivilegedKitTests"
        ),
        .testTarget(
            name: "SystemKitTests",
            dependencies: ["SystemKit"],
            path: "Tests/SystemKitTests"
        ),
    ]
)
