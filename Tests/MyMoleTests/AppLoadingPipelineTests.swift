import Foundation
import StorageKit
import Testing

@testable import MyMole

@MainActor @Suite struct AppLoadingPipelineTests {
    private func waitUntil(_ ready: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if ready() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return ready()
    }

    @Test func inventoryBypassesBusyWalksAndAnOldListingCannotReplaceANewerOne() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "app-pipeline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String) throws {
            let contents = root.appending(path: "Applications/\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: NSDictionary = ["CFBundleIdentifier": "org.example.\(name)", "CFBundleName": name]
            try info.write(to: contents.appending(path: "Info.plist"))
        }
        try app("Canvas")
        let budget = ScanBudget(slots: 1)
        let (stream, release) = AsyncStream<Void>.makeStream()
        defer { release.yield(()); release.finish() }
        let hold = Task.detached {
            await budget.run(background: true) {
                for await _ in stream { break }
            }
        }
        try #require(await waitUntil { budget.running == 1 })
        let model = AppsModel(
            home: root.path, folders: [root.appending(path: "Applications").path], base: root.appending(path: "saved"),
            logURL: root.appending(path: "history.json"), recycle: { _ in TrashOutcome(moved: [], failed: []) }, isRunning: { _ in false },
            otherCopies: { _ in [] }, protections: UserProtections(root: root.appending(path: "support")), scanBudget: budget)
        await model.restoreJob?.value
        model.load()
        let old = model.loadJob
        try #require(await waitUntil { !model.apps.isEmpty })
        #expect(model.apps.count == 1 && model.apps[0].sizePending && model.loading)
        #expect(budget.waiting == 1)
        #expect(AppStore.load(folders: model.folders, base: root.appending(path: "saved")) == nil)
        model.stop()
        try #require(await waitUntil { !model.loading && budget.waiting == 0 })
        await old?.value
        #expect(budget.running == 1)
        #expect(AppStore.load(folders: model.folders, base: root.appending(path: "saved")) == nil)
        try app("Sketch")
        model.load()
        try #require(await waitUntil { model.apps.count == 2 })
        #expect(model.apps.allSatisfy { $0.sizePending })
        release.yield(())
        release.finish()
        await hold.value
        await old?.value
        await model.loadJob?.value
        #expect(Set(model.apps.map(\.name)) == ["Canvas", "Sketch"])
        #expect(!model.loading && !model.isStale)
        #expect(model.apps.allSatisfy { !$0.sizePending && $0.bytes > 0 })
    }
}
