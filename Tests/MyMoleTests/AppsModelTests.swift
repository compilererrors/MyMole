import Darwin
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
            identityReaders: AppIdentity.Readers = .init(groups: { _ in [] }), runtimeRoots: [RuntimeLeftovers.Root] = [], homePath: String? = nil,
            recycle: (@MainActor ([String]) async -> TrashOutcome)? = nil,
            recycleURL: (@MainActor (URL) async -> TrashOutcome)? = nil,
            fallbackRecycle: (@MainActor (URL) async -> TrashOutcome)? = nil,
            appAccess: AppBundleAccess? = nil,
            runningCheck: (@MainActor (AppBundle) -> Bool)? = nil,
            lookUpCopies: (@Sendable (AppBundle) -> [AppBundle]?)? = nil
        ) -> AppsModel {
            let homePath = homePath ?? path
            return AppsModel(
                home: homePath, folders: [homePath + "/Applications"], base: url.appending(path: "store"),
                logURL: url.appending(path: "history.json"), recycle: recycle ?? { [bin = testBin(url)] in Trasher.moveToTrash($0, through: TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing), backend: bin) },
                recycleURL: recycleURL, fallbackRecycle: fallbackRecycle, appAccess: appAccess,
                isRunning: runningCheck ?? { _ in running },
                otherCopies: lookUpCopies ?? { app in
                    copies?.map { AppBundle(path: $0, name: app.name, bundleID: app.bundleID, version: nil, bytes: 0, fromAppStore: false) }
                },
                system: system ?? AppsModel.SystemSide(base: path + "/system", isReady: { false }, remove: { _, _, _ in RemovalReport() }),
                trash: testBin(url), protections: protections, imageOf: imageOf, eject: eject, identityReaders: identityReaders, runtimeRoots: runtimeRoots)
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

    private static func deniedRecycle(_ paths: [String]) -> TrashOutcome {
        AppsModel.recycleOutcome(urls: paths.map { URL(fileURLWithPath: $0) }, map: [:],
            error: NSError(domain: NSCocoaErrorDomain, code: 513,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -5000)]))
    }

    @Test func successfulNativeMovesSurviveDifferentDirectoryHintsInTheReply() {
        let source = URL(fileURLWithPath: "/synthetic/Editor.app", isDirectory: true)
        let key = URL(fileURLWithPath: "/synthetic/Editor.app", isDirectory: false)
        let target = URL(fileURLWithPath: "/synthetic/Trash/Editor.app", isDirectory: true)
        let outcome = AppsModel.recycleOutcome(urls: [source], map: [key: target], error: nil)
        #expect(outcome.moved == [.init(original: source, trashed: target)] && outcome.failed.isEmpty)
    }

    private static func simulatedAdministratorMove(_ app: AppBundle, _ source: RemovedApp.Source, home: String) throws -> ApplicationTrash.Receipt {
        let name = UUID().uuidString + "-" + (app.path as NSString).lastPathComponent
        let request = ApplicationTrash.Request(path: app.path, bundleID: try #require(app.bundleID),
            identity: source.originalIdentity, parentIdentity: source.originalParentIdentity, uid: getuid(), trashName: name)
        let trash = home + "/.Trash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.moveItem(atPath: app.path, toPath: trash + "/" + name)
        return .init(request: request, record: .init(original: URL(fileURLWithPath: app.path), trashed: URL(fileURLWithPath: trash + "/" + name)))
    }

    @Test func aNativePermissionFailureCanRequestAdministratorApprovalForOnlyTheConfirmedApp() async throws {
        let home = try Home()
        var calls = 0
        var model: AppsModel!
        let system = AppsModel.SystemSide(base: home.path + "/system", isReady: { true }, remove: { _, _, _ in .init() },
            trashApp: { app, source in
                calls += 1
                #expect(model.authorizingApp == app.path)
                #expect(home.exists("Library/Preferences/com.vendor.Editor.plist"))
                return try Self.simulatedAdministratorMove(app, source, home: home.path)
            })
        model = home.model(system: system, recycle: Self.deniedRecycle, fallbackRecycle: { Self.deniedRecycle([$0.path]) })
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        #expect(await model.uninstall(app, leftovers: []) == .done)
        #expect(calls == 1 && model.authorizingApp == nil && !model.uninstalling)
        #expect(!home.exists("Applications/Editor.app") && home.exists("Library/Preferences/com.vendor.Editor.plist"))
        model.undoUninstall()
        await model.undoJob?.value
        #expect(home.exists("Applications/Editor.app"))
    }

    @Test func cancellingAdministratorApprovalLeavesTheAppDataAndSystemFilesUntouched() async throws {
        let home = try Home()
        var calls = 0, systemCalls = 0
        let side = AppsModel.SystemSide(base: home.path + "/system", isReady: { true }, remove: { _, _, _ in systemCalls += 1; return .init() },
            trashApp: { _, _ in calls += 1; throw PrivilegedClient.Failure.cancelled })
        let model = home.model(system: side, recycle: Self.deniedRecycle)
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        if case .failed(let why) = await model.uninstall(app, leftovers: []) { #expect(why.contains("cancelled")) }
        else { Issue.record("Administrator cancellation must not report success") }
        #expect(calls == 1 && systemCalls == 0 && !model.uninstalling && model.authorizingApp == nil)
        #expect(home.exists("Applications/Editor.app") && home.exists("Library/Caches/com.vendor.Editor/c"))
        #expect(model.appMoveFailures[app.path]?.permissionDenied == false)
    }

    @Test(arguments: [false, true]) func administratorMovesRevalidateVerifiedAndManuallyReviewedLeftovers(_ manual: Bool) async throws {
        let home = try Home()
        let side = AppsModel.SystemSide(base: home.path + "/system", isReady: { true }, remove: { _, _, _ in .init() },
            trashApp: { app, source in try Self.simulatedAdministratorMove(app, source, home: home.path) })
        let model = home.model(system: side, identityReaders: .init(groups: { _ in manual ? nil : [] }), recycle: Self.deniedRecycle)
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let report = try #require(await model.leftoverReport(for: app))
        let cache = try #require(report.items.first { $0.place == "Caches" })
        if manual { #expect(!cache.canRemove && report.manualReview != nil) }
        #expect(await model.uninstall(app, leftovers: [cache], manualReview: manual ? report.manualReview : nil) == .done)
        #expect(!home.exists("Applications/Editor.app") && !home.exists("Library/Caches/com.vendor.Editor/c"))
        #expect(home.exists("Library/Preferences/com.vendor.Editor.plist"))
    }

    @Test func aCopyInstalledDuringAdministratorApprovalKeepsTheSharedData() async throws {
        let home = try Home()
        let side = AppsModel.SystemSide(base: home.path + "/system", isReady: { true }, remove: { _, _, _ in .init() },
            trashApp: { app, source in
                let receipt = try Self.simulatedAdministratorMove(app, source, home: home.path)
                try home.write("Applications/Editor.app/Contents/MacOS/bin")
                try NSDictionary(dictionary: ["CFBundleIdentifier": "com.vendor.Editor", "CFBundleName": "Replacement Editor"])
                    .write(to: URL(fileURLWithPath: home.path + "/Applications/Editor.app/Contents/Info.plist"))
                return receipt
            })
        let model = home.model(system: side, recycle: Self.deniedRecycle)
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let cache = try #require(await model.leftovers(for: app)?.first { $0.place == "Caches" })
        #expect(await model.uninstall(app, leftovers: [cache]) == .done)
        #expect(home.exists("Applications/Editor.app") && home.exists("Library/Caches/com.vendor.Editor/c"))
    }

    @Test func anAdministratorAttemptDoesNotStartIfTheAppStartsOrIsKeptAfterTheNativeFailure() async throws {
        for startApp in [false, true] {
            let home = try Home()
            var running = false, calls = 0
            let side = AppsModel.SystemSide(base: home.path + "/system", isReady: { true }, remove: { _, _, _ in .init() },
                trashApp: { _, _ in calls += 1; return nil })
            let model = home.model(system: side, recycle: { paths in
                if startApp { running = true } else { try! CleanKeepList(paths: Set(paths)).save(to: home.protections.keepList) }
                return Self.deniedRecycle(paths)
            }, runningCheck: { _ in running })
            let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
            _ = await model.uninstall(app, leftovers: [])
            #expect(calls == 0 && home.exists("Applications/Editor.app") && home.exists("Library/Caches/com.vendor.Editor/c"))
        }
    }

    @Test func administratorRestoreIsOnlyRequestedForTheRecordedAppAfterOrdinaryUndoFails() async throws {
        let home = try Home()
        var restores = 0
        let side = AppsModel.SystemSide(base: home.path + "/system", isReady: { true }, remove: { _, _, _ in .init() },
            trashApp: { app, source in try Self.simulatedAdministratorMove(app, source, home: home.path) },
            restoreApp: { receipt in
                restores += 1
                #expect(receipt.isInTrash(home: home.path))
                _ = chmod(home.path + "/Applications", 0o700)
                try FileManager.default.moveItem(at: receipt.record.trashed, to: receipt.record.original)
                return true
            })
        let model = home.model(system: side, recycle: Self.deniedRecycle)
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        #expect(await model.uninstall(app, leftovers: []) == .done)
        _ = chmod(home.path + "/Applications", 0o500)
        defer { _ = chmod(home.path + "/Applications", 0o700) }
        model.undoUninstall()
        await model.undoJob?.value
        #expect(restores == 1 && home.exists("Applications/Editor.app") && !model.canUndo)
    }

    @Test func reviewSharesOneOwnershipInventoryAndPublishesSmallFilesBeforeCompletion() async throws {
        let home = try Home()
        let reads = Mutex(0)
        let previews = Mutex<[[Leftover]]>([])
        let model = home.model(lookUpCopies: { _ in reads.withLock { $0 += 1 }; return [] })
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let report = await model.reviewReport(for: app) { items in previews.withLock { $0.append(items) } }
        #expect(reads.withLock { $0 } == 1)
        #expect(report.leftovers?.ownershipVerified == true)
        #expect(report.leftovers?.items.count == 2)
        let first = try #require(previews.withLock { $0.first })
        #expect(first.count == 1 && first[0].path.hasSuffix("com.vendor.Editor.plist"))
    }

    @Test func cheapPreviewDoesNotWaitForOwnershipAndCannotSupplyRemovalApproval() async throws {
        let home = try Home()
        let calls = Mutex(0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = home.model(lookUpCopies: { _ in
            calls.withLock { $0 += 1 }
            _ = release.wait(timeout: .now() + 3)
            return []
        })
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let discovery = Task { await model.reviewReport(for: app) }
        defer { discovery.cancel() }
        for _ in 0..<200 where calls.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(calls.withLock { $0 } == 1)
        let preview = await model.reviewPreview(for: app)
        #expect(preview.count == 2)
        #expect(preview.first { $0.place == "Caches" }?.bytes == nil)
        #expect(preview.first { $0.place == "Preferences" }?.bytes != nil)
        release.signal()
        let report = await discovery.value
        #expect(report.leftovers?.items.count == 2)
    }

    @Test func appOnlyRemovalDoesNotWaitForBackgroundDataDiscoveryOrTakeItsLateResults() async throws {
        let home = try Home()
        let started = Mutex(false)
        let completed = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = home.model(lookUpCopies: { _ in
            started.withLock { $0 = true }
            _ = release.wait(timeout: .now() + 5)
            completed.withLock { $0 = true }
            return []
        })
        model.jobs = TrashJobs()
        let app = try #require(AppFinder.read(home.path + "/Applications/Editor.app"))
        let discovery = Task { await model.reviewReport(for: app) }
        defer { discovery.cancel() }
        for _ in 0..<200 where !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        try #require(started.withLock { $0 })
        let intent = UninstallIntent(app: app, leftovers: [], system: [], manualReview: nil)
        #expect(await model.uninstall(intent.app, leftovers: intent.leftovers) == .done)
        #expect(!completed.withLock { $0 })
        #expect(!home.exists("Applications/Editor.app"))
        #expect(home.exists("Library/Preferences/com.vendor.Editor.plist"))
        #expect(home.exists("Library/Caches/com.vendor.Editor/c"))
        release.signal()
        _ = await discovery.value
        model.undoUninstall()
        await model.undoJob?.value
        #expect(home.exists("Applications/Editor.app"))
    }

    @Test func cancelledQueuedReviewsNeverStartAndOnlyOneOwnershipReadRunsAtATime() async throws {
        let home = try Home()
        let reads = Mutex(0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = home.model(lookUpCopies: { _ in
            let call = reads.withLock { $0 += 1; return $0 }
            if call == 1 { _ = release.wait(timeout: .now() + 3) }
            return []
        })
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let first = Task { await model.reviewReport(for: app) }
        for _ in 0..<200 where reads.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(reads.withLock { $0 } == 1)
        let skipped = Task { await model.reviewReport(for: app) }
        try await Task.sleep(for: .milliseconds(10))
        skipped.cancel()
        let latest = Task { await model.reviewReport(for: app) }
        try await Task.sleep(for: .milliseconds(10))
        #expect(reads.withLock { $0 } == 1)
        first.cancel()
        release.signal()
        #expect(await first.value.leftovers == nil)
        #expect(await skipped.value.leftovers == nil)
        #expect(await latest.value.leftovers?.items.count == 2)
        #expect(reads.withLock { $0 } == 2)
    }

    @Test func liveInventoryDetectsExternalInstallAndRemovalWithoutRepeatedSizeWalksWhenUnchanged() async throws {
        let home = try Home()
        let model = home.model()
        model.load()
        await model.loadJob?.value
        let date = model.scannedAt
        await model.refreshInventoryIfChanged()
        #expect(!model.loading && model.scannedAt == date)
        let info: NSDictionary = ["CFBundleIdentifier": "com.vendor.Editor", "CFBundleName": "Editor", "CFBundleShortVersionString": "2"]
        try info.write(to: home.url.appending(path: "Applications/Editor.app/Contents/Info.plist"))
        await model.refreshInventoryIfChanged()
        await model.loadJob?.value
        #expect(model.apps.first?.version == "2")
        try home.addViewer()
        await model.refreshInventoryIfChanged()
        await model.loadJob?.value
        #expect(model.apps.count == 2 && model.apps.allSatisfy { !$0.sizePending })
        try FileManager.default.removeItem(atPath: home.path + "/Applications/Viewer.app")
        await model.refreshInventoryIfChanged()
        await model.loadJob?.value
        #expect(model.apps.map(\.name) == ["Editor"])
        #expect(home.exists("Library/Caches/com.vendor.Viewer/c"))
    }

    @Test func stoppingAnInventoryIsNotUndoneByAutomaticRefresh() async throws {
        let home = try Home()
        let model = home.model()
        model.load()
        await model.loadJob?.value
        model.stop()
        try home.addViewer()
        await model.refreshInventoryIfChanged()
        #expect(!model.loading && model.apps.count == 1)
        model.load()
        await model.loadJob?.value
        #expect(model.apps.count == 2)
    }

    @Test func temporaryDataIsManualAndUsesTheSameGateAndUndoAsLibraryData() async throws {
        let home = try Home()
        try home.write("Runtime/Temp/com.vendor.Editor/draft")
        let root = RuntimeLeftovers.Root(path: home.path + "/Runtime/Temp", kind: .temporary)
        let model = home.model(runtimeRoots: [root])
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let report = try #require(await model.leftoverReport(for: app, deep: true))
        let temporary = try #require(report.items.first { $0.evidence == .runtimeID })
        #expect(!temporary.chosenByDefault && !report.limited && report.unreadable.isEmpty)
        #expect(await model.reset(app, leftovers: [temporary]) == .done)
        #expect(!home.exists("Runtime/Temp/com.vendor.Editor/draft"))
        #expect(home.exists("Library/Caches/com.vendor.Editor/c"))
        model.undoUninstall()
        await model.undoJob?.value
        #expect(home.exists("Runtime/Temp/com.vendor.Editor/draft"))
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

    @Test func appGrantCarriesOriginalSelectedURLThroughTheMoveAndThenReleasesIt() async throws {
        let home = try Home()
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let selected = URL(fileURLWithPath: app.path, isDirectory: true)
        var events: [String] = []
        let access = AppBundleAccess(choose: { _ in events.append("choose"); return selected },
                                     start: { _ in events.append("start"); return true },
                                     stop: { _ in events.append("stop") })
        let bin = testBin(home.url)
        let model = home.model(recycleURL: { source in
            #expect(source.absoluteString == selected.absoluteString)
            #expect(access.url == selected)
            events.append("move")
            return Trasher.moveToTrash([source.path], through: TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing), backend: bin)
        }, appAccess: access)
        #expect(await model.uninstall(app, leftovers: []) == .done)
        #expect(events == ["choose", "start", "move", "stop"])
        #expect(access.url == nil)
        #expect(home.exists("Library/Caches/com.vendor.Editor/c"))
    }

    @Test func cancelledOrWrongAppGrantNeverMovesTheAppOrItsData() async throws {
        let home = try Home()
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        var moves = 0, started = 0
        for selection in [nil, URL(fileURLWithPath: home.path + "/Applications/Other.app")] {
            let access = AppBundleAccess(choose: { _ in selection }, start: { _ in started += 1; return true }, stop: { _ in })
            let model = home.model(recycleURL: { _ in moves += 1; return TrashOutcome(moved: [], failed: []) }, appAccess: access)
            guard case .refused = await model.uninstall(app, leftovers: []) else { Issue.record("Missing exact-file access must stop the move"); continue }
            #expect(!model.uninstalling && access.url == nil)
        }
        #expect(moves == 0 && started == 0)
        #expect(home.exists("Applications/Editor.app/Contents/Info.plist"))
        #expect(home.exists("Library/Caches/com.vendor.Editor/c"))
    }

    @Test func appChangedWhileWaitingAfterGrantIsRefusedAndScopeIsReleased() async throws {
        let home = try Home()
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        var granted = false, stops = 0, moves = 0
        let access = AppBundleAccess(choose: { target in granted = true; return target }, start: { _ in true }, stop: { _ in stops += 1 })
        let model = home.model(recycleURL: { _ in moves += 1; return TrashOutcome(moved: [], failed: []) }, appAccess: access)
        let jobs = TrashJobs()
        model.jobs = jobs
        let blocker = await jobs.begin(.moveToTrash)
        let pending = Task { await model.uninstall(app, leftovers: []) }
        for _ in 0..<200 where !granted { try await Task.sleep(for: .milliseconds(5)) }
        #expect(granted)
        let info: NSDictionary = ["CFBundleIdentifier": "com.vendor.Other", "CFBundleName": "Editor"]
        try info.write(to: home.url.appending(path: "Applications/Editor.app/Contents/Info.plist"))
        jobs.end(blocker)
        guard case .refused = await pending.value else { Issue.record("The post-queue identity gate must still apply"); return }
        #expect(moves == 0 && stops == 1 && access.url == nil)
        #expect(home.exists("Library/Caches/com.vendor.Editor/c"))
    }

    @Test func aDeniedAppMoveLeavesAllItsDataAndSystemItemsUntouchedAndCanBeRetried() async throws {
        let home = try Home()
        let denied = Mutex(true)
        var systemCalls = 0
        try home.write("system/Library/Caches/com.vendor.Editor/item")
        let system = AppsModel.SystemSide(base: home.path + "/system", isReady: { true }, remove: { _, _, _ in
            systemCalls += 1
            return RemovalReport()
        })
        let bin = testBin(home.url)
        let model = home.model(system: system, recycle: { paths in
            if denied.withLock({ $0 }) {
                return AppsModel.recycleOutcome(urls: paths.map { URL(fileURLWithPath: $0) }, map: [:],
                    error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
            }
            return Trasher.moveToTrash(paths, through: TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing), backend: bin)
        })
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        let leftovers = try #require(await model.leftovers(for: app))
        let selected = leftovers.filter(\.chosenByDefault)
        let systemItem = SystemLeftover(path: home.path + "/system/Library/Caches/com.vendor.Editor", bytes: 3_000, place: "Caches", kind: .rebuildable)
        let failed = await model.uninstall(app, leftovers: selected, system: [systemItem])
        guard case .failed = failed else { Issue.record("A refused OS move must report failure"); return }
        #expect(model.appMoveFailures[app.path]?.permissionDenied == true)
        #expect(home.exists("Applications/Editor.app/Contents/Info.plist"))
        #expect(home.exists("Library/Caches/com.vendor.Editor/c"))
        #expect(home.exists("Library/Preferences/com.vendor.Editor.plist"))
        #expect(home.exists("system/Library/Caches/com.vendor.Editor/item"))
        #expect(systemCalls == 0 && !model.uninstalling && model.notice?.canUndo != true)
        #expect(model.apps.contains { $0.path == app.path })
        #expect(await model.reset(app, leftovers: []) == .refused("Choose what to reset."))
        #expect(model.appMoveFailures[app.path] == nil)
        denied.withLock { $0 = false }
        #expect(await model.uninstall(app, leftovers: selected) == .done)
        #expect(model.appMoveFailures[app.path] == nil)
        #expect(!home.exists("Applications/Editor.app"))
        #expect(home.exists("Library/Preferences/com.vendor.Editor.plist"))
    }

    @Test func finderCompletionKeepsSuccessfulMovesWhenOtherItemsFail() {
        let first = URL(fileURLWithPath: "/synthetic/Applications/First.app")
        let second = URL(fileURLWithPath: "/synthetic/Applications/Second.app")
        let destination = URL(fileURLWithPath: "/synthetic/Trash/First.app")
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        let result = AppsModel.recycleOutcome(urls: [first, second], map: [first: destination], error: error)
        #expect(result.moved == [TrashRecord(original: first, trashed: destination)])
        #expect(result.failed.map(\.path) == [second.path])
        #expect(result.failureInfo[first.path] == nil)
        #expect(result.failureInfo[second.path]?.permissionDenied == true)
        let missing = AppsModel.recycleOutcome(urls: [second], map: [:], error: nil)
        #expect(missing.moved.isEmpty && missing.failed.count == 1 && missing.failureInfo.isEmpty)
    }

    @Test func aDeniedAppKitMoveCanUseTheNormalTrashFallbackForTheSameApp() async throws {
        let home = try Home()
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        var fallbackCalls = 0
        let bin = testBin(home.url)
        let model = home.model(recycleURL: { source in
            AppsModel.recycleOutcome(urls: [source], map: [:], error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        }, fallbackRecycle: { source in
            fallbackCalls += 1
            return Trasher.moveToTrash([source.path], through: TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing), backend: bin)
        })
        #expect(await model.uninstall(app, leftovers: []) == .done)
        #expect(fallbackCalls == 1)
        #expect(!home.exists("Applications/Editor.app"))
        #expect(home.exists("Library/Caches/com.vendor.Editor/c"))
        #expect(model.notice?.canUndo == true)
        model.undoUninstall()
        await model.undoJob?.value
        #expect(home.exists("Applications/Editor.app"))
    }

    @Test func anIdenticalLookingReplacementCannotBeMovedByTheFallback() async throws {
        let home = try Home()
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        var fallbackCalls = 0
        let parked = home.url.appending(path: "parked.app")
        let model = home.model(recycleURL: { source in
            try! FileManager.default.moveItem(at: source, to: parked)
            try! FileManager.default.copyItem(at: parked, to: source)
            return AppsModel.recycleOutcome(urls: [source], map: [:], error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        }, fallbackRecycle: { _ in fallbackCalls += 1; return TrashOutcome(moved: [], failed: []) })
        guard case .failed = await model.uninstall(app, leftovers: []) else { Issue.record("The replacement must stay"); return }
        #expect(fallbackCalls == 0)
        #expect(home.exists("Applications/Editor.app/Contents/Info.plist"))
        #expect(home.exists("Library/Caches/com.vendor.Editor/c"))
    }

    @Test func anAppThatStartsAfterTheFirstDenialCannotEnterTheFallback() async throws {
        let home = try Home()
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        var running = false, fallbackCalls = 0
        let model = home.model(recycleURL: { source in
            running = true
            return AppsModel.recycleOutcome(urls: [source], map: [:], error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        }, fallbackRecycle: { _ in fallbackCalls += 1; return TrashOutcome(moved: [], failed: []) }, runningCheck: { _ in running })
        guard case .failed = await model.uninstall(app, leftovers: []) else { Issue.record("The running app must stay"); return }
        #expect(fallbackCalls == 0)
        #expect(home.exists("Applications/Editor.app/Contents/Info.plist"))
    }

    @Test func redirectingTheOriginalParentCannotAuthorizeTheFallback() async throws {
        let home = try Home()
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        var fallbackCalls = 0
        let parent = home.url.appending(path: "Applications")
        let movedParent = home.url.appending(path: "oldApplications")
        let model = home.model(recycleURL: { source in
            try! FileManager.default.moveItem(at: parent, to: movedParent)
            try! FileManager.default.createSymbolicLink(at: parent, withDestinationURL: movedParent)
            return AppsModel.recycleOutcome(urls: [source], map: [:], error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        }, fallbackRecycle: { _ in fallbackCalls += 1; return TrashOutcome(moved: [], failed: []) })
        guard case .failed = await model.uninstall(app, leftovers: []) else { Issue.record("The redirected parent must stop the fallback"); return }
        #expect(fallbackCalls == 0)
        #expect(home.exists("oldApplications/Editor.app/Contents/Info.plist"))
        #expect(home.exists("Library/Caches/com.vendor.Editor/c"))
    }

    @Test func explicitReviewRefreshReadsTheNewVersionAndRefusesAReplacementIdentity() async throws {
        let home = try Home()
        let model = home.model()
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        let info = home.url.appending(path: "Applications/Editor.app/Contents/Info.plist")
        try (["CFBundleIdentifier": "com.vendor.Editor", "CFBundleName": "Editor", "CFBundleShortVersionString": "2.0"] as NSDictionary).write(to: info)
        let refreshed = try #require(await model.refreshedForReview(app))
        #expect(refreshed.version == "2.0" && !refreshed.sizePending && refreshed.bytes > 0)
        #expect(refreshed.bytes == app.bytes)
        #expect(home.exists("Library/Preferences/com.vendor.Editor.plist"))
        try (["CFBundleIdentifier": "com.vendor.Replacement", "CFBundleName": "Replacement"] as NSDictionary).write(to: info)
        #expect(await model.refreshedForReview(app) == nil)
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
        #expect(found.allSatisfy { !$0.kind.chosenByDefault })

        let refused = await model.uninstall(app, leftovers: [], system: found)
        #expect(refused == .refused("System-wide leftovers can't be removed in this edition. Untick them to go on."))
        #expect(home.exists("Applications/Editor.app"))
        #expect(asked.calls.isEmpty)

        ready.value = true
        // The explicit review choice, independent of the conservative defaults.
        let picked = found.filter { $0.name == "com.vendor.Editor.helper" }
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

    @Test func everyReviewIncludesHiddenAndDeepDataWithoutASetting() async throws {
        let home = try Home()
        try home.write(".config/editor/settings.json")
        try home.write("Library/Application Support/Collection/Editor Local Data/database")
        try home.write("Runtime/Temp/com.vendor.Editor/draft")
        let root = RuntimeLeftovers.Root(path: home.path + "/Runtime/Temp", kind: .temporary)
        let model = home.model(runtimeRoots: [root])
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let report = try #require(await model.leftoverReport(for: app))
        #expect(report.ownershipVerified)
        for relative in [".config/editor", "Library/Application Support/Collection/Editor Local Data", "Runtime/Temp/com.vendor.Editor"] {
            let item = try #require(report.items.first { $0.path == home.path + "/" + relative })
            #expect(item.canRemove && !item.chosenByDefault)
        }
    }

    @Test func unknownOwnersDoNotHideDiscoverableDataOrAuthorizeItsRemoval() async throws {
        let home = try Home()
        try home.write(".config/editor/settings.json")
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let model = home.model(copies: nil)
        let report = try #require(await model.leftoverReport(for: app))
        #expect(!report.ownershipVerified)
        #expect(Set(report.items.map(\.name)) == ["com.vendor.Editor", "com.vendor.Editor.plist", "editor"])
        #expect(report.items.allSatisfy { !$0.canRemove && !$0.chosenByDefault })
        #expect(await model.leftovers(for: app) == nil)
        let verifiedLater = home.model()
        if case .refused = await verifiedLater.reset(app, leftovers: report.items) {} else { Issue.record("Read-only discovery must not turn into a removal request") }
        if case .refused = await verifiedLater.uninstall(app, leftovers: report.items) {} else { Issue.record("Read-only discovery must not recycle the app or its data") }
        #expect(home.exists("Applications/Editor.app") && home.exists("Library/Caches/com.vendor.Editor/c") && home.exists(".config/editor/settings.json"))
    }

    @Test func canonicalTemporaryHomeDoesNotInventAnotherInstalledCopy() async throws {
        let home = try Home()
        let physical = try #require(realpath(home.path, nil))
        defer { free(physical) }
        let path = String(cString: physical)
        let model = home.model(homePath: path)
        let app = try #require(AppFinder.metadata(path + "/Applications/Editor.app"))
        let report = try #require(await model.leftoverReport(for: app))
        #expect(report.ownershipVerified && report.items.count == 2)
        #expect(report.items.contains { $0.place == "Caches" && $0.chosenByDefault })
    }

    @Test func explicitManualReviewCanResetUnverifiedDataAndUndoIt() async throws {
        let home = try Home()
        let model = home.model(identityReaders: .init(groups: { _ in nil }))
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let report = try #require(await model.leftoverReport(for: app))
        let review = try #require(report.manualReview)
        let preferences = try #require(report.items.first { $0.place == "Preferences" })
        #expect(!preferences.canRemove && !preferences.chosenByDefault)
        #expect(review.includes(preferences.path))
        if case .refused = await model.reset(app, leftovers: [preferences]) {} else { Issue.record("Manual review is required") }
        #expect(await model.reset(app, leftovers: [preferences], manualReview: review) == .done)
        #expect(home.exists("Applications/Editor.app") && home.exists("Library/Caches/com.vendor.Editor/c"))
        #expect(!home.exists("Library/Preferences/com.vendor.Editor.plist"))
        model.undoUninstall()
        await model.undoJob?.value
        #expect(home.exists("Library/Preferences/com.vendor.Editor.plist"))
    }

    @Test func manualUninstallMovesOnlyExplicitlyChosenUnverifiedFiles() async throws {
        let home = try Home()
        let model = home.model(copies: nil)
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let report = try #require(await model.leftoverReport(for: app))
        let cache = try #require(report.items.first { $0.place == "Caches" })
        let review = try #require(report.manualReview)
        #expect(await model.uninstall(app, leftovers: [cache], manualReview: review) == .done)
        #expect(!home.exists("Applications/Editor.app") && !home.exists("Library/Caches/com.vendor.Editor"))
        #expect(home.exists("Library/Preferences/com.vendor.Editor.plist"))
        model.undoUninstall()
        await model.undoJob?.value
        #expect(home.exists("Applications/Editor.app") && home.exists("Library/Caches/com.vendor.Editor/c"))
    }

    @Test func aGuessedLegacyGroupCanBeReviewedWithoutClaimingVerifiedOwnership() async throws {
        let home = try Home()
        let group = "ABCDE12345.com.vendor.EditorLegacy"
        try home.write("Library/Group Containers/" + group + "/database")
        let model = home.model(identityReaders: .init(groups: { _ in nil }))
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let report = try #require(await model.leftoverReport(for: app))
        let leftover = try #require(report.items.first { $0.name == group })
        let review = try #require(report.manualReview)
        #expect(!report.ownershipVerified && !leftover.canRemove && !leftover.chosenByDefault)
        #expect(await model.reset(app, leftovers: [leftover], manualReview: review) == .done)
        #expect(!home.exists("Library/Group Containers/" + group))
        #expect(home.exists("Applications/Editor.app"))
    }

    @Test func knownSharedGroupsCannotBeOverriddenByManualReview() async throws {
        let home = try Home()
        try home.addViewer()
        let group = "ABCDE12345.com.vendor.EditorLegacy"
        try home.write("Library/Group Containers/" + group + "/database")
        let model = home.model(identityReaders: .init(groups: { $0.hasSuffix("Viewer.app") ? [group] : nil }))
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let report = try #require(await model.leftoverReport(for: app))
        let review = try #require(report.manualReview)
        let path = home.path + "/Library/Group Containers/" + group
        #expect(!review.includes(path))
        var forged = Leftover(path: path, bytes: 1, place: "Group Containers")
        forged.evidence = .unverified
        if case .refused = await model.reset(app, leftovers: [forged], manualReview: review) {} else { Issue.record("Known shared ownership must stay blocked") }
        #expect(home.exists("Library/Group Containers/" + group + "/database"))
    }

    @Test func aNewGroupOwnerWhileQueuedBlocksManualUninstallBeforeTheAppMoves() async throws {
        let home = try Home()
        let group = "ABCDE12345.com.vendor.EditorLegacy"
        try home.write("Library/Group Containers/" + group + "/database")
        let model = home.model(identityReaders: .init(groups: { $0.hasSuffix("Viewer.app") ? [group] : nil }))
        model.jobs = TrashJobs()
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let report = try #require(await model.leftoverReport(for: app))
        let leftover = try #require(report.items.first { $0.name == group })
        let review = try #require(report.manualReview)
        let held = await model.jobs.begin(.moveToTrash)
        defer { model.jobs.end(held) }
        let pending = Task { await model.uninstall(app, leftovers: [leftover], manualReview: review) }
        for _ in 0..<1_000 where model.jobs.waiting == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(model.jobs.waiting == 1)
        try home.addViewer()
        model.jobs.end(held)
        if case .refused = await pending.value {} else { Issue.record("A fresh competing claim must block manual removal") }
        #expect(home.exists("Applications/Editor.app") && home.exists("Library/Group Containers/" + group + "/database"))
    }

    @Test(arguments: [false, true]) func replacementOrSymlinkInvalidatesManualReview(link: Bool) async throws {
        let home = try Home()
        let model = home.model(identityReaders: .init(groups: { _ in nil }))
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let report = try #require(await model.leftoverReport(for: app))
        let cache = try #require(report.items.first { $0.place == "Caches" })
        let review = try #require(report.manualReview)
        try FileManager.default.moveItem(atPath: cache.path, toPath: cache.path + "-original")
        if link {
            try FileManager.default.createSymbolicLink(atPath: cache.path, withDestinationPath: cache.path + "-original")
        } else { try home.write("Library/Caches/com.vendor.Editor/new-data") }
        if case .refused = await model.uninstall(app, leftovers: [cache], manualReview: review) {} else { Issue.record("A review cannot authorize a replacement") }
        #expect(home.exists("Applications/Editor.app") && home.exists("Library/Caches/com.vendor.Editor-original/c"))
    }

    @Test func manualReviewRespectsKeepRulesAndUnreadableProtections() async throws {
        let home = try Home()
        let model = home.model(identityReaders: .init(groups: { _ in nil }))
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let report = try #require(await model.leftoverReport(for: app))
        let cache = try #require(report.items.first { $0.place == "Caches" })
        let review = try #require(report.manualReview)
        try CleanKeepList(paths: [cache.path + "/c"]).save(to: home.protections.keepList)
        if case .failed = await model.reset(app, leftovers: [cache], manualReview: review) {} else { Issue.record("A kept child must protect its containing folder") }
        #expect(home.exists("Library/Caches/com.vendor.Editor/c"))
        try Data("broken".utf8).write(to: home.protections.keepList)
        if case .refused = await model.uninstall(app, leftovers: [cache], manualReview: review) {} else { Issue.record("Unreadable protections must stop before recycling the app") }
        #expect(home.exists("Applications/Editor.app") && home.exists("Library/Caches/com.vendor.Editor/c"))
    }

    @Test func manualReviewNeverAuthorizesSystemDeletion() async throws {
        let home = try Home()
        let asked = Asked()
        let side = AppsModel.SystemSide(base: home.path + "/system", isReady: { true }, remove: { paths, id, ids in
            asked.calls.append((paths, id, ids))
            return RemovalReport()
        })
        let model = home.model(system: side, identityReaders: .init(groups: { _ in nil }))
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let report = try #require(await model.leftoverReport(for: app))
        let cache = try #require(report.items.first { $0.place == "Caches" })
        let review = try #require(report.manualReview)
        let system = SystemLeftover(path: home.path + "/system/Library/Caches/com.vendor.Editor", bytes: 1, place: "Caches", kind: .rebuildable)
        if case .refused = await model.uninstall(app, leftovers: [cache], system: [system], manualReview: review) {} else { Issue.record("Manual review cannot authorize permanent deletion") }
        #expect(asked.calls.isEmpty && home.exists("Applications/Editor.app") && home.exists("Library/Caches/com.vendor.Editor/c"))
    }

    @Test(arguments: [".ssh", "Library/Keychains", "Library", "Library/Vendor", "Applications/Editor.app"])
    func manualReviewDoesNotAcceptProtectedOrBroadLocations(relative: String) async throws {
        let home = try Home()
        try home.write(relative + "/private-data")
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        var guessed = Leftover(path: home.path + "/" + relative, bytes: 1, place: "Home")
        guessed.evidence = .unverified
        #expect(ManualLeftoverReview.capture(for: app, home: home.path, leftovers: [guessed], installed: [app], identity: .init()) == nil)
        #expect(home.exists(relative + "/private-data"))
    }

    @Test func anotherCopyInstalledWhileQueuedBlocksManualRemoval() async throws {
        let home = try Home()
        let model = home.model(identityReaders: .init(groups: { _ in nil }))
        model.jobs = TrashJobs()
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let report = try #require(await model.leftoverReport(for: app))
        let cache = try #require(report.items.first { $0.place == "Caches" })
        let review = try #require(report.manualReview)
        let held = await model.jobs.begin(.moveToTrash)
        defer { model.jobs.end(held) }
        let pending = Task { await model.uninstall(app, leftovers: [cache], manualReview: review) }
        for _ in 0..<1_000 where model.jobs.waiting == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(model.jobs.waiting == 1)
        try FileManager.default.copyItem(atPath: app.path, toPath: home.path + "/Applications/Editor QA.app")
        model.jobs.end(held)
        if case .refused = await pending.value {} else { Issue.record("A newly installed copy still owns its data") }
        #expect(home.exists("Applications/Editor.app") && home.exists("Applications/Editor QA.app") && home.exists("Library/Caches/com.vendor.Editor/c"))
    }

    @Test func aRemovedAppCanSupplyAManualReviewWithoutBeingMovedAgain() async throws {
        let home = try Home()
        let evidence = home.url.appending(path: ".Trash")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: home.url.appending(path: "Applications/Editor.app"), to: evidence.appending(path: "Editor.app"))
        let removed = try #require(RemovedApp.read(path: evidence.appending(path: "Editor.app").path, home: home.path))
        let model = home.model(identityReaders: .init(groups: { _ in nil }))
        let report = try #require(await model.leftoverReport(for: removed))
        let review = try #require(report.manualReview)
        let cache = try #require(report.items.first { $0.place == "Caches" })
        #expect(await model.cleanRemovedApp(removed, leftovers: [cache], manualReview: review) == .done)
        #expect(removed.isCurrent(home: home.path) && !home.exists("Library/Caches/com.vendor.Editor"))
        #expect(home.exists("Library/Preferences/com.vendor.Editor.plist"))
        model.undoUninstall()
        await model.undoJob?.value
        #expect(home.exists("Library/Caches/com.vendor.Editor/c") && removed.isCurrent(home: home.path))
    }

    @Test func knownCopiesOutsideTheScanRootsStillProtectDataWhenDiscoveryIsPartial() async throws {
        let home = try Home()
        let model = home.model(copies: nil)
        model.jobs = TrashJobs()
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        let report = try #require(await model.leftoverReport(for: app))
        let cache = try #require(report.items.first { $0.place == "Caches" })
        let review = try #require(report.manualReview)
        try FileManager.default.createDirectory(atPath: home.path + "/build", withIntermediateDirectories: true)
        let second = home.path + "/build/Editor.app"
        try FileManager.default.copyItem(atPath: app.path, toPath: second)
        let held = await model.jobs.begin(.moveToTrash)
        defer { model.jobs.end(held) }
        let pending = Task { await model.uninstall(app, leftovers: [cache], manualReview: review) }
        for _ in 0..<1_000 where model.jobs.waiting == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(model.jobs.waiting == 1)
        model.rememberOtherCopies([try #require(AppFinder.metadata(second))])
        model.jobs.end(held)
        if case .refused = await pending.value {} else { Issue.record("Known copies cannot disappear from a partial owner inventory") }
        #expect(home.exists("Applications/Editor.app") && home.exists("Library/Caches/com.vendor.Editor/c"))
    }

    @Test func positiveCopyLookupSurvivesAnUnrelatedMetadataFailure() async throws {
        let home = try Home()
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        try FileManager.default.createDirectory(atPath: home.path + "/build", withIntermediateDirectories: true)
        let second = home.path + "/build/Editor.app"
        try FileManager.default.copyItem(atPath: app.path, toPath: second)
        try home.write("Applications/Unknown.app/Contents/Info.plist")
        let model = home.model(copies: [second])
        let report = try #require(await model.leftoverReport(for: app))
        #expect(!report.ownershipVerified && report.items.isEmpty && report.manualReview == nil)
        #expect(home.exists("Library/Caches/com.vendor.Editor/c"))
    }

    @Test func cancelledManualReviewDoesNotPublishAPartialApproval() async throws {
        let home = try Home()
        let app = try #require(AppFinder.metadata(home.path + "/Applications/Editor.app"))
        var cache = Leftover(path: home.path + "/Library/Caches/com.vendor.Editor", bytes: 1, place: "Caches")
        cache.evidence = .unverified
        let polls = Mutex(0)
        let review = ManualLeftoverReview.capture(for: app, home: home.path, leftovers: [cache], installed: [app], identity: .init(), stop: {
            polls.withLock { $0 += 1; return $0 > 1 }
        })
        #expect(review == nil && polls.withLock { $0 } >= 2)
        #expect(home.exists("Library/Caches/com.vendor.Editor/c"))
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
