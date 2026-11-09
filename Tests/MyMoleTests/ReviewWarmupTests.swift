import Foundation
import StorageKit
import Testing

@testable import MyMole

@MainActor @Suite(.serialized) struct ReviewWarmupTests {
    private func app(_ name: String) -> AppBundle {
        AppBundle(path: "/synthetic/\(name).app", name: name, bundleID: "com.example.\(name)", version: "1", bytes: 1, fromAppStore: false)
    }

    @Test func mouseDownAndPresentationJoinOneHintReadAndInventoryChangesInvalidateIt() async {
        var reads = 0
        let warmup = ReviewWarmup { _ in reads += 1; return .init(mentions: []) }
        let key = ReviewWarmup.Key(app: app("Editor"), revision: 1)
        warmup.prepare(key)
        _ = await warmup.value(for: key)
        _ = await warmup.value(for: key)
        #expect(reads == 1)
        _ = await warmup.value(for: .init(app: key.app, revision: 2))
        #expect(reads == 2)
    }

    @Test func aClosedOrRefreshedReviewDoesNotReuseItsPreviousHintResult() async {
        var reads = 0
        let warmup = ReviewWarmup { _ in reads += 1; return .init() }
        let key = ReviewWarmup.Key(app: app("Editor"), revision: 1)
        _ = await warmup.value(for: key)
        warmup.cancel(key)
        _ = await warmup.value(for: key)
        #expect(reads == 2)
    }

    @Test func rapidRequestsCannotOverlapSlowHintReadsOrReturnAnotherAppsHints() async throws {
        var active = 0
        var maximum = 0
        var release: CheckedContinuation<Void, Never>?
        defer { release?.resume() }
        let warmup = ReviewWarmup { app in
            active += 1
            maximum = max(maximum, active)
            if app.name == "Editor" { await withCheckedContinuation { release = $0 } }
            active -= 1
            return .init(uninstaller: app.path)
        }
        let first = ReviewWarmup.Key(app: app("Editor"), revision: 1)
        warmup.prepare(first)
        for _ in 0..<200 where release == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(release != nil)
        let second = ReviewWarmup.Key(app: app("Viewer"), revision: 1)
        warmup.prepare(second)
        let pending = Task { await warmup.value(for: second) }
        try await Task.sleep(for: .milliseconds(10))
        #expect(active == 1 && maximum == 1)
        release?.resume()
        release = nil
        let result = await pending.value
        #expect(maximum == 1 && result.uninstaller == second.app.path)
    }
}
