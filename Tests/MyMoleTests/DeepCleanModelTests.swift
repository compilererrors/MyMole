import Foundation
import StorageKit
import Synchronization
import Testing

@testable import MyMole

/// A synthetic home folder per test. Anything moved to the Trash is put
/// back by Undo before the folder is removed.
/// Names of running tools as the model reads them, off the main actor.
private final class ToolNames: @unchecked Sendable {
    var value: Set<String>? = []
}

@MainActor
@Suite(.serialized) struct DeepCleanModelTests {
    private final class Home {
        let url = FileManager.default.temporaryDirectory.appending(path: "deepclean-\(UUID().uuidString)")
        var path: String { url.path }

        init() throws {
            try file("Library/Caches/com.vendor.Editor/blob")
            try file("Library/Caches/com.vendor.Player/blob")
            try file("Library/Caches/CloudKit/db")
            try file(".npm/_cacache/content/a")
            try file(".npm/_cacache/index/b")
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func file(_ rel: String, bytes: Int = 4_000) throws {
            let u = url.appending(path: rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: u)
        }

        func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: path + "/" + rel) }

        /// Bundle IDs of running apps and names of running tools; tests
        /// change them between steps.
        var running: Set<String> = []
        let toolNames = ToolNames()
        var tools: Set<String>? {
            get { toolNames.value }
            set { toolNames.value = newValue }
        }

