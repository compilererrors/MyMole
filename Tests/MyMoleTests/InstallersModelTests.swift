import Foundation
import StorageKit
import Synchronization
import Testing

@testable import MyMole

/// Each test owns a temporary folder with synthetic installers; anything
/// moved to the Trash is put back by Undo or removed from there afterwards.
@MainActor
@Suite(.serialized) struct InstallersModelTests {
    private final class Box {
        let url = FileManager.default.temporaryDirectory.appending(path: "installers-\(UUID().uuidString)")
        var path: String { url.path }
        var downloads: String { path + "/Downloads" }

        init() throws { try FileManager.default.createDirectory(atPath: path + "/Downloads", withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }

        @discardableResult
        func file(_ name: String, bytes: Int = 2_000) throws -> String {
            let p = downloads + "/" + name
            try Data(repeating: 7, count: bytes).write(to: URL(fileURLWithPath: p))
            return p
        }

        @MainActor func model() -> InstallersModel {
            let m = InstallersModel(
                locations: [InstallerLocation(path: downloads, depth: 1)], base: url.appending(path: "store"),
                logURL: url.appending(path: "history.json"), trash: testBin(url))
            m.protections = UserProtections(root: url.appending(path: "lists"))
            return m
        }

    }

    @Test func aScanAskedForDuringAMoveWaitsForIt() async throws {
        let box = try Box()
        let go = try box.file("Go.pkg")
        try box.file("Stay.dmg")
        let bin = box.url.appending(path: "Held")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let folder = TrashBackend.folder(bin.path)
        let held = DispatchSemaphore(value: 0)
        let entered = Mutex(false)
        let model = InstallersModel(
            locations: [InstallerLocation(path: box.downloads, depth: 1)], base: box.url.appending(path: "store"),
            logURL: box.url.appending(path: "history.json"),
            trash: TrashBackend { path in
                entered.withLock { $0 = true }
                held.wait()
                return folder.moveOne(path)
            })
        model.protections = UserProtections(root: box.url.appending(path: "lists"))
        model.scan()
        await model.scanJob?.value
        let scannedBefore = try #require(model.scannedAt)
        model.chosen = [go]
        model.trashChosen()
        while !entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        model.scan()
        #expect(!model.scanning && model.scannedAt == scannedBefore)
        held.signal()
        await model.trashJob?.value
        // The move landed on the list it was made from, then the scan ran.
        await model.scanJob?.value
        #expect(model.scannedAt != scannedBefore)
        #expect(model.files.map(\.name) == ["Stay.dmg"])
        model.undoTrash()
        await model.trashJob?.value
    }

    @Test func trashesOnlyWhatIsStillAnInstallerAndUndoes() async throws {
        let box = try Box()
        let keep = try box.file("Keep.dmg")
        let go = try box.file("Go.pkg")
        let swapped = try box.file("Swapped.dmg")
        let model = box.model()
        model.scan()
        await model.scanJob?.value
        #expect(Set(model.files.map(\.name)) == ["Keep.dmg", "Go.pkg", "Swapped.dmg"])

        // Replaced by a link after the scan: must be left alone.
        try FileManager.default.removeItem(atPath: swapped)
        try FileManager.default.createSymbolicLink(atPath: swapped, withDestinationPath: keep)
        model.chosen = [go, swapped]
        model.trashChosen()
        await model.trashJob?.value

        #expect(!FileManager.default.fileExists(atPath: go))
        #expect(FileManager.default.fileExists(atPath: keep))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: swapped)) == keep)
        #expect(model.chosen.isEmpty)
        #expect(Set(model.files.map(\.name)) == ["Keep.dmg", "Swapped.dmg"])
        #expect(model.notice?.canUndo == true)
        #expect(model.notice?.text.contains("1 left alone") == true)

        model.undoTrash()
        await model.trashJob?.value
        #expect(FileManager.default.fileExists(atPath: go))
        #expect(model.files.contains { $0.path == go })
    }

    @Test func anEarlierMoveOfTheSessionCanStillBePutBack() async throws {
        let box = try Box()
        let first = try box.file("First.dmg")
        let second = try box.file("Second.pkg")
        let model = box.model()
        model.scan()
        await model.scanJob?.value
        model.chosen = [first]
        model.trashChosen()
        await model.trashJob?.value
        let firstRun = try #require(model.undoLogID)
        model.chosen = [second]
        model.trashChosen()
        await model.trashJob?.value
        let secondRun = try #require(model.undoLogID)
        #expect(firstRun != secondRun && model.canUndo(run: firstRun) && model.canUndo(run: secondRun))

        // The earlier one, as History asks for it: only it comes back.
        model.undoTrash(run: firstRun)
        await model.trashJob?.value
        #expect(FileManager.default.fileExists(atPath: first) && !FileManager.default.fileExists(atPath: second))
        #expect(!model.canUndo(run: firstRun) && model.undoLogID == secondRun)
        // The latest is still Undo's.
        model.undoTrash()
        await model.trashJob?.value
        #expect(FileManager.default.fileExists(atPath: second) && !model.canUndo)
    }

    @Test func nothingIsTrashedWhileScanning() async throws {
        let box = try Box()
        let a = try box.file("A.dmg")
        let model = box.model()
        model.scan()
        await model.scanJob?.value
        model.chosen = [a]
        model.scan()
        #expect(model.trashBlocker != nil)
        model.trashChosen()
        await model.trashJob?.value
        #expect(FileManager.default.fileExists(atPath: a))
        await model.scanJob?.value
        #expect(model.trashBlocker == nil)
        #expect(model.chosen == [a])
    }

    @Test func opensOnTheSavedResultAndAStoppedScanKeepsIt() async throws {
        let box = try Box()
        try box.file("A.dmg")
        let first = box.model()
        first.scan()
        await first.scanJob?.value
        // The save runs in the background after the scan, queued behind other writes.
        StoreWrites.flush()
        #expect(InstallerStore.load(for: first.locations, base: box.url.appending(path: "store")) != nil)

        try box.file("B.dmg")
        let next = box.model()
        // The saved result is read off the main actor, then shown.
        await next.restoreJob?.value
        #expect(next.files.map(\.name) == ["A.dmg"])
        #expect(next.isStale)
        next.scan()
        next.stop()
        await next.scanJob?.value
        #expect(next.files.map(\.name) == ["A.dmg"])
        #expect(!next.scanning)
    }
}

@Suite struct NothingMovedTextTests {
    @Test func aMoveWhereNothingWentSaysSoWithTheReason() {
        #expect(nothingMoved([("/x", "Operation not permitted")]) == "Nothing was moved to the Trash; MyMole couldn't move it: Operation not permitted.")
        #expect(nothingMoved([("/x", "a."), ("/y", "b")]).contains("couldn't move 2 items: a."))
    }
}
