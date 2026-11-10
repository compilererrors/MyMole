import AppKit
import Foundation
import Observation
import StorageKit

/// One AppKit snapshot serves a batch, including another running copy of an ID.
struct RunningAppSnapshot {
    let paths: Set<String>
    let bundleIDs: Set<String>

    func contains(_ app: AppBundle) -> Bool {
        paths.contains(app.path) || app.bundleID.map(bundleIDs.contains) == true
    }

    func matchingPaths(in apps: [AppBundle]) -> Set<String> { Set(apps.lazy.filter(contains).map(\.path)) }

    @MainActor static func read() -> Self {
        #if SMOKE
        guard let scope = try? SyntheticRun.current() else { return Self(paths: [], bundleIDs: []) }
        let running = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.bundleURL?.path.hasPrefix(scope.home + "/Applications/") == true
        }
        return Self(paths: Set(running.compactMap { $0.bundleURL?.path }), bundleIDs: Set(running.compactMap(\.bundleIdentifier)))
        #else
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        return Self(paths: Set(running.compactMap { $0.bundleURL?.standardizedFileURL.path }),
                    bundleIDs: Set(running.compactMap(\.bundleIdentifier)))
        #endif
    }
}

/// Owned by the visible review; observing a quit never starts a removal.
@MainActor @Observable final class AppRunState {
    private(set) var isRunning: Bool
    private let read: @MainActor () -> Bool

    init(read: @escaping @MainActor () -> Bool) {
        self.read = read
        isRunning = read()
    }

    func refresh() {
        let current = read()
        if current != isRunning { isRunning = current }
    }
}

enum UninstallChoicePolicy {
    static func canChoose(verified: Bool, eligibleForReview: Bool, kept: Bool) -> Bool {
        !kept && (verified || eligibleForReview)
    }
}
