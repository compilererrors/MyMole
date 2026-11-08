import Foundation
import StorageKit
import Testing

@testable import MyMole

/// Emptying a Trash folder of the test's own through the model.
@MainActor
@Suite struct TrashModelTests {
    private func box() throws -> (root: URL, trash: String, log: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "trash-model-\(UUID().uuidString)")
        let trash = root.appending(path: "Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        return (root, trash.path, root.appending(path: "history.json"))
    }

    @Test func nothingGoesBeforeTheConfirmationAndOnlyWhatItShowed() async throws {
        let (root, trash, log) = try box()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 8_000).write(to: URL(fileURLWithPath: trash + "/old.zip"))
        let model = TrashModel(folder: trash, jobs: TrashJobs(), logURL: log)

        await model.askToEmpty()
        let confirmed = try #require(model.confirming)
        #expect(confirmed.count == 1 && model.canEmpty)
        #expect(FileManager.default.fileExists(atPath: trash + "/old.zip"))

        // Something moved to the Trash while the confirmation shows stays.
        try Data(repeating: 2, count: 8_000).write(to: URL(fileURLWithPath: trash + "/new.zip"))
        await model.empty(confirmed)
        #expect(!FileManager.default.fileExists(atPath: trash + "/old.zip"))
        #expect(FileManager.default.fileExists(atPath: trash + "/new.zip"))
        #expect(model.confirming == nil && !model.emptying && model.count == 1)

        // The history has the run: deleted for good, counts and sizes only.
        let records = CleanupLog.load(from: log)
        #expect(records.count == 1)
        #expect(records.first?.source == TrashModel.source && records.first?.deleted == 1 && records.first?.items == 0)
        #expect(records.first?.bytes == confirmed.bytes)
    }

    @Test func anAskDuringAReadingWaitsForItAndStillAsks() async throws {
        let (root, trash, log) = try box()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<400 { try Data(repeating: 1, count: 100).write(to: URL(fileURLWithPath: trash + "/f\(i)")) }
        let model = TrashModel(folder: trash, jobs: TrashJobs(), logURL: log)

        let reading = Task { await model.refresh(force: true) }
        var spins = 0
        while !model.measuring && spins < 1_000 {
            await Task.yield()
            spins += 1
        }
        #expect(model.measuring)
        await model.askToEmpty()
        #expect(model.confirming?.count == 400)
        #expect(!model.measuring)
        await reading.value
        #expect(!model.measuring)
    }

    @Test func anEmptyOrUnreadableTrashAsksNothing() async throws {
        let (root, trash, log) = try box()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = TrashModel(folder: trash, jobs: TrashJobs(), logURL: log)
        await model.askToEmpty()
        #expect(model.confirming == nil && model.notice != nil && !model.canEmpty)

        let missing = TrashModel(folder: root.appending(path: "nowhere").path, jobs: TrashJobs(), logURL: log)
        await missing.askToEmpty()
        #expect(missing.confirming == nil && missing.bytes == nil && missing.notice != nil)
        #expect(CleanupLog.load(from: log).isEmpty)
    }

    @Test func theReportSaysWhatStayed() {
        let all = TrashModel.report(.init(removed: 3, bytes: 2_000_000, failed: 0, skipped: 0))
        #expect(all.contains("3 items") && !all.contains("couldn't"))
        let some = TrashModel.report(.init(removed: 1, bytes: 1_000, failed: 2, skipped: 1))
        #expect(some.contains("1 item ") && some.contains("2 couldn't be removed") && some.contains("1 left"))
        #expect(TrashModel.report(.init(removed: 0, bytes: 0, failed: 1, skipped: 0)).hasPrefix("Nothing was deleted"))
    }
}