        @MainActor func model(running: Set<String> = []) -> DeepCleanModel {
            self.running = running
            return DeepCleanModel(
                home: path, base: url.appending(path: "store"), keepURL: url.appending(path: "keep.json"),
                logURL: url.appending(path: "history.json"), runningApps: { self.running },
                runningTools: { [toolNames] in toolNames.value }, trash: testBin(url))
        }

    }

    @Test func choosesSafeItemsOfAppsThatArentRunning() async throws {
        let home = try Home()
        let model = home.model(running: ["com.vendor.Player"])
        model.scan()
        await model.scanJob?.value
        let chosen = Set(model.chosen.map { String($0.dropFirst(home.path.count + 1)) })
        #expect(chosen == ["Library/Caches/com.vendor.Editor", ".npm/_cacache"])
        #expect(model.candidates.count == 4)
    }

    @Test func movesToTheTrashKeepsWhatIsKeptAndUndoes() async throws {
        let home = try Home()
        let model = home.model()
        model.scan()
        await model.scanJob?.value
        model.keepAlways([home.path + "/.npm/_cacache/index"])
        model.chosen = [home.path + "/Library/Caches/com.vendor.Editor", home.path + "/.npm/_cacache"]
        model.trashChosen()
        while model.trashing { try await Task.sleep(for: .milliseconds(10)) }

        #expect(!home.exists("Library/Caches/com.vendor.Editor"))
        #expect(!home.exists(".npm/_cacache/content"))
        #expect(home.exists(".npm/_cacache/index/b"))
        #expect(home.exists(".npm/_cacache"))
        #expect(home.exists("Library/Caches/com.vendor.Player/blob"))
        // The emptied npm cache still holds a kept item, so it stays listed.
        #expect(model.candidates.contains { $0.path == home.path + "/.npm/_cacache" })
        #expect(!model.candidates.contains { $0.path == home.path + "/Library/Caches/com.vendor.Editor" })
        #expect(model.notice?.canUndo == true)

        model.undoTrash()
        await model.undoJob?.value
        #expect(home.exists("Library/Caches/com.vendor.Editor/blob"))
        #expect(home.exists(".npm/_cacache/content/a"))
        #expect(model.isStale)
    }

    @Test func onlyWhatReallyMovedIsCountedAndUndoneAtItsSize() async throws {
        let home = try Home()
        let model = home.model()
        model.scan()
        await model.scanJob?.value
        model.keepAlways([home.path + "/.npm/_cacache/index"])
        model.chosen = [home.path + "/.npm/_cacache"]
        model.trashChosen()
        while model.trashing { try await Task.sleep(for: .milliseconds(10)) }
        let bin = home.url.appending(path: "Bin").path
        let inBin = StorageScanner.scan(path: bin, workers: 1).root.size
        CleanupLog.flush()
        let record = try #require(CleanupLog.load(from: home.url.appending(path: "history.json")).first)
        // The kept index isn't counted: only the content went.
        #expect(inBin > 0 && record.bytes == inBin)
        // History can find the run's Undo by its record.
        #expect(model.undoLogID == record.id && model.canUndo)
        #expect(home.exists(".npm/_cacache/index/b"))
        model.undoTrash()
        await model.undoJob?.value
        CleanupLog.flush()
        #expect(CleanupLog.load(from: home.url.appending(path: "history.json")).first?.restoredBytes == inBin)
        #expect(!model.canUndo && model.undoLogID == nil)
    }

    @Test func anAppStartedDuringTheRunKeepsItsCache() async throws {
        let home = try Home()
        let bin = home.url.appending(path: "Bin2")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let folder = TrashBackend.folder(bin.path)
        let apps = Mutex<Set<String>>([])
        let model = DeepCleanModel(
            home: home.path, base: home.url.appending(path: "store"), keepURL: home.url.appending(path: "keep.json"),
            logURL: home.url.appending(path: "history.json"), runningApps: { apps.withLock { $0 } }, runningTools: { [] },
            trash: TrashBackend { path in
                // The player starts as the editor's cache goes.
                if path.hasSuffix("com.vendor.Editor") { _ = apps.withLock { $0.insert("com.vendor.Player") } }
                return folder.moveOne(path)
            })
        model.scan()
        await model.scanJob?.value
        model.chosen = [home.path + "/Library/Caches/com.vendor.Editor", home.path + "/Library/Caches/com.vendor.Player"]
        model.trashChosen()
        while model.trashing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!home.exists("Library/Caches/com.vendor.Editor"))
        #expect(home.exists("Library/Caches/com.vendor.Player/blob"))
        #expect(model.notice?.text.contains("1 left alone") == true)
    }

    @Test func anUnreadableKeepListStopsTheRun() async throws {
        let home = try Home()
        let model = home.model()
        model.scan()
        await model.scanJob?.value
        try Data("broken".utf8).write(to: home.url.appending(path: "keep.json"))
        model.chosen = [home.path + "/Library/Caches/com.vendor.Editor"]
        model.trashChosen()
        #expect(!model.trashing)
        #expect(model.keepError != nil)
        #expect(home.exists("Library/Caches/com.vendor.Editor/blob"))
    }

    @Test func anAppOpenedSinceTheScanKeepsItsCache() async throws {
        let home = try Home()
        let model = home.model()
        model.scan()
        await model.scanJob?.value
        model.chosen = [home.path + "/Library/Caches/com.vendor.Editor", home.path + "/Library/Caches/com.vendor.Player"]
        home.running = ["com.vendor.Player"]
        model.trashChosen()
        while model.trashing { try await Task.sleep(for: .milliseconds(10)) }

        #expect(!home.exists("Library/Caches/com.vendor.Editor"))
        #expect(home.exists("Library/Caches/com.vendor.Player/blob"))
        #expect(model.notice?.text.contains("1 left alone") == true)
    }

    @Test func aRunningToolKeepsItsCache() async throws {
        let home = try Home()
        home.tools = ["zsh", "npm-cli"]
        let model = home.model()
        model.scan()
        await model.scanJob?.value
        let npm = home.path + "/.npm/_cacache"
        #expect(!model.chosen.contains(npm))
        model.chosen = [npm]
        model.trashChosen()
        while model.trashing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(home.exists(".npm/_cacache/content/a"))

        // Once npm has quit, the cache can go.
        home.tools = ["zsh"]
        model.chosen = [npm]
        model.trashChosen()
        while model.trashing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!home.exists(".npm/_cacache/content"))
    }

    @Test func anUnreadableProcessListKeepsToolCaches() async throws {
        let home = try Home()
        home.tools = nil
        let model = home.model()
        model.scan()
        await model.scanJob?.value
        #expect(!model.chosen.contains(home.path + "/.npm/_cacache"))
        #expect(model.chosen.contains(home.path + "/Library/Caches/com.vendor.Editor"))
    }

    @Test func keptItemsCantBeChosen() async throws {
        let home = try Home()
        let model = home.model()
        model.scan()
        await model.scanJob?.value
        let editor = home.path + "/Library/Caches/com.vendor.Editor"
        model.keepAlways([editor])
        #expect(!model.chosen.contains(editor))
        model.toggle(editor)
        #expect(!model.chosen.contains(editor))
        model.stopKeeping([editor])
        model.toggle(editor)
        #expect(model.chosen.contains(editor))
    }
}
