import Foundation
import StorageKit
import Testing

@testable import MyMole

@MainActor @Suite struct SelfRemovalTests {
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "self-removal-\(UUID().uuidString)")
        var path: String { root.path }
        var appPath: String { path + "/Applications/Cleaner.app" }
        let bundleID = "org.example.Cleaner"
        var events: [String] = []

        init() throws {
            try file("Applications/Cleaner.app/Contents/MacOS/program")
            let info: NSDictionary = ["CFBundleIdentifier": bundleID, "CFBundleName": "Cleaner"]
            try info.write(to: root.appending(path: "Applications/Cleaner.app/Contents/Info.plist"))
            try file("Library/Caches/org.example.Cleaner/cache")
            try file("Library/Application Support/Cleaner/history.json")
            try file("Library/Preferences/org.example.Cleaner.plist")
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func file(_ relative: String) throws {
            let url = root.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 100).write(to: url)
        }

        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: path + "/" + relative) }

        func model(prepareFailure: String? = nil, copiesUnavailable: Bool = false,
                   denyNativeMove: Bool = false, finder: FinderAppTrash? = nil, reviewSourceAvailable: Bool = true) -> SelfRemovalModel {
            let backend = testBin(root)
            let apps = AppsModel(
                home: path, folders: [path + "/Applications"], base: root.appending(path: "saved"),
                logURL: root.appending(path: "Library/Application Support/Cleaner/history.json"),
                recycle: { [self] paths in
                    events.append("recycle")
                    if denyNativeMove {
                        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
                        return TrashOutcome(moved: [], failed: paths.map { ($0, error.localizedDescription) },
                            failureInfo: Dictionary(uniqueKeysWithValues: paths.map { ($0, .init(error, area: .uninstall)) }))
                    }
                    return Trasher.moveToTrash(paths, through: TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing), backend: backend)
                }, finderTrash: finder, isRunning: { _ in true }, otherCopies: { _ in copiesUnavailable ? nil : [] },
                system: AppsModel.SystemSide(base: path + "/system", isReady: { false }, remove: { _, _, _ in .init() }),
                trash: backend, protections: UserProtections(root: root.appending(path: "protections")),
                imageOf: { _ in nil }, eject: { _ in "Not in tests" }, ownAppPath: appPath, ownAppID: bundleID, identityReaders: .init(groups: { _ in [] }))
            return SelfRemovalModel(apps: apps, prepare: { [self] in
                events.append("prepare")
                return prepareFailure
            }, resume: { [self] in events.append("resume") }, quit: { [self] in events.append("quit") },
                readReviewSource: { reviewSourceAvailable ? RemovedApp.Source.capture($0) : nil })
        }
    }

    @Test func selfRemovalKeepsSettingsUnlessChosenAndQuitsAfterMoving() async throws {
        let fixture = try Fixture()
        let model = fixture.model()
        await model.load()
        #expect(model.canRemove)
        #expect(model.chosenLeftovers.allSatisfy { $0.kind == .rebuildable })
        await model.remove()
        #expect(fixture.events == ["prepare", "recycle", "quit"])
        #expect(model.removed && !model.running)
        #expect(!fixture.exists("Applications/Cleaner.app"))
        #expect(!fixture.exists("Library/Caches/org.example.Cleaner"))
        #expect(fixture.exists("Library/Preferences/org.example.Cleaner.plist"))
        #expect(fixture.exists("Library/Application Support/Cleaner/history.json"))
    }

    @Test func replacingTheReviewedAppNeverRemovesTheReplacementOrItsData() async throws {
        let fixture = try Fixture()
        let model = fixture.model()
        await model.load()
        let original = fixture.root.appending(path: "Original-held.app")
        try FileManager.default.moveItem(at: URL(fileURLWithPath: fixture.appPath), to: original)
        try fixture.file("Applications/Cleaner.app/Contents/MacOS/program")
        let info: NSDictionary = ["CFBundleIdentifier": fixture.bundleID, "CFBundleName": "Replacement"]
        try info.write(to: fixture.root.appending(path: "Applications/Cleaner.app/Contents/Info.plist"))
        await model.remove()
        #expect(!model.removed && !model.running && model.problem != nil)
        #expect(fixture.events.isEmpty)
        #expect(fixture.exists("Applications/Cleaner.app/Contents/MacOS/program"))
        #expect(fixture.exists("Library/Caches/org.example.Cleaner/cache"))
        #expect(fixture.exists("Original-held.app/Contents/MacOS/program"))
    }

    @Test func finderCanMoveOnlyTheReviewedSelfAfterNativePermissionDenial() async throws {
        let fixture = try Fixture()
        var prompts = 0
        let finder = FinderAppTrash(authorize: { prompts += 1; return 0 }, move: { request in
            #expect(request.stillCurrent())
            #expect(request.source.path == fixture.appPath)
            #expect(fixture.exists("Library/Preferences/org.example.Cleaner.plist"))
            do {
                let trash = fixture.root.appending(path: ".Trash")
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: request.source, to: trash.appending(path: "Cleaner.app"))
                return 0
            } catch { Issue.record(error); return -1 }
        })
        let model = fixture.model(denyNativeMove: true, finder: finder)
        await model.load()
        model.chosen = []
        await model.remove()
        #expect(model.removed && prompts == 1)
        #expect(fixture.events == ["prepare", "recycle", "quit"])
        #expect(fixture.exists(".Trash/Cleaner.app/Contents/MacOS/program"))
        #expect(fixture.exists("Library/Preferences/org.example.Cleaner.plist"))
    }

    @Test func aReviewCanWaitForTheExactBundleGrantBeforeReadingItsParent() async throws {
        let fixture = try Fixture()
        let model = fixture.model(reviewSourceAvailable: false)
        await model.load()
        #expect(model.canRemove)
        await model.remove()
        #expect(model.removed && fixture.events.last == "quit")
        #expect(fixture.exists("Library/Preferences/org.example.Cleaner.plist"))
    }

    @Test func chosenOwnDataIsNotRecreatedByTheUninstallHistory() async throws {
        let fixture = try Fixture()
        let model = fixture.model()
        await model.load()
        model.chosen = Set(model.leftovers.map(\.path))
        await model.remove()
        CleanupLog.flush()
        #expect(model.removed)
        #expect(!fixture.exists("Library/Application Support/Cleaner"))
        #expect(!fixture.exists("Library/Preferences/org.example.Cleaner.plist"))
    }

    @Test func failedShutdownPreparationLeavesAppAndDataAndResumes() async throws {
        let fixture = try Fixture()
        let model = fixture.model(prepareFailure: "Synthetic login removal failed.")
        await model.load()
        await model.remove()
        #expect(!model.removed && !model.running)
        #expect(fixture.events == ["prepare", "resume"])
        #expect(fixture.exists("Applications/Cleaner.app"))
        #expect(fixture.exists("Library/Caches/org.example.Cleaner"))
    }

    @Test func ownCopyRequiresTheDedicatedFlowAndNeverRunsInABatch() async throws {
        let fixture = try Fixture()
        let model = fixture.model()
        await model.load()
        let app = try #require(model.app)
        let result = await model.apps.uninstall(app, leftovers: [])
        #expect(result == .refused("Use Uninstall MyMole in Settings to remove this running copy."))
        let problems = await model.apps.uninstall(batch: [.init(app: app, leftovers: [])])
        #expect(problems.count == 1 && fixture.events.isEmpty)
        #expect(fixture.exists("Applications/Cleaner.app"))
        let other = AppBundle(path: fixture.path + "/Elsewhere/Cleaner.app", name: app.name, bundleID: app.bundleID, version: nil, bytes: 0, fromAppStore: false)
        #expect(!model.apps.isSelf(other))
        #expect(await model.apps.uninstall(other, leftovers: []) == .refused("Cleaner is open. Quit it first."))
    }

    @Test func anotherEditionClaimsItsSharedDataBeforeTheAppListHasLoaded() async throws {
        let fixture = try Fixture()
        try fixture.file("Applications/Cleaner Store.app/Contents/MacOS/program")
        let info: NSDictionary = ["CFBundleIdentifier": "org.example.Cleaner.Store", "CFBundleName": "Cleaner"]
        try info.write(to: fixture.root.appending(path: "Applications/Cleaner Store.app/Contents/Info.plist"))
        let model = fixture.model()
        #expect(model.apps.apps.isEmpty)
        await model.load()
        #expect(!model.leftovers.contains { $0.path.hasSuffix("/Application Support/Cleaner") })
        model.chosen = Set(model.leftovers.map(\.path))
        await model.remove()
        #expect(model.removed)
        #expect(fixture.exists("Library/Application Support/Cleaner/history.json"))
        #expect(fixture.exists("Applications/Cleaner Store.app"))
    }

    @Test func failedCopyLookupStillAllowsRemovingOnlyThisApp() async throws {
        let fixture = try Fixture()
        let model = fixture.model(copiesUnavailable: true)
        await model.load()
        #expect(model.dataUnavailable && !model.leftovers.isEmpty)
        #expect(model.leftovers.allSatisfy { !$0.canRemove && !$0.chosenByDefault })
        // Even a stale/programmatic choice cannot include inspection-only data.
        model.chosen = Set(model.leftovers.map(\.path))
        #expect(model.chosenLeftovers.isEmpty)
        await model.remove()
        #expect(model.removed && fixture.events.last == "quit")
        #expect(!fixture.exists("Applications/Cleaner.app"))
        #expect(fixture.exists("Library/Application Support/Cleaner/history.json"))
        #expect(fixture.exists("Library/Caches/org.example.Cleaner"))
    }

    @Test func selfRemovalReportsAnUninspectedLinkedLocation() async throws {
        let fixture = try Fixture()
        let cache = fixture.root.appending(path: "Library/Caches")
        let elsewhere = fixture.root.appending(path: "ElsewhereCaches")
        try FileManager.default.moveItem(at: cache, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: elsewhere)
        let model = fixture.model()
        await model.load()
        #expect(model.dataIncomplete && !model.dataUnavailable)
        #expect(model.canRemove)
        #expect(!model.leftovers.contains { $0.place == "Caches" })
        #expect(fixture.exists("ElsewhereCaches/org.example.Cleaner/cache"))
        #expect(fixture.events.isEmpty)
    }
}
