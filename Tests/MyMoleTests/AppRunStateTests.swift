import Foundation
import StorageKit
import Synchronization
import Testing

@testable import MyMole

@MainActor @Suite(.serialized) struct AppRunStateTests {
    @Test func oneSnapshotMatchesLargeBatchesByExactPathOrBundleIdentityWithoutTreatingUnknownIDsAsEqual() {
        var apps = (0..<5_000).map { index in
            AppBundle(path: "/synthetic/Applications/Editor-\(index).app", name: "Editor \(index)", bundleID: "com.example.editor\(index)", version: nil, bytes: 1, fromAppStore: false)
        }
        let unknown = AppBundle(path: "/synthetic/Applications/Unknown.app", name: "Unknown", bundleID: nil, version: nil, bytes: 1, fromAppStore: false)
        apps.append(unknown)
        let snapshot = RunningAppSnapshot(paths: [apps[0].path], bundleIDs: ["com.example.editor4999"])
        #expect(snapshot.matchingPaths(in: apps) == [apps[0].path, apps[4999].path])
        #expect(!snapshot.contains(unknown))
    }

    @Test func aReviewNoticesAnExternalQuitAndLaterRelaunchWithoutRescanningFiles() async throws {
        let processIsRunning = Mutex(true)
        let state = AppRunState { processIsRunning.withLock { $0 } }
        let refresh = LiveRefresh()
        let watch = Task { await refresh.observe(every: .milliseconds(5)) { state.refresh() } }
        defer { watch.cancel() }
        #expect(state.isRunning)
        processIsRunning.withLock { $0 = false }
        for _ in 0..<100 where state.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!state.isRunning)
        processIsRunning.withLock { $0 = true }
        state.refresh()
        #expect(state.isRunning)
        watch.cancel()
        await watch.value
    }

    @Test func aClosedReviewDoesNotKeepReadingRunningApps() async throws {
        var reads = 0
        let state = AppRunState { reads += 1; return false }
        let refresh = LiveRefresh()
        let watch = Task { await refresh.observe(every: .milliseconds(5)) { state.refresh() } }
        for _ in 0..<100 where reads < 2 { try await Task.sleep(for: .milliseconds(5)) }
        watch.cancel()
        await watch.value
        let stoppedAt = reads
        try await Task.sleep(for: .milliseconds(20))
        #expect(reads == stoppedAt)
    }

    @Test func eligibleUnverifiedChoicesRemainDistinctFromProtectedOrKnownSharedItems() {
        #expect(UninstallChoicePolicy.canChoose(verified: false, eligibleForReview: true, kept: false))
        #expect(!UninstallChoicePolicy.canChoose(verified: false, eligibleForReview: false, kept: false))
        #expect(!UninstallChoicePolicy.canChoose(verified: true, eligibleForReview: true, kept: true))
        #expect(UninstallChoicePolicy.canChoose(verified: true, eligibleForReview: false, kept: false))
    }
}
