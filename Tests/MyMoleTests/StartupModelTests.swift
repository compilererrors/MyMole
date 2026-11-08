import Foundation
import StorageKit
import Testing

@testable import MyMole

/// The Startup Items pane on launch folders of the test's own.
@MainActor
@Suite struct StartupModelTests {
    final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "startup-\(UUID().uuidString)")
        var home: String { root.appending(path: "home").path }
        var system: String { root.appending(path: "system").path }
        var log: URL { root.appending(path: "history.json") }

        deinit { try? FileManager.default.removeItem(at: root) }

        func agent(_ rel: String, label: String, program: String) throws {
            let path = root.path + "/" + rel
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["Label": label, "Program": program, "RunAtLoad": true], format: .xml, options: 0)
                .write(to: URL(fileURLWithPath: path))
        }

        @MainActor func model() -> StartupModel {
            let m = StartupModel(home: home, root: system, logURL: log, trash: testBin(root))
            m.readLive = { nil }
            m.jobs = TrashJobs()
            m.protections = UserProtections(root: root.appending(path: "lists"))
            return m
        }
    }

    @Test func onlyTheUsersOwnAgentsCanBeChosenAndMovedAndUndoPutsThemBack() async throws {
        let box = Box()
        let mine = box.home + "/Library/LaunchAgents/com.vendor.gone.plist"
        let shared = box.system + "/Library/LaunchDaemons/com.vendor.daemon.plist"
        try box.agent("home/Library/LaunchAgents/com.vendor.gone.plist", label: "com.vendor.gone", program: "/opt/vendor/gone")
        try box.agent("system/Library/LaunchDaemons/com.vendor.daemon.plist", label: "com.vendor.daemon", program: "/opt/vendor/gone")
        let model = box.model()
        model.load()
        await model.job?.value
        #expect(model.items.count == 2 && model.leftovers == 2)

        // A daemon that needs an administrator can't be chosen, by a tick or by Choose Leftovers.
        model.toggle(shared)
        model.chooseLeftovers()
        #expect(model.chosen == [mine])

        model.trashChosen()
        await model.job?.value
        #expect(!FileManager.default.fileExists(atPath: mine) && FileManager.default.fileExists(atPath: shared))
        #expect(model.items.map(\.path) == [shared] && model.chosen.isEmpty && model.canUndo)
        let record = try #require(CleanupLog.load(from: box.log).first)
        #expect(record.source == StartupModel.source && record.items == 1 && record.deleted == 0)

        model.undoTrash(run: record.id)
        await model.job?.value
        #expect(FileManager.default.fileExists(atPath: mine) && !model.canUndo)
        #expect(CleanupLog.load(from: box.log).first?.restored == 1)
    }

    @Test func anAgentReplacedByALinkSinceTheListIsLeft() async throws {
        let box = Box()
        let mine = box.home + "/Library/LaunchAgents/com.vendor.gone.plist"
        let shared = box.system + "/Library/LaunchDaemons/com.vendor.daemon.plist"
        try box.agent("home/Library/LaunchAgents/com.vendor.gone.plist", label: "com.vendor.gone", program: "/opt/vendor/gone")
        try box.agent("system/Library/LaunchDaemons/com.vendor.daemon.plist", label: "com.vendor.daemon", program: "/opt/vendor/gone")
        let model = box.model()
        model.load()
        await model.job?.value
        model.toggle(mine)
        try FileManager.default.removeItem(atPath: mine)
        try FileManager.default.createSymbolicLink(atPath: mine, withDestinationPath: shared)

        model.trashChosen()
        await model.job?.value
        #expect(FileManager.default.fileExists(atPath: shared) && !model.canUndo)
        #expect(model.notice?.text.hasPrefix("Nothing was moved") == true)
    }
}
