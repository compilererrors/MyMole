import Foundation
import PrivilegedKit
import StorageKit
import Testing

@testable import MyMole

/// A synthetic Applications folder and Library per test. The Finder step is
/// replaced by `Trasher`, and anything moved is put back by Undo.
@MainActor
@Suite(.serialized) struct AppsModelTests {
    private final class Home {
        let url = FileManager.default.temporaryDirectory.appending(path: "apps-\(UUID().uuidString)")
        var path: String { url.path }

        init() throws {
            try write("Applications/Editor.app/Contents/MacOS/bin")
            let info: NSDictionary = ["CFBundleIdentifier": "com.vendor.Editor", "CFBundleName": "Editor"]
            try info.write(to: url.appending(path: "Applications/Editor.app/Contents/Info.plist"))
            try write("Library/Caches/com.vendor.Editor/c")
            try write("Library/Preferences/com.vendor.Editor.plist")
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ rel: String) throws {
            let u = url.appending(path: rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 3, count: 3_000).write(to: u)
        }

        func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: path + "/" + rel) }

        /// `copies` nil: other copies can't be looked up.
        @MainActor func model(running: Bool = false, copies: [String]? = [], system: AppsModel.SystemSide? = nil) -> AppsModel {
            AppsModel(
                home: path, folders: [path + "/Applications"], base: url.appending(path: "store"),
                logURL: url.appending(path: "history.json"), recycle: { [bin = testBin(url)] in Trasher.moveToTrash($0, through: TrashGate(still: { _ in true }), backend: bin) },
                isRunning: { _ in running },
                otherCopies: { app in
                    copies?.map { AppBundle(path: $0, name: app.name, bundleID: app.bundleID, version: nil, bytes: 0, fromAppStore: false) }
                },
                system: system ?? AppsModel.SystemSide(base: path + "/system", isReady: { false }, remove: { _, _, _ in RemovalReport() }),
                trash: testBin(url))
        }
    }

    @Test func refusesARunningApp() async throws {
        let home = try Home()
        let model = home.model(running: true)
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        let result = await model.uninstall(app, leftovers: await model.leftovers(for: app) ?? [])
        #expect(result == .refused("Editor is open. Quit it first."))
        #expect(home.exists("Applications/Editor.app"))
    }

    @Test func movesAppAndChosenLeftoversThenUndoes() async throws {
        let home = try Home()
        let model = home.model()
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        let leftovers = try #require(await model.leftovers(for: app))
        #expect(leftovers.count == 2)
        // Keep the preferences: only the cache goes.
        let picked = leftovers.filter { $0.place == "Caches" }
        let result = await model.uninstall(app, leftovers: picked)

        #expect(result == .done)
        #expect(!home.exists("Applications/Editor.app"))
        #expect(!home.exists("Library/Caches/com.vendor.Editor"))
        #expect(home.exists("Library/Preferences/com.vendor.Editor.plist"))
        #expect(model.apps.isEmpty)
        #expect(model.notice?.canUndo == true)
        // The log is written in the background.
        var log = CleanupLog.load(from: home.url.appending(path: "history.json"))
        for _ in 0..<100 where log.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            log = CleanupLog.load(from: home.url.appending(path: "history.json"))
        }
        #expect(log.first?.source == "Uninstall" && log.first?.items == 2)

        model.undoUninstall()
        await model.undoJob?.value
        #expect(home.exists("Applications/Editor.app/Contents/Info.plist"))
        #expect(home.exists("Library/Caches/com.vendor.Editor/c"))
        #expect(model.apps.map(\.name) == ["Editor"])
    }

    @Test func refusesAnAppReplacedSinceTheListing() async throws {
        let home = try Home()
        let model = home.model()
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        let info: NSDictionary = ["CFBundleIdentifier": "org.other.Thing"]
        try info.write(to: home.url.appending(path: "Applications/Editor.app/Contents/Info.plist"))
        let result = await model.uninstall(app, leftovers: [])
        #expect(result == .refused("Editor changed since the list was made. Reload and try again."))
        #expect(home.exists("Applications/Editor.app"))
    }

    @Test func aCopyElsewhereKeepsTheLeftovers() async throws {
        let home = try Home()
        let model = home.model(copies: ["/synthetic/Volumes/External/Editor.app"])
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        #expect(await model.leftovers(for: app)?.isEmpty == true)
    }

    @Test func noLeftoversWhenOtherCopiesCantBeLookedUp() async throws {
        let home = try Home()
        let lookedUp = home.model()
        lookedUp.load()
        await lookedUp.loadJob?.value
        let listed = try #require(lookedUp.apps.first)
        let found = try #require(await lookedUp.leftovers(for: listed))
        let model = home.model(copies: nil)
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        #expect(await model.leftovers(for: app) == nil)
        // Leftovers chosen before the lookup failed stay; the app alone may go.
        let result = await model.uninstall(app, leftovers: found)
        #expect(result == .refused("Other copies of Editor couldn't be looked up, so its leftovers stay. Untick them to move only the app."))
        #expect(home.exists("Applications/Editor.app"))
        #expect(home.exists("Library/Caches/com.vendor.Editor/c"))
        #expect(await model.uninstall(app, leftovers: []) == .done)
        #expect(!home.exists("Applications/Editor.app"))
        #expect(home.exists("Library/Caches/com.vendor.Editor/c"))
        model.undoUninstall()
        await model.undoJob?.value
        #expect(home.exists("Applications/Editor.app/Contents/Info.plist"))
    }

    @Test func anAppWithItsOwnUninstallerIsLeftToIt() async throws {
        let home = try Home()
        try home.write("Applications/Editor.app/Contents/Resources/Uninstall Editor.app/Contents/MacOS/bin")
        let model = home.model()
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first { $0.name == "Editor" })
        #expect(model.ownUninstaller(of: app) != nil)
        let result = await model.uninstall(app, leftovers: [])
        #expect(result == .refused("Editor comes with its own uninstaller. Use that instead."))
        #expect(home.exists("Applications/Editor.app"))
    }

    final class Asked { var calls: [(paths: [String], appID: String, ids: [String])] = [] }

    @Test func systemLeftoversNeedRootAndGoThroughTheTool() async throws {
        let home = try Home()
        try home.write("system/Library/PrivilegedHelperTools/com.vendor.Editor.helper")
        try home.write("system/Library/Preferences/com.vendor.Editor.plist")
        let asked = Asked()
        final class Ready { var value = false }
        let ready = Ready()
        let side = AppsModel.SystemSide(base: home.path + "/system", isReady: { ready.value }, remove: { paths, appID, ids in
            asked.calls.append((paths, appID, ids))
            var r = RemovalReport()
            r.removed = paths
            return r
        })
        let model = home.model(system: side)
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        let found = await model.systemLeftovers(for: app)
        #expect(found.map(\.name) == ["com.vendor.Editor.helper", "com.vendor.Editor.plist"])
        #expect(found.filter(\.kind.chosenByDefault).map(\.name) == ["com.vendor.Editor.helper"])

        let refused = await model.uninstall(app, leftovers: [], system: found)
        #expect(refused == .refused("System-wide leftovers can't be removed in this edition. Untick them to go on."))
        #expect(home.exists("Applications/Editor.app"))
        #expect(asked.calls.isEmpty)

        ready.value = true
        let picked = found.filter(\.kind.chosenByDefault)
        #expect(await model.uninstall(app, leftovers: [], system: picked) == .done)
        #expect(asked.calls.count == 1)
        #expect(asked.calls.first?.paths == picked.map(\.path))
        #expect(asked.calls.first?.appID == "com.vendor.Editor")
        #expect(asked.calls.first?.ids == ["com.vendor.Editor"])
        #expect(model.notice?.text.contains("1 system item deleted for good") == true)
    }

    @Test func anotherInstalledAppsLongerIDKeepsItsSystemFiles() async throws {
        let home = try Home()
        try home.write("Applications/Editor Pro.app/Contents/MacOS/bin")
        let info: NSDictionary = ["CFBundleIdentifier": "com.vendor.Editor.Pro", "CFBundleName": "Editor Pro"]
        try info.write(to: home.url.appending(path: "Applications/Editor Pro.app/Contents/Info.plist"))
        try home.write("system/Library/PrivilegedHelperTools/com.vendor.Editor.Pro.helper")
        try home.write("system/Library/PrivilegedHelperTools/com.vendor.Editor.helper")
        let model = home.model()
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first { $0.bundleID == "com.vendor.Editor" })
        #expect(await model.systemLeftovers(for: app).map(\.name) == ["com.vendor.Editor.helper"])
    }
}
