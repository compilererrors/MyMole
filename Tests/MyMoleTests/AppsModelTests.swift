import Foundation
import Synchronization
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

        /// Keep lists and project rules of the test's own.
        var protections: UserProtections { UserProtections(root: url.appending(path: "support")) }

        /// `copies` nil: other copies can't be looked up.
        @MainActor func model(
            running: Bool = false, copies: [String]? = [], system: AppsModel.SystemSide? = nil,
            imageOf: @escaping @Sendable (String) -> MountedImage? = { _ in nil },
            eject: @escaping @Sendable (String) -> String? = { _ in "Not in tests" },
            identityReaders: AppIdentity.Readers = .init(groups: { _ in [] })
        ) -> AppsModel {
            AppsModel(
                home: path, folders: [path + "/Applications"], base: url.appending(path: "store"),
                logURL: url.appending(path: "history.json"), recycle: { [bin = testBin(url)] in Trasher.moveToTrash($0, through: TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing), backend: bin) },
                isRunning: { _ in running },
                otherCopies: { app in
                    copies?.map { AppBundle(path: $0, name: app.name, bundleID: app.bundleID, version: nil, bytes: 0, fromAppStore: false) }
                },
                system: system ?? AppsModel.SystemSide(base: path + "/system", isReady: { false }, remove: { _, _, _ in RemovalReport() }),
                trash: testBin(url), protections: protections, imageOf: imageOf, eject: eject, identityReaders: identityReaders)
        }

        /// A second app beside Editor, with a cache of its own.
        func addViewer() throws {
            try write("Applications/Viewer.app/Contents/MacOS/bin")
            let info: NSDictionary = ["CFBundleIdentifier": "com.vendor.Viewer", "CFBundleName": "Viewer"]
            try info.write(to: url.appending(path: "Applications/Viewer.app/Contents/Info.plist"))
            try write("Library/Caches/com.vendor.Viewer/c")
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

    @Test func aResetKeepsTheAppAndUndoPutsItsDataBack() async throws {
        let home = try Home()
        let model = home.model()
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        let leftovers = try #require(await model.leftovers(for: app))
        #expect(await model.reset(app, leftovers: []) == .refused("Choose what to reset."))

        #expect(await model.reset(app, leftovers: leftovers) == .done)
        #expect(home.exists("Applications/Editor.app/Contents/Info.plist"))
        #expect(!home.exists("Library/Caches/com.vendor.Editor") && !home.exists("Library/Preferences/com.vendor.Editor.plist"))
        #expect(model.apps.map(\.name) == ["Editor"] && model.notice?.canUndo == true)

        model.undoUninstall()
        await model.undoJob?.value
        #expect(home.exists("Library/Caches/com.vendor.Editor/c") && home.exists("Library/Preferences/com.vendor.Editor.plist"))
        // The app was never gone, so it isn't listed twice.
        #expect(model.apps.map(\.name) == ["Editor"])
    }

    @Test func aRunningAppIsntReset() async throws {
        let home = try Home()
        let model = home.model(running: true)
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        #expect(await model.reset(app, leftovers: await model.leftovers(for: app) ?? []) == .refused("Editor is open. Quit it first."))
        #expect(home.exists("Library/Caches/com.vendor.Editor/c"))
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
        try home.write("Volumes/External/Editor.app/Contents/MacOS/bin")
        try (["CFBundleIdentifier": "com.vendor.Editor", "CFBundleName": "Editor"] as NSDictionary)
            .write(to: home.url.appending(path: "Volumes/External/Editor.app/Contents/Info.plist"))
        let model = home.model(copies: [home.path + "/Volumes/External/Editor.app"])
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
        #expect(result == .refused("Ownership of Editor's leftovers couldn't be verified. Untick them to move only the app."))
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
        #expect(await model.ownUninstaller(of: app) != nil)
        let result = await model.uninstall(app, leftovers: [])
        #expect(result == .refused("Editor comes with its own uninstaller. Use that instead."))
        #expect(home.exists("Applications/Editor.app"))
    }

    /// Another pane's move holds the turn; the uninstall is started behind
    /// it and returned once it waits there.
    private func uninstallWaitingItsTurn(_ model: AppsModel, _ app: AppBundle) async throws -> (other: TrashJob, run: Task<AppsModel.Result, Never>) {
        let other = await model.jobs.begin(.moveToTrash)
        let run = Task { await model.uninstall(app, leftovers: []) }
        for _ in 0..<1000 where model.jobs.waiting == 0 { try await Task.sleep(for: .milliseconds(5)) }
        return (other, run)
    }

    @Test func anAppReplacedWhileTheUninstallWaitsItsTurnStays() async throws {
        let home = try Home()
        let model = home.model()
        model.jobs = TrashJobs()
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        let (other, run) = try await uninstallWaitingItsTurn(model, app)
        let info: NSDictionary = ["CFBundleIdentifier": "org.other.Thing"]
        try info.write(to: home.url.appending(path: "Applications/Editor.app/Contents/Info.plist"))
        model.jobs.end(other)
        #expect(await run.value == .refused("Editor changed since the list was made. Reload and try again."))
        #expect(home.exists("Applications/Editor.app"))
    }

    @Test func anAppKeptWhileTheUninstallWaitsItsTurnStays() async throws {
        let home = try Home()
        let model = home.model()
        model.jobs = TrashJobs()
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        let (other, run) = try await uninstallWaitingItsTurn(model, app)
        try CleanKeepList(paths: [app.path]).save(to: home.protections.keepList)
        model.jobs.end(other)
        #expect(await run.value == .refused("Editor is on one of your keep lists, or holds something that is, so it stays."))
        #expect(home.exists("Applications/Editor.app"))
    }

    @Test func aLeftoverNamedTwiceGoesOnce() async throws {
        let home = try Home()
        let model = home.model()
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        let cache = try #require(await model.leftovers(for: app)?.first { $0.place == "Caches" })
        #expect(await model.uninstall(app, leftovers: [cache, cache]) == .done)
        #expect(!home.exists("Library/Caches/com.vendor.Editor"))
        let text = try #require(model.notice?.text)
        #expect(text.contains("and 1 leftover ") && !text.contains("couldn't be moved"))
        model.undoUninstall()
        await model.undoJob?.value
        #expect(home.exists("Applications/Editor.app/Contents/Info.plist") && home.exists("Library/Caches/com.vendor.Editor/c"))
    }

    @Test func leftoversKeptInDeepCleanOrProjectsStayAndTheAppGoes() async throws {
        let home = try Home()
        let cache = home.path + "/Library/Caches/com.vendor.Editor"
        let settings = home.path + "/Library/Preferences/com.vendor.Editor.plist"
        try CleanKeepList(paths: [cache]).save(to: home.protections.keepList)
        var rules = ProjectRules()
        rules.keepPaths = [settings]
        try ProjectStore.saveRules(rules, base: home.protections.projectBase)
        let model = home.model()
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        let leftovers = try #require(await model.leftovers(for: app))
        // The sheet shows both as kept before anything moves.
        #expect(await model.kept(among: [app.path] + leftovers.map(\.path)) == [cache, settings])

        #expect(await model.uninstall(app, leftovers: leftovers) == .done)
        #expect(!home.exists("Applications/Editor.app"))
        #expect(home.exists("Library/Caches/com.vendor.Editor/c"))
        #expect(home.exists("Library/Preferences/com.vendor.Editor.plist"))
        #expect(model.notice?.text.contains("2 couldn't be moved") == true)
        model.undoUninstall()
        await model.undoJob?.value
        #expect(home.exists("Applications/Editor.app/Contents/Info.plist"))
    }

    @Test func aKeepListThatCantBeReadStopsTheUninstall() async throws {
        let home = try Home()
        let list = home.protections.keepList
        try FileManager.default.createDirectory(at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: list)
        let model = home.model()
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        #expect(await model.kept(among: [app.path]) == nil)
        #expect(await model.uninstall(app, leftovers: []) == .refused("Your keep lists couldn't be read, so nothing was moved."))
        #expect(home.exists("Applications/Editor.app"))
    }

    @Test func aSystemItemOnSystemCleansKeepListIsNeverSentToTheTool() async throws {
        let home = try Home()
        try home.write("system/Library/PrivilegedHelperTools/com.vendor.Editor.helper")
        try home.write("system/Library/Preferences/com.vendor.Editor.plist")
        let helper = home.path + "/system/Library/PrivilegedHelperTools/com.vendor.Editor.helper"
        try CleanKeepList(paths: [helper]).save(to: home.protections.systemKeepList)
        let asked = Asked()
        let side = AppsModel.SystemSide(base: home.path + "/system", isReady: { true }, remove: { paths, appID, ids in
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
        #expect(await model.kept(among: found.map(\.path), system: true) == [helper])

        #expect(await model.uninstall(app, leftovers: [], system: found) == .done)
        #expect(asked.calls.count == 1)
        #expect(asked.calls.first?.paths == found.map(\.path).filter { $0 != helper })
        #expect(model.systemProblems.map(\.path) == [helper])
        #expect(model.notice?.text.contains("1 system item stayed") == true)
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

    @Test func severalAppsGoTogetherAndOneUndoPutsThemAllBack() async throws {
        let home = try Home()
        try home.addViewer()
        let model = home.model()
        model.load()
        await model.loadJob?.value
        #expect(model.apps.count == 2)
        var items: [AppsModel.BatchItem] = []
        for app in model.apps {
            items.append(AppsModel.BatchItem(app: app, leftovers: (await model.leftovers(for: app) ?? []).filter(\.kind.chosenByDefault)))
        }
        let problems = await model.uninstall(batch: items)
        #expect(problems.isEmpty)
        #expect(!home.exists("Applications/Editor.app") && !home.exists("Applications/Viewer.app"))
        #expect(!home.exists("Library/Caches/com.vendor.Viewer") && !home.exists("Library/Caches/com.vendor.Editor"))
        // Settings weren't chosen.
        #expect(home.exists("Library/Preferences/com.vendor.Editor.plist"))
        #expect(model.notice?.canUndo == true)

        model.undoLatest()
        await model.undoJob?.value
        #expect(home.exists("Applications/Editor.app") && home.exists("Applications/Viewer.app"))
        #expect(home.exists("Library/Caches/com.vendor.Viewer") && home.exists("Library/Caches/com.vendor.Editor"))
        #expect(!model.canUndo)
    }

    @Test func anOpenAppStaysOutOfABatchAndTheRestGoes() async throws {
        let home = try Home()
        try home.addViewer()
        let model = AppsModel(
            home: home.path, folders: [home.path + "/Applications"], base: home.url.appending(path: "store"),
            logURL: home.url.appending(path: "history.json"),
            recycle: { [bin = testBin(home.url)] in Trasher.moveToTrash($0, through: TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing), backend: bin) },
            isRunning: { $0.name == "Viewer" }, otherCopies: { _ in [] }, trash: testBin(home.url), protections: home.protections,
            imageOf: { _ in nil }, eject: { _ in nil })
        model.load()
        await model.loadJob?.value
        let problems = await model.uninstall(batch: model.apps.map { AppsModel.BatchItem(app: $0, leftovers: []) })
        #expect(problems.map(\.name) == ["Viewer"])
        #expect(!home.exists("Applications/Editor.app") && home.exists("Applications/Viewer.app"))
    }

    @Test func aDroppedAppOpensAndOtherFilesAreLeftOut() async throws {
        let home = try Home()
        try home.write("Downloads/Viewer.app/Contents/MacOS/bin")
        let info: NSDictionary = ["CFBundleIdentifier": "com.vendor.Viewer", "CFBundleName": "Viewer"]
        try info.write(to: home.url.appending(path: "Downloads/Viewer.app/Contents/Info.plist"))
        try home.write("Downloads/notes.txt")
        let model = home.model()
        model.load()
        await model.loadJob?.value

        model.open([home.url.appending(path: "Downloads/notes.txt")])
        #expect(model.dropped.isEmpty && model.notice != nil)

        // One outside the Applications folders, and the listed one, which is used as listed.
        model.open([home.url.appending(path: "Downloads/Viewer.app"), home.url.appending(path: "Applications/Editor.app")])
        await model.dropJob?.value
        #expect(model.dropped.map(\.name).sorted() == ["Editor", "Viewer"])
        #expect(model.dropped.first { $0.name == "Editor" } == model.apps.first)
    }

    @Test func anAppOnADiskImageOffersItsImageWhichGoesOnceEjected() async throws {
        let home = try Home()
        try home.write("Downloads/Editor.dmg")
        let image = MountedImage(image: home.path + "/Downloads/Editor.dmg", mountPoint: "/Volumes/Editor")
        let ejected = Mutex<[String]>([])
        let app = AppBundle(path: "/Volumes/Editor/Editor.app", name: "Editor", bundleID: "com.vendor.Editor", version: nil, bytes: 1, fromAppStore: false)
        let model = home.model(imageOf: { _ in image }, eject: { point in ejected.withLock { $0.append(point) }; return nil })

        let item = AppsModel.ImageApp(app: app, mountPoint: image.mountPoint, image: image)
        #expect(await model.removeImage(item) == .done)
        #expect(ejected.withLock { $0 } == ["/Volumes/Editor"])
        #expect(!home.exists("Downloads/Editor.dmg"))
        model.undoLatest()
        await model.undoJob?.value
        #expect(home.exists("Downloads/Editor.dmg"))
    }

    @Test func anImageThatWontEjectStays() async throws {
        let home = try Home()
        try home.write("Downloads/Editor.dmg")
        let image = MountedImage(image: home.path + "/Downloads/Editor.dmg", mountPoint: "/Volumes/Editor")
        let app = AppBundle(path: "/Volumes/Editor/Editor.app", name: "Editor", bundleID: "com.vendor.Editor", version: nil, bytes: 1, fromAppStore: false)
        let model = home.model(eject: { _ in "In use" })
        let result = await model.removeImage(AppsModel.ImageApp(app: app, mountPoint: image.mountPoint, image: image))
        #expect(result == .failed("Editor.dmg couldn't be ejected: In use"))
        #expect(home.exists("Downloads/Editor.dmg"))
    }

    @Test func aMacOSAppIsResetNeverUninstalled() async throws {
        let home = try Home()
        try home.write("Library/Caches/com.apple.Safari/c")
        try home.write("Library/Containers/com.apple.Safari/Data/x")
        try home.write("Applications/Safari.app/Contents/MacOS/bin")
        try (["CFBundleIdentifier": "com.apple.Safari", "CFBundleName": "Safari"] as NSDictionary)
            .write(to: home.url.appending(path: "Applications/Safari.app/Contents/Info.plist"))
        let safari = AppBundle(path: home.path + "/Applications/Safari.app", name: "Safari", bundleID: "com.apple.Safari", version: nil, bytes: 1, fromAppStore: false)
        let model = home.model()
        let found = try #require(await model.leftovers(for: safari))
        #expect(found.map(\.place) == ["Caches"])
        #expect(await model.uninstall(safari, leftovers: found) == .refused("Safari is part of macOS."))
        #expect(await model.reset(safari, leftovers: found) == .done)
        #expect(!home.exists("Library/Caches/com.apple.Safari") && home.exists("Library/Containers/com.apple.Safari"))
        #expect(await model.systemLeftovers(for: safari).isEmpty)
    }

    @Test func aKeptImageIsNeverEjected() async throws {
        let home = try Home()
        try home.write("Downloads/Editor.dmg")
        let image = MountedImage(image: home.path + "/Downloads/Editor.dmg", mountPoint: "/Volumes/Editor")
        let ejected = Mutex(0)
        let model = home.model(eject: { _ in ejected.withLock { $0 += 1 }; return nil })
        _ = try CleanKeepList.update(at: home.protections.keepList) { $0.paths.insert(image.image) }
        let app = AppBundle(path: "/Volumes/Editor/Editor.app", name: "Editor", bundleID: "com.vendor.Editor", version: nil, bytes: 1, fromAppStore: false)
        let result = await model.removeImage(AppsModel.ImageApp(app: app, mountPoint: image.mountPoint, image: image))
        #expect(result == .refused("Editor.dmg is on one of your keep lists, so it stays."))
        #expect(ejected.withLock { $0 } == 0 && home.exists("Downloads/Editor.dmg"))
    }

    @Test func whatTheDeeperSearchFindsGoesOnlyWhenChosen() async throws {
        let home = try Home()
        try home.write(".config/editor/settings.json")
        let model = home.model()
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        #expect(!(try #require(await model.leftovers(for: app, deep: false))).contains { $0.path.hasSuffix(".config/editor") })
        let deep = try #require(await model.leftovers(for: app, deep: true))
        let config = try #require(deep.first { $0.path.hasSuffix(".config/editor") })
        #expect(config.evidence == .loose && !config.chosenByDefault)
        #expect(await model.uninstall(app, leftovers: [config]) == .done)
        #expect(!home.exists(".config/editor"))
    }
    @Test func unreadableIdentityBlocksChosenDataButTheAppAloneCanGo() async throws {
        let home = try Home()
        let known = home.model()
        known.load()
        await known.loadJob?.value
        let app = try #require(known.apps.first)
        let chosen = try #require(await known.leftovers(for: app))
        let model = home.model(identityReaders: .init(groups: { _ in nil }))
        #expect(await model.leftovers(for: app) == nil)
        #expect(await model.systemLeftovers(for: app).isEmpty)
        #expect(await model.uninstall(app, leftovers: chosen) == .refused("Ownership of Editor's leftovers couldn't be verified. Untick them to move only the app."))
        #expect(await model.reset(app, leftovers: chosen) == .refused("Ownership of Editor's leftovers couldn't be verified, so nothing was reset."))
        #expect(home.exists("Applications/Editor.app") && home.exists("Library/Caches/com.vendor.Editor"))
        #expect(await model.uninstall(app, leftovers: []) == .done)
        #expect(home.exists("Library/Caches/com.vendor.Editor") && home.exists("Library/Preferences/com.vendor.Editor.plist"))
    }

    @Test func anUnknownGroupOwnerInstalledWhileQueuedStopsUninstallBeforeRecycle() async throws {
        let home = try Home()
        let group = "ABCDE12345.com.vendor.shared"
        try home.write("Library/Group Containers/" + group + "/database")
        let readers = AppIdentity.Readers(groups: { path in path.hasSuffix("Viewer.app") ? nil : [group] })
        let model = home.model(identityReaders: readers)
        model.jobs = TrashJobs()
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        let chosen = try #require(await model.leftovers(for: app)).filter { $0.name == group }
        #expect(chosen.count == 1)
        let held = await model.jobs.begin(.moveToTrash)
        defer { model.jobs.end(held) }
        let pending = Task { await model.uninstall(app, leftovers: chosen) }
        for _ in 0..<1_000 where model.jobs.waiting == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(model.jobs.waiting == 1)
        try home.addViewer()
        model.jobs.end(held)
        #expect(await pending.value == .refused("Ownership changed or couldn't be verified while waiting. Nothing was uninstalled."))
        #expect(home.exists("Applications/Editor.app") && home.exists("Library/Group Containers/" + group + "/database"))
    }

    @Test func aNewSharedGroupOwnerIsRespectedWhenAQueuedResetStarts() async throws {
        let home = try Home()
        let group = "ABCDE12345.com.vendor.shared"
        try home.write("Library/Group Containers/" + group + "/database")
        let model = home.model(identityReaders: .init(groups: { _ in [group] }))
        model.jobs = TrashJobs()
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        let chosen = try #require(await model.leftovers(for: app)).filter { $0.name == group }
        #expect(chosen.count == 1)
        let held = await model.jobs.begin(.moveToTrash)
        defer { model.jobs.end(held) }
        let pending = Task { await model.reset(app, leftovers: chosen) }
        for _ in 0..<1_000 where model.jobs.waiting == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(model.jobs.waiting == 1)
        try home.addViewer()
        model.jobs.end(held)
        let outcome = await pending.value
        if case .failed = outcome {} else { Issue.record("A newly shared group must not be reset") }
        #expect(home.exists("Applications/Editor.app") && home.exists("Library/Group Containers/" + group + "/database"))
    }

    @Test func anotherAppsHelperIsNotOfferedAsASystemLeftover() async throws {
        let home = try Home()
        try home.addViewer()
        try home.write("Applications/Viewer.app/Contents/XPCServices/Shared.xpc/Contents/MacOS/code")
        try (["CFBundleIdentifier": "COM.VENDOR.EDITOR.Shared"] as NSDictionary)
            .write(to: home.url.appending(path: "Applications/Viewer.app/Contents/XPCServices/Shared.xpc/Contents/Info.plist"))
        try home.write("system/Library/LaunchAgents/com.vendor.Editor.Shared.plist")
        let model = home.model()
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first { $0.bundleID == "com.vendor.Editor" })
        #expect(await model.systemLeftovers(for: app).isEmpty)
    }

    @Test func stopDuringTheFinalOwnershipReadPreventsRecyclingTheApp() async throws {
        let home = try Home()
        let known = home.model()
        known.load()
        await known.loadJob?.value
        let app = try #require(known.apps.first)
        let chosen = try #require(await known.leftovers(for: app))
        let calls = Mutex(0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = home.model(identityReaders: .init(groups: { _ in
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 2 { _ = release.wait(timeout: .now() + 5) }
            return []
        }))
        model.jobs = TrashJobs()
        let pending = Task { await model.uninstall(app, leftovers: chosen) }
        for _ in 0..<1_000 where calls.withLock({ $0 }) < 2 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(calls.withLock { $0 } == 2)
        model.jobs.stop()
        release.signal()
        #expect(await pending.value == .refused("Stopped before anything was moved."))
        #expect(home.exists("Applications/Editor.app") && home.exists("Library/Caches/com.vendor.Editor"))
    }

}
