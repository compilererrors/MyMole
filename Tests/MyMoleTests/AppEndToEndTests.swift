#if DEBUG
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import PrivilegedKit
import StorageKit
import Synchronization
import SystemKit
import Testing
import UniformTypeIdentifiers
@testable import MyMole

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MYMOLE_E2E"] == "1"))
struct AppEndToEndTests {
    @Test func multiGigabyteSparseFileMovesAndRestoresWithoutAllocatingItsContents() async throws {
        let f = try EndToEndFixture()
        let prefix = Data(repeating: 37, count: 8_192)
        let path = try f.file("Workspace/Synthetic/large.bin", data: prefix)
        let length: UInt64 = 4 * 1_024 * 1_024 * 1_024
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try writer.truncate(atOffset: 1_048_576)
        var probe = stat()
        try #require(lstat(path, &probe) == 0 && probe.st_blocks * 512 < 65_536,
                     "Verify sparse-file support on a small owned probe before extending it")
        try writer.truncate(atOffset: length)
        try writer.close()
        var original = stat()
        try #require(lstat(path, &original) == 0 && original.st_size == Int64(length))
        try #require(original.st_blocks * 512 < 1_048_576, "The owned fixture must remain sparse and cannot fill the disk")
        let model = StorageModel()
        model.snapshotBase = f.root.appending(path: "snapshots")
        model.protections = f.protections
        model.logURL = f.log
        model.trashBackend = f.backend
        model.jobs = f.jobs
        model.scanBudget = ScanBudget(slots: 1)
        model.scan(path: f.home)
        await model.scanJob?.value
        model.show(folder: f.home + "/Workspace/Synthetic")
        await model.chooseAllContents()
        try #require(model.marked.keys.contains(path))
        model.trashMarked()
        await model.trashJob?.value
        #expect(!f.exists(path) && model.canUndo)
        model.undoTrash()
        try await f.wait { !model.trashing && f.exists(path) }
        await model.scanJob?.value
        var restored = stat()
        try #require(lstat(path, &restored) == 0)
        #expect(restored.st_dev == original.st_dev && restored.st_ino == original.st_ino)
        #expect(restored.st_size == original.st_size && restored.st_blocks == original.st_blocks)
        let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? reader.close() }
        #expect(try reader.read(upToCount: prefix.count) == prefix)
        try reader.seek(toOffset: length - UInt64(prefix.count))
        #expect(try reader.read(upToCount: prefix.count) == Data(repeating: 0, count: prefix.count))
    }
    @Test func diskMapChecksAllMovesRealFixtureBytesRecordsHistoryAndRestoresExactly() async throws {
        let f = try EndToEndFixture()
        _ = try f.file("Workspace/Synthetic/.build/large.bin", data: Data(repeating: 17, count: 2_000_000))
        _ = try f.file("Workspace/Synthetic/.build/small.txt", data: Data("small".utf8))
        _ = try f.file("Workspace/Synthetic/.build/.hidden", data: Data("hidden".utf8))
        _ = try f.file("Documents/keep.txt", data: Data("never chosen".utf8))
        let before = try f.contents()
        let model = StorageModel()
        model.snapshotBase = f.root.appending(path: "snapshots")
        model.protections = f.protections
        model.logURL = f.log
        model.trashBackend = f.backend
        model.jobs = f.jobs
        model.scanBudget = ScanBudget(slots: 1)
        model.scan(path: f.home)
        await model.scanJob?.value
        model.show(folder: f.home + "/Workspace/Synthetic/.build")
        await model.chooseAllContents()
        #expect(model.marked.count == 3 && !model.marked.keys.contains(f.home + "/Documents/keep.txt"))
        model.beginTrashReview()
        #expect(model.showReview && model.canTrash)
        #expect(try f.contents() == before)
        model.showReview = false
        model.trashMarked()
        await model.trashJob?.value
        await model.scanJob?.value
        #expect(model.canUndo && model.marked.isEmpty && f.exists(f.home + "/Workspace/Synthetic/.build"))
        #expect(try f.contents().count == 1)
        CleanupLog.flush()
        #expect(CleanupLog.load(from: f.log).first?.items == 3)
        model.undoTrash()
        try await f.wait { !model.trashing }
        await model.scanJob?.value
        let afterUndo = try f.contents()
        #expect(afterUndo == before)
    }

    @Test func deepCleanRespectsKeepAcrossProjectsAndInstallersRoundTrip() async throws {
        let f = try EndToEndFixture()
        let kept = try f.file("Library/Caches/com.example.Kept/keep.bin")
        let disposable = try f.file("Library/Caches/com.example.Disposable/cache.bin")
        _ = try f.file("Documents/source.txt", data: Data("source".utf8))
        let installer = try f.file("Downloads/Synthetic.pkg")
        let before = try f.contents()
        var rules = ProjectRules()
        rules.keepPaths = [kept]
        try ProjectStore.saveRules(rules, base: f.protections.projectBase)
        let clean = DeepCleanModel(home: f.home, base: f.root.appending(path: "clean"), keepURL: f.protections.keepList,
            logURL: f.log, runningApps: { [] }, runningTools: { [] }, trash: f.backend, projectRules: f.protections.projectBase, quietFor: 0)
        clean.jobs = f.jobs
        clean.scan()
        await clean.scanJob?.value
        clean.chosen = [f.home + "/Library/Caches/com.example.Kept", f.home + "/Library/Caches/com.example.Disposable"]
        clean.trashChosen()
        try await f.wait { !clean.trashing }
        #expect(f.exists(kept) && !f.exists(disposable) && f.exists(installer))
        clean.undoTrash()
        await clean.undoJob?.value
        #expect(try f.contents() == before)
        let installers = InstallersModel(locations: [.init(path: f.home + "/Downloads", depth: 1)],
            base: f.root.appending(path: "installers"), logURL: f.log, trash: f.backend)
        installers.protections = f.protections
        installers.jobs = f.jobs
        installers.scan()
        await installers.scanJob?.value
        #expect(installers.files.map(\.path) == [installer])
        installers.chosen = [installer]
        installers.trashChosen()
        await installers.trashJob?.value
        #expect(!f.exists(installer) && f.exists(kept))
        installers.undoTrash()
        await installers.trashJob?.value
        #expect(try f.contents() == before)
    }

    @Test func changedKeepRulesAndAPartialMoveFailurePreserveUncheckedBytesAndUndoOnlySuccesses() async throws {
        let f = try EndToEndFixture()
        let removable = try f.file("Documents/removable.bin")
        let kept = try f.file("Documents/newly-kept.bin", data: Data("protected after review".utf8))
        let denied = try f.file("Documents/denied.bin", data: Data("synthetic access failure".utf8))
        let before = try f.contents()
        let model = StorageModel()
        model.snapshotBase = f.root.appending(path: "snapshots")
        model.protections = f.protections
        model.logURL = f.log
        model.jobs = f.jobs
        model.scanBudget = ScanBudget(slots: 1)
        model.trashBackend = TrashBackend { path in
            if path == denied { return (nil, "Synthetic access failure") }
            return f.backend.moveOne(path)
        }
        model.scan(path: f.home)
        await model.scanJob?.value
        model.show(folder: f.home + "/Documents")
        await model.chooseAllContents()
        model.beginTrashReview()
        #expect(model.marked.count == 3 && model.canTrash)
        try CleanKeepList(paths: [kept]).save(to: f.protections.keepList)
        model.showReview = false
        model.trashMarked()
        await model.trashJob?.value
        await model.scanJob?.value
        #expect(!f.exists(removable) && f.exists(kept) && f.exists(denied) && model.canUndo)
        CleanupLog.flush()
        #expect(CleanupLog.load(from: f.log).first?.items == 1)
        model.undoTrash()
        try await f.wait { !model.trashing }
        await model.scanJob?.value
        #expect(try f.contents() == before)
    }

    @Test func appUninstallLeavesUncheckedDataThenOrphanCleanupAndUndoPreserveEverything() async throws {
        let f = try EndToEndFixture()
        let path = try f.app()
        let cache = try f.file("Library/Caches/com.example.SyntheticEditor/cache.bin")
        let data = try f.file("Library/Application Support/com.example.SyntheticEditor/document.bin")
        let before = try f.contents()
        let model = AppsModel(home: f.home, folders: [f.home + "/Applications"], base: f.root.appending(path: "apps"), logURL: f.log,
            recycle: { paths in Trasher.moveToTrash(paths, through: .init(still: { _ in true }, protections: TrashGate.keepsNothing), backend: f.backend) },
            isRunning: { _ in false }, otherCopies: { _ in [] },
            system: .init(base: f.home + "/System", isReady: { false }, remove: { _, _, _ in .init() }),
            trash: f.backend, protections: f.protections, imageOf: { _ in nil }, eject: { _ in "Disabled in E2E" },
            identityReaders: .init(groups: { _ in [] }), runtimeRoots: [])
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        let leftovers = try #require(await model.leftovers(for: app))
        #expect(leftovers.contains { $0.path == (cache as NSString).deletingLastPathComponent })
        let result = await model.uninstall(app, leftovers: [])
        #expect(result == .done && !f.exists(path) && f.exists(cache) && f.exists(data))
        let orphans = OrphansModel(home: f.home, logURL: f.log, trash: f.backend, known: { _ in false }, running: { [] }, installedNow: { [] })
        orphans.protections = f.protections
        orphans.jobs = f.jobs
        orphans.load()
        await orphans.job?.value
        #expect(orphans.items.contains { $0.path == (data as NSString).deletingLastPathComponent })
        #expect(!orphans.chosen.contains((data as NSString).deletingLastPathComponent))
        orphans.trashChosen()
        await orphans.job?.value
        #expect(!f.exists(cache) && f.exists(data))
        orphans.undoTrash()
        await orphans.job?.value
        model.undoUninstall()
        await model.undoJob?.value
        try await f.wait { f.exists(path) }
        #expect(try f.contents() == before)
    }

    @Test func duplicateContentComparisonChecksAllButAlwaysKeepsACopyAndUndoRestoresBytes() async throws {
        let f = try EndToEndFixture()
        for name in ["one.bin", "two.bin", "three.bin"] { _ = try f.file("Documents/" + name, data: Data(repeating: 19, count: 40_000)) }
        _ = try f.file("Documents/different.bin", data: Data(repeating: 20, count: 40_000))
        let before = try f.contents()
        let model = DuplicatesModel(home: f.home, roots: [f.home + "/Documents"], minimum: 10_000, logURL: f.log,
            trash: f.backend, scanBudget: ScanBudget(slots: 1))
        model.jobs = f.jobs
        model.protections = f.protections
        model.scan()
        await model.scanJob?.value
        #expect(model.groups.count == 1 && model.chosen.isEmpty)
        model.chooseAll(keeping: .oldest)
        #expect(model.chosen.count == 2)
        #expect(try f.contents() == before)
        model.trashChosen()
        await model.trashJob?.value
        #expect(try f.contents().count == 2)
        model.undoTrash()
        await model.trashJob?.value
        await model.scanJob?.value
        #expect(try f.contents() == before)
    }

    @Test func startupPlistDiscoveryMovesOnlyTheOwnedAgentAndRestoresIt() async throws {
        let f = try EndToEndFixture()
        let agent = try f.plist("Library/LaunchAgents/com.example.synthetic.plist", ["Label": "com.example.synthetic", "Program": f.home + "/missing-program"])
        _ = try f.plist("System/Library/LaunchDaemons/com.example.system.plist", ["Label": "com.example.system", "Program": f.home + "/missing-program"])
        let before = try f.contents()
        let model = StartupModel(home: f.home, root: f.home + "/System", logURL: f.log, trash: f.backend)
        model.jobs = f.jobs
        model.protections = f.protections
        model.readLive = { nil }
        model.load()
        await model.job?.value
        #expect(model.items.count == 2)
        model.chooseLeftovers()
        #expect(model.chosen == [agent])
        model.trashChosen()
        await model.job?.value
        #expect(!f.exists(agent) && model.items.count == 1)
        model.undoTrash()
        await model.job?.value
        #expect(try f.contents() == before)
    }

    @Test func realProjectDiscoveryCleansBuildArtifactsAndPreservesSource() async throws {
        let f = try EndToEndFixture()
        _ = try f.file("Workspace/Synthetic/Package.swift", data: Data("// swift-tools-version: 6.2\n".utf8))
        let artifact = try f.file("Workspace/Synthetic/.build/output.o")
        let source = try f.file("Workspace/Synthetic/Sources/main.swift", data: Data("print(42)".utf8))
        let before = try f.contents()
        let found = await Task.detached {
            ProjectScanner.list(roots: [f.home + "/Workspace"], home: f.home, workers: 1)
        }.value
        #expect(found.footprints.count == 1 && found.unreadable.isEmpty)
        let model = ProjectsModel(footprints: found.footprints, base: f.protections.projectBase,
            defaults: testDefaults(in: f.root), logURL: f.log, keepList: f.protections.keepList)
        model.jobs = f.jobs
        model.trashBackend = f.backend
        let build = try #require(found.footprints.flatMap(\.items).first { $0.category == .build }?.entries.first?.path)
        model.chosen = [build]
        #expect(!model.chosenEntries.isEmpty && model.trashBlocker == nil)
        model.trashChosen()
        try await f.wait { !model.trashing }
        #expect(!f.exists(artifact) && f.exists(source) && model.canUndo)
        model.undoTrash()
        try await f.wait { !model.trashing }
        #expect(try f.contents() == before)
    }

    @Test func realImageDecodingAndSimilarityRetainTheBestAndRestoreTheSmallerCopy() async throws {
        let f = try EndToEndFixture()
        func image(_ relative: String, width: Int, type: UTType) throws -> String {
            let path = try f.file(relative, data: Data())
            let context = try #require(CGContext(data: nil, width: width, height: width * 3 / 4, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            for x in 0..<width {
                let value = Double(x) / Double(width)
                context.setFillColor(red: value, green: 1 - value, blue: 0.4, alpha: 1)
                context.fill(CGRect(x: x, y: 0, width: 1, height: width * 3 / 4))
            }
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: width / 3, y: width * 3 / 8, width: width / 3, height: width * 3 / 16))
            let destination = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(destination))
            return path
        }
        let best = try image("Pictures/best.png", width: 900, type: .png)
        let smaller = try image("Downloads/smaller.jpg", width: 300, type: .jpeg)
        let before = try f.contents()
        let model = SimilarModel(home: f.home, roots: [f.home + "/Pictures", f.home + "/Downloads"], minimum: 1,
            logURL: f.log, trash: f.backend, cacheURL: f.root.appending(path: "fingerprints.json"))
        model.jobs = f.jobs
        model.protections = f.protections
        model.scan()
        await model.scanJob?.value
        #expect(model.groups.count == 1 && model.chosen.isEmpty)
        model.chooseAllButBest()
        #expect(model.chosen == [smaller])
        model.trashChosen()
        await model.trashJob?.value
        #expect(f.exists(best) && !f.exists(smaller))
        model.undoTrash()
        await model.trashJob?.value
        await model.scanJob?.value
        #expect(try f.contents() == before)
    }

    @Test func irreversibleTrashConfirmationDeletesOnlyTheSyntheticItemsItListed() async throws {
        let f = try EndToEndFixture()
        let original = try f.file("Documents/original.bin")
        let moved = try #require(f.backend.moveOne(original).trashed)
        let model = TrashModel(folder: f.scope.trash, jobs: f.jobs, logURL: f.log)
        await model.askToEmpty()
        let listing = try #require(model.confirming)
        #expect(listing.count == 1 && f.exists(moved.path))
        let later = try f.file("Documents/later.bin", data: Data("later".utf8))
        let laterMove = try #require(f.backend.moveOne(later).trashed)
        await model.empty(listing)
        #expect(!f.exists(moved.path) && f.exists(laterMove.path))
        CleanupLog.flush()
        #expect(CleanupLog.load(from: f.log).first?.deleted == 1)
        #expect(Trasher.restore([TrashRecord(original: URL(fileURLWithPath: later), trashed: laterMove)]).isEmpty)
        #expect(try Data(contentsOf: URL(fileURLWithPath: later)) == Data("later".utf8))
    }

    @Test func systemCleanupRecordsOnlyUnkeptPathsWithoutRunningThePrivilegedTool() async throws {
        let f = try EndToEndFixture()
        let disposable = try f.file("System/Library/Caches/com.example.disposable/blob")
        let kept = try f.file("System/Library/Caches/com.example.kept/blob")
        let before = try f.contents()
        var removals: [[String]] = []
        let system = SystemCleanModel(privileged: PrivilegedClient(toolPath: nil), logURL: f.log, keepURL: f.protections.systemKeepList,
            backend: .init(isReady: { true }, scan: { _ in .init(candidates: [
                .init(path: disposable, bytes: 8192, modified: .distantPast, safety: .safe, reason: "Synthetic cache"),
                .init(path: kept, bytes: 8192, modified: .distantPast, safety: .safe, reason: "Synthetic kept cache")]) },
                remove: { paths, _ in
                    removals.append(paths)
                    var report = RemovalReport()
                    report.removed = paths
                    return report
                }))
        system.jobs = f.jobs
        system.lookForStaging = { [] }
        system.scan()
        await system.scanJob?.value
        try CleanKeepList(paths: [kept]).save(to: f.protections.systemKeepList)
        system.removeChosen()
        await system.removeJob?.value
        #expect(removals == [[disposable]])
        #expect(try f.contents() == before)
    }

    @Test func optimizationMovesSyntheticFilesAndRecordsTheExpectedCommandsAndResults() async throws {
        let f = try EndToEndFixture()
        let state = try f.file("Library/Saved Application State/com.example.synthetic.savedState/window.bin")
        let stateFolder = (state as NSString).deletingLastPathComponent
        let broken = try f.file("Library/Preferences/com.example.broken.plist", data: Data("broken synthetic plist".utf8))
        let kept = try f.file("Library/Preferences/com.example.kept.plist", data: Data("kept synthetic plist".utf8))
        _ = try f.plist("Library/Preferences/com.example.valid.plist", ["SyntheticSetting": true])
        for path in [state, stateFolder, broken, kept] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: path)
        }
        try CleanKeepList(paths: [kept]).save(to: f.protections.keepList)
        let before = try f.contents()
        let commands = Mutex([[String]]())
        let moves = Mutex([TrashRecord]())
        let runner = CommandRunner(run: { path, arguments in commands.withLock { $0.append([path] + arguments) }; return (0, "") }, exists: { _ in true })
        let engine = MaintenanceEngine(role: .user, home: f.home, runner: runner,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }, trash: { paths, gate in
                let result = Trasher.moveToTrash(paths, through: gate, backend: f.backend)
                moves.withLock { $0.append(contentsOf: result.moved) }
                return result
            }, protections: { try f.protections.read() })
        let maintenance = MaintenanceModel(privileged: PrivilegedClient(toolPath: nil), engine: engine,
            defaults: testDefaults(in: f.root), logURL: f.log)
        maintenance.check()
        try await f.wait { maintenance.phase == .idle }
        #expect(maintenance.checkedAt != nil)
        #expect(maintenance.reports[.savedState]?.status == .willRun && maintenance.reports[.brokenPreferences]?.status == .willRun)
        #expect(try f.contents() == before)
        #if APPSTORE
        #expect(commands.withLock { $0 }.isEmpty)
        #else
        #expect(commands.withLock { $0 } == [
            ["/usr/bin/defaults", "read", "com.apple.desktopservices", "DSDontWriteNetworkStores"],
            ["/usr/bin/defaults", "read", "com.apple.desktopservices", "DSDontWriteUSBStores"]])
        #expect(maintenance.reports[.flushDNS]?.status == .needsHelper)
        #endif
        commands.withLock { $0.removeAll() }
        maintenance.run()
        try await f.wait { maintenance.phase == .idle }
        #expect(!maintenance.privileged.isAvailable && maintenance.lastRun != nil)
        #expect(maintenance.reports[.savedState]?.status == .done)
        #expect(maintenance.reports[.brokenPreferences]?.status == .failed)
        #expect(maintenance.reports[.brokenPreferences]?.detail == "Moved 1; 1 couldn't be moved.")
        #if APPSTORE
        #expect(commands.withLock { $0 }.isEmpty)
        #else
        #expect(commands.withLock { $0 } == [["/usr/bin/qlmanage", "-r", "cache"], ["/usr/bin/qlmanage", "-r"]])
        #expect(maintenance.reports[.quickLook]?.status == .done)
        #endif
        #expect(!f.exists(stateFolder) && !f.exists(broken) && f.exists(kept))
        let records = moves.withLock { $0 }
        #expect(Set(records.map { $0.original.path }) == [stateFolder, broken])
        CleanupLog.flush()
        let history = try #require(CleanupLog.load(from: f.log).first)
        #expect(history.source == "Optimize" && history.failed == 1)
        #if APPSTORE
        #expect(history.items == 1)
        #else
        #expect(history.items == 2)
        #endif
        #expect(Trasher.restore(records).isEmpty)
        #expect(try f.contents() == before)
    }

    @Test func liveStatusAndSettingsPersistOnlySyntheticValuesAndRecoverHiddenCards() throws {
        let f = try EndToEndFixture()
        let sample = SystemSampler(readers: .synthetic, warmup: .zero).sample()
        #expect(sample.hardware.model == "Synthetic Mac" && sample.topProcesses.map(\.name) == ["Synthetic Editor", "Synthetic Player"])
        #expect(sample.memory?.total == 16 << 30 && sample.health.score > 0)
        var layout = StatusLayout()
        layout.setVisible(false, for: .cpu)
        #expect(layout.hidden.map(\.id) == [.cpu])
        var restored = StatusLayout.read(layout.saved)
        restored.showAll()
        #expect(restored.hidden.isEmpty)
        let defaults = testDefaults(in: f.root)
        let confirmations = ConfirmationSettings(defaults: defaults)
        confirmations.setAsking(false, for: .installers)
        #expect(!ConfirmationSettings(defaults: defaults).asks(.installers))
        confirmations.restore()
        #expect(ConfirmationSettings(defaults: defaults).asks(.installers))
        #expect(confirmations.asks(.uninstall, always: true) && confirmations.asks(nil))
        #expect(f.jobs.isBusy == false)
    }

    @Test func unreadableKeepRulesAndAStoppedQueueRefuseMovesWithoutChangingFixtureBytes() async throws {
        let f = try EndToEndFixture()
        let path = try f.file("Downloads/Synthetic.pkg")
        let before = try f.contents()
        let model = InstallersModel(locations: [.init(path: f.home + "/Downloads", depth: 1)],
            base: f.root.appending(path: "installers"), logURL: f.log, trash: f.backend)
        model.protections = f.protections
        model.jobs = f.jobs
        model.scan()
        await model.scanJob?.value
        try FileManager.default.createDirectory(at: f.protections.keepList.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken protection list".utf8).write(to: f.protections.keepList)
        model.chosen = [path]
        model.trashChosen()
        await model.trashJob?.value
        #expect(try f.contents() == before)
        try CleanKeepList().save(to: f.protections.keepList)
        model.chosen = [path]
        let first = await f.jobs.begin(.moveToTrash)
        model.trashChosen()
        try await f.wait { f.jobs.waiting == 1 }
        f.jobs.stop()
        f.jobs.end(first)
        await model.trashJob?.value
        #expect(!f.jobs.isBusy && !model.canUndo)
        #expect(try f.contents() == before)
    }

    @Test func smartScanRunsActualScannersAndFindsDuplicatesAfterCheapStages() async throws {
        let f = try EndToEndFixture()
        _ = try f.file("Documents/one.bin", data: Data(repeating: 41, count: 40_000))
        _ = try f.file("Downloads/two.bin", data: Data(repeating: 41, count: 40_000))
        _ = try f.file("Downloads/Synthetic.dmg")
        _ = try f.file("Library/Caches/com.example.cache/blob")
        let before = try f.contents()
        let clean = DeepCleanModel(home: f.home, base: f.root.appending(path: "clean"), keepURL: f.protections.keepList,
            logURL: f.log, runningApps: { [] }, runningTools: { [] }, trash: f.backend, projectRules: f.protections.projectBase, quietFor: 0)
        let installers = InstallersModel(locations: [.init(path: f.home + "/Downloads", depth: 1)], base: f.root.appending(path: "installers"), logURL: f.log, trash: f.backend)
        installers.protections = f.protections
        let duplicates = DuplicatesModel(home: f.home, roots: [f.home + "/Documents", f.home + "/Downloads"], minimum: 10_000,
            logURL: f.log, trash: f.backend, scanBudget: ScanBudget(slots: 1))
        duplicates.protections = f.protections
        var order: [Pane] = []
        let jobs: [Pane: SmartScanPipeline.Job] = [
            .clean: .init(start: { clean.scan() }, wait: { await clean.scanJob?.value }),
            .installer: .init(start: { installers.scan() }, wait: { await installers.scanJob?.value }),
            .duplicates: .init(start: {
                #expect(clean.scannedAt != nil && installers.scannedAt != nil)
                duplicates.scan()
            }, wait: { await duplicates.scanJob?.value })]
        await SmartScanPipeline(jobs: jobs).run(together: true, allowed: { true }, starting: { order.append($0) })
        #expect(order.last == .duplicates && duplicates.groups.count == 1 && duplicates.chosen.isEmpty)
        #expect(!clean.candidates.isEmpty && installers.files.count == 1)
        #expect(try f.contents() == before)
    }

    @Test func exportedScansRemainReadOnlyAndCannotAuthorizeRemoval() async throws {
        let f = try EndToEndFixture()
        _ = try f.file("Documents/large.bin", data: Data(repeating: 23, count: 2_000_000))
        let before = try f.contents()
        let root = await Task.detached { StorageScanner.scan(path: f.home, workers: 1).root }.value
        let file = f.root.appending(path: "synthetic.mymolescan")
        try ScanExport(of: root).data().write(to: file)
        let model = StorageModel()
        model.snapshotBase = f.root.appending(path: "snapshots")
        model.protections = f.protections
        model.logURL = f.log
        model.trashBackend = f.backend
        model.jobs = f.jobs
        await model.open(exported: file)
        #expect(model.opened != nil && model.root?.fileCount == 1)
        model.mark([.init(path: f.home + "/Documents/large.bin", name: "large.bin", size: 2_000_000, isFolder: false)])
        model.trashMarked()
        #expect(!model.canTrash && !f.jobs.isBusy && model.marked.isEmpty)
        #expect(try f.contents() == before)
    }

    @Test func permissionChangesRefreshWithoutARealSettingsPanelOrOneTimeCachedGrant() async throws {
        let f = try EndToEndFixture()
        let state = Mutex(FullDiskAccess.State.denied)
        let monitor = DiskAccessMonitor(probe: { state.withLock { $0 } })
        var changes = 0
        monitor.didChange = { changes += 1 }
        await monitor.request(scope: 1)?.value
        #expect(monitor.state == .denied && monitor.hasResult)
        state.withLock { $0 = .granted }
        await monitor.request(scope: 1)?.value
        #expect(monitor.state == .granted && changes == 2)
        await monitor.request(scope: nil)?.value
        #expect(!monitor.hasResult && monitor.state == .unknown)
        #if APPSTORE
        var selected: URL?
        let bookmarks = FolderAccess.Bookmarks(resolve: { data in (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false) },
            startAccessing: { _ in true }, stopAccessing: { _ in }, make: { Data($0.path.utf8) }, choose: { _ in selected })
        let defaults = testDefaults(in: f.root)
        let access = FolderAccess(defaults: defaults, bookmarks: bookmarks)
        #expect(access.needsHome)
        selected = URL(fileURLWithPath: FolderAccess.Place.home.path)
        access.request(.home)
        #expect(access.has(.home) && FolderAccess(defaults: defaults, bookmarks: bookmarks).has(.home))
        access.revoke(.home)
        #expect(access.needsHome)
        #else
        #expect(!FolderAccess(defaults: testDefaults(in: f.root)).needsHome)
        #endif
    }

    @Test func selfRemovalUsesOnlyAFakeOwnBundleAndInjectedShutdownCallbacks() async throws {
        let f = try EndToEndFixture()
        let own = try f.app()
        let cache = try f.file("Library/Caches/com.example.SyntheticEditor/cache.bin")
        let preferences = try f.file("Library/Preferences/com.example.SyntheticEditor.plist")
        let before = try f.contents()
        var events: [String] = []
        let apps = AppsModel(home: f.home, folders: [f.home + "/Applications"], base: f.root.appending(path: "apps"), logURL: f.log,
            recycle: { paths in
                events.append("move")
                return Trasher.moveToTrash(paths, through: .init(still: { _ in true }, protections: TrashGate.keepsNothing), backend: f.backend)
            }, isRunning: { _ in true }, otherCopies: { _ in [] },
            system: .init(base: f.home + "/System", isReady: { false }, remove: { _, _, _ in .init() }), trash: f.backend,
            protections: f.protections, imageOf: { _ in nil }, eject: { _ in "Disabled in E2E" }, ownAppPath: own,
            ownAppID: "com.example.SyntheticEditor", identityReaders: .init(groups: { _ in [] }), runtimeRoots: [])
        apps.jobs = f.jobs
        let model = SelfRemovalModel(apps: apps, prepare: { events.append("prepare"); return nil },
            resume: { events.append("resume") }, quit: { events.append("quit callback") })
        await model.load()
        #expect(model.canRemove)
        await model.remove()
        #expect(model.removed && events == ["prepare", "move", "quit callback"])
        #expect(!f.exists(own) && !f.exists(cache) && f.exists(preferences))
        apps.undoUninstall()
        await apps.undoJob?.value
        #expect(try f.contents() == before)
    }

    @Test func appCopiesFindBuildsAndDeclaredIntegrationsWithoutRegisteringOrLaunchingThem() async throws {
        let f = try EndToEndFixture()
        let installed = try f.app()
        let copy = f.home + "/Workspace/Synthetic/build/Debug/Synthetic Editor QA.app"
        try FileManager.default.createDirectory(atPath: (copy as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: installed, toPath: copy)
        _ = try f.plist("Workspace/Synthetic/build/Debug/Synthetic Editor QA.app/Contents/Info.plist", [
            "CFBundleIdentifier": "com.example.SyntheticEditor", "CFBundleName": "Synthetic Editor QA",
            "CFBundleExecutable": "SyntheticEditor", "CFBundleVersion": "2", "CFBundlePackageType": "APPL",
            "NSServices": [["NSMenuItem": ["default": "Synthetic/Edit Selection"], "NSMessage": "editSelection"]],
            "CFBundleDocumentTypes": [["CFBundleTypeName": "Synthetic Document", "CFBundleTypeRole": "Editor", "CFBundleTypeExtensions": ["synthetic"]]],
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["synthetic-editor"]]]
        ])
        _ = try f.plist("Workspace/Synthetic/build/Debug/Synthetic Editor QA.app/Contents/PlugIns/SyntheticFinder.appex/Contents/Info.plist", [
            "CFBundleIdentifier": "com.example.SyntheticEditor.finder", "CFBundleName": "Synthetic Finder",
            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.FinderSync"]
        ])
        let before = try f.contents()
        let commands = Mutex([[String]]())
        let runner = CommandRunner(run: { path, arguments in commands.withLock { $0.append([path] + arguments) }; return (0, installed + "\0") }, exists: { _ in true })
        let missing = f.home + "/Applications/Missing Synthetic.app"
        let model = AppCopiesModel(folders: [f.home + "/Applications"], runner: runner, registered: { _ in [installed, missing] }, budget: ScanBudget(slots: 1))
        model.load()
        await model.job?.value
        #expect(model.report.copies.count == 1 && model.report.missingRegistered == [missing])
        model.addFolder(f.home + "/Workspace")
        await model.job?.value
        #expect(model.counts["com.example.syntheticeditor"] == 2 && !model.loading)
        let development = try #require(model.report.copies.first { $0.app.path == (copy as NSString).standardizingPath })
        #expect(development.hint == .buildFolder && development.app.sizePending)
        #expect(Set(development.integrations.items.map(\.kind)) == [.service, .documents, .urls, .finder])
        #expect(development.integrations.items.contains { $0.name == "Edit Selection" })
        #expect(commands.withLock { $0 }.count == 2)
        #expect(try f.contents() == before)
    }
}
#endif
