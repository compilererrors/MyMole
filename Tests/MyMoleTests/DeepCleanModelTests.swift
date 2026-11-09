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

        /// Project rules of the test's own.
        var projectRules: URL { url.appending(path: "projects") }

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
                runningTools: { [toolNames] in toolNames.value }, trash: testBin(url), projectRules: projectRules, quietFor: 0)
        }

    }

    /// While the first scan runs its finds are shown, but nothing is
    /// offered for choosing until the list is complete; then the preview
    /// gives way to the list and the progress is gone.
    @Test func theFirstScanShowsWhatItFoundBeforeItsDone() async throws {
        let home = try Home()
        let model = home.model()
        await model.restoreJob?.value
        model.scan()
        #expect(model.scanning && model.scanFraction == 0 && model.candidates.isEmpty)
        await model.scanJob?.value
        #expect(!model.scanning && model.scanFraction == nil && model.preview.isEmpty)
        #expect(!model.candidates.isEmpty)
    }

    @Test func aCacheWrittenJustNowIsLeftUnticked() async throws {
        let home = try Home()
        // Everything but the editor's cache was last written an hour ago.
        let hourAgo = Date().addingTimeInterval(-3_600)
        let all = FileManager.default.enumerator(atPath: home.path)?.allObjects as? [String] ?? []
        for rel in all where !rel.contains("com.vendor.Editor") {
            try FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: home.path + "/" + rel)
        }
        let model = DeepCleanModel(
            home: home.path, base: home.url.appending(path: "store"), keepURL: home.url.appending(path: "keep.json"),
            logURL: home.url.appending(path: "history.json"), runningApps: { [] }, runningTools: { [] },
            trash: testBin(home.url), projectRules: home.projectRules)
        model.scan()
        await model.scanJob?.value
        let editor = try #require(model.candidates.first { $0.path.hasSuffix("com.vendor.Editor") })
        let player = try #require(model.candidates.first { $0.path.hasSuffix("com.vendor.Player") })
        #expect(model.isJustWritten(editor) && !model.chosen.contains(editor.path))
        #expect(!model.isJustWritten(player) && model.chosen.contains(player.path))
        // Still the user's to choose.
        model.choose([editor.path])
        #expect(model.chosen.contains(editor.path))
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

    @Test func visibleActivityChangesUpdateBadgesAndUnchooseNewlyActiveDataWithoutRescanningOrRechoosing() async throws {
        let home = try Home()
        let model = home.model()
        model.scan()
        await model.scanJob?.value
        let date = model.scannedAt
        let editor = try #require(model.candidates.first { $0.path.hasSuffix("com.vendor.Editor") })
        let npm = try #require(model.candidates.first { $0.path.hasSuffix("_cacache") })
        #expect(model.chosen.contains(editor.path) && model.chosen.contains(npm.path))
        home.running = ["com.vendor.Editor"]
        home.tools = ["npm"]
        await model.refreshActivity()
        #expect(model.isRunning(editor) && model.isRunning(npm))
        #expect(!model.chosen.contains(editor.path) && !model.chosen.contains(npm.path))
        home.running = []
        home.tools = []
        await model.refreshActivity()
        #expect(!model.isRunning(editor) && !model.isRunning(npm))
        #expect(!model.chosen.contains(editor.path) && !model.chosen.contains(npm.path))
        #expect(model.scannedAt == date)
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

    @Test func aMoveWaitsForAnotherPanesJobAndIsStoppedByAQuit() async throws {
        let home = try Home()
        let model = home.model()
        let jobs = TrashJobs()
        model.jobs = jobs
        model.scan()
        await model.scanJob?.value
        model.chosen = [home.path + "/Library/Caches/com.vendor.Editor", home.path + "/.npm/_cacache"]
        // Another pane's job holds the turn: nothing moves until it ends.
        let other = await jobs.begin(.moveToTrash)
        model.trashChosen()
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.trashing)
        #expect(home.exists("Library/Caches/com.vendor.Editor/blob") && home.exists(".npm/_cacache/content/a"))
        // A quit stops the waiting move before its first item.
        jobs.stop()
        jobs.end(other)
        while model.trashing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(home.exists("Library/Caches/com.vendor.Editor/blob") && home.exists(".npm/_cacache/content/a"))
        #expect(model.notice?.canUndo == false)
        #expect(!jobs.isBusy)
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
            }, projectRules: home.projectRules, quietFor: 0)
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
        #expect(model.trashing)
        while model.trashing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.keepError != nil)
        // The code names the keep list and the error, never the file.
        let code = try #require(model.keepError?.code).description
        #expect(code.hasPrefix("MM-KEEP-") && !code.contains(home.path) && !code.contains("keep.json"))
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

    @Test func aCacheOfFilesIsCountedAtTheirSize() async throws {
        let home = try Home()
        // Yarn keeps its cache as files right inside the folder, which is
        // emptied item by item.
        try home.file(".yarn/berry/cache/a.zip", bytes: 40_000)
        try home.file(".yarn/berry/cache/b.zip", bytes: 24_000)
        let model = home.model()
        model.scan()
        await model.scanJob?.value
        let yarn = home.path + "/.yarn/berry/cache"
        #expect(model.chosen.contains(yarn))
        model.chosen = [yarn]
        model.trashChosen()
        while model.trashing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(home.exists(".yarn/berry/cache") && !home.exists(".yarn/berry/cache/a.zip"))
        let inBin = StorageScanner.scan(path: home.url.appending(path: "Bin").path, workers: 1).root.size
        CleanupLog.flush()
        let record = try #require(CleanupLog.load(from: home.url.appending(path: "history.json")).first)
        #expect(inBin > 0 && record.bytes == inBin)
        #expect(model.notice?.text.contains("Moved Zero") == false)
    }

    @Test func aPathKeptInProjectsStaysAndIsNeverChosen() async throws {
        let home = try Home()
        let editor = home.path + "/Library/Caches/com.vendor.Editor"
        var rules = ProjectRules()
        rules.keepPaths = [editor, home.path + "/.npm/_cacache/index"]
        try ProjectStore.saveRules(rules, base: home.projectRules)
        let model = home.model()
        model.scan()
        await model.scanJob?.value
        // Shown as kept: not chosen by the scan, and can't be ticked.
        #expect(model.isKept(editor) && !model.chosen.contains(editor))
        model.toggle(editor)
        #expect(!model.chosen.contains(editor))
        // Chosen anyway, as an older choice would be: the move leaves it,
        // and goes around what's kept inside a cache.
        model.chosen = [editor, home.path + "/.npm/_cacache"]
        model.trashChosen()
        while model.trashing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(home.exists("Library/Caches/com.vendor.Editor/blob"))
        #expect(home.exists(".npm/_cacache/index/b") && !home.exists(".npm/_cacache/content"))
    }

    @Test func projectRulesThatCantBeReadStopTheRun() async throws {
        let home = try Home()
        let model = home.model()
        model.scan()
        await model.scanJob?.value
        try FileManager.default.createDirectory(at: home.projectRules, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: home.projectRules.appending(path: "rules.json"))
        model.chosen = [home.path + "/Library/Caches/com.vendor.Editor"]
        model.trashChosen()
        #expect(model.trashing)
        while model.trashing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.notice?.text == "Nothing was moved: your project rules couldn't be read.")
        #expect(home.exists("Library/Caches/com.vendor.Editor/blob"))
    }

    @Test func aScanAskedForDuringAMoveRunsWhenTheMoveEnds() async throws {
        let home = try Home()
        let model = home.model()
        let jobs = TrashJobs()
        model.jobs = jobs
        model.scan()
        await model.scanJob?.value
        // Another pane's move holds the turn, so this one stays under way.
        let other = await jobs.begin(.moveToTrash)
        let editor = home.path + "/Library/Caches/com.vendor.Editor"
        model.chosen = [editor]
        model.trashChosen()
        #expect(model.trashing)
        // Something new turns up, and a scan is asked for meanwhile: the
        // list stays as it is under the move.
        try home.file("Library/Caches/com.vendor.Viewer/blob")
        model.scan()
        #expect(!model.scanning)
        jobs.end(other)
        while model.trashing { try await Task.sleep(for: .milliseconds(10)) }
        await model.scanJob?.value
        #expect(!model.scanning)
        let found = Set(model.candidates.map(\.path))
        #expect(found.contains(home.path + "/Library/Caches/com.vendor.Viewer") && !found.contains(editor))
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
