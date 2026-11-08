import Foundation
import StorageKit
import Synchronization
import Testing

@testable import MyMole

/// Project rules and measuring again, with the model's store, preferences
/// and history in a folder of the test's own. Nothing is moved.
@MainActor
@Suite struct ProjectRulesModelTests {
    final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "rules-\(UUID().uuidString)")
        var store: URL { root.appending(path: "store") }
        var project: String { root.appending(path: "App").path }
        init() throws { try FileManager.default.createDirectory(atPath: root.path + "/App", withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }

        func footprint(_ bytes: Int64 = 100) -> ProjectFootprint {
            let item = FootprintItem(
                id: project + "#build", category: .build, title: ".build", location: project, attribution: .inside,
                entries: [FootprintEntry(path: project + "/.build", bytes: bytes, modified: .distantPast)])
            return ProjectFootprint(project: DevProject(path: project, markers: [".git"]), items: [item])
        }

        @MainActor func model() -> ProjectsModel {
            ProjectsModel(footprints: [footprint()], base: store, defaults: testDefaults(in: store), logURL: root.appending(path: "history.json"))
        }
    }

    @Test func aRuleAddedElsewhereSurvivesTheNextChange() throws {
        let box = try Box()
        let first = box.model()
        let second = box.model()
        first.keep([box.project + "/.build"], in: box.project)
        // The second window never read the first one's rule, yet keeps it.
        second.keepEverywhere(named: "vendor")
        let saved = try ProjectStore.loadRules(base: box.store)
        #expect(saved.keepPaths == [box.project + "/.build"] && saved.keepNames == ["vendor"])
        #expect(second.rules == saved)
    }

    @Test func aFileBrokenAfterLaunchIsNeverSavedOver() throws {
        let box = try Box()
        let m = box.model()
        m.keep([box.project + "/.build"], in: box.project)
        try Data("{ broken".utf8).write(to: box.store.appending(path: "rules.json"))
        m.keepEverywhere(named: "vendor")
        #expect(try Data(contentsOf: box.store.appending(path: "rules.json")) == Data("{ broken".utf8))
        #expect(m.rulesError != nil)
        // The rules in use stay as they were: the failed change didn't apply.
        #expect(m.rules.keepPaths == [box.project + "/.build"] && m.rules.keepNames.isEmpty)
    }

    @Test func onlyTheNewestMeasureOfAProjectLands() async throws {
        let box = try Box()
        let m = box.model()
        let gates = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
        let runs = Mutex(0)
        let finished = Mutex(0)
        let sizes: [Int64] = [111, 222]
        let made = sizes.map(box.footprint)
        m.measureProject = { _, _, _ in
            let n = runs.withLock { r in defer { r += 1 }; return r }
            gates[n].wait()
            defer { finished.withLock { $0 += 1 } }
            return made[n]
        }
        m.rescan(box.project)
        // The older run is the one measuring before the newer is asked for,
        // so the two are told apart by when they were asked, not by when
        // the pool happens to start them.
        while runs.withLock({ $0 }) < 1 { try await Task.sleep(for: .milliseconds(5)) }
        m.rescan(box.project)
        // The newer run finishes first, the older one after it.
        gates[1].signal()
        for _ in 0..<400 where m.footprints.first?.bytes != 222 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(m.footprints.first?.bytes == 222 && m.rescanning.isEmpty)
        gates[0].signal()
        while finished.withLock({ $0 }) < 2 { try await Task.sleep(for: .milliseconds(5)) }
        // Its result is handed to the main queue; give it every chance to land.
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(m.footprints.first?.bytes == 222)
    }
}
