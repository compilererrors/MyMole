import Foundation
import StorageKit
import Testing

@testable import MyMole

/// What Deep Clean keeps stays in Projects too, on synthetic files of the
/// test's own. (The other way round is in DeepCleanModelTests.)
@MainActor
@Suite struct ProjectsKeptInDeepCleanTests {
    private final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "cross-keep-\(UUID().uuidString)")
        var store: URL { root.appending(path: "store") }
        var keepList: URL { root.appending(path: "keep.json") }
        var project: String { root.appending(path: "App").path }

        deinit { try? FileManager.default.removeItem(at: root) }

        func file(_ rel: String) throws {
            let u = root.appending(path: rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 5, count: 2_000).write(to: u)
        }

        func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: root.path + "/" + rel) }

        private func item(_ name: String, _ category: FootprintCategory) -> FootprintItem {
            FootprintItem(
                id: "inside:" + name, category: category, title: name, location: project, attribution: .inside,
                entries: [FootprintEntry(path: project + "/" + name, bytes: 2_000, modified: .distantPast)])
        }

        @MainActor func model() -> ProjectsModel {
            let footprint = ProjectFootprint(
                project: DevProject(path: project, markers: ["package.json"]),
                items: [item(".build", .build), item("node_modules", .dependencies)])
            let m = ProjectsModel(
                footprints: [footprint], base: store, defaults: testDefaults(in: store), logURL: root.appending(path: "history.json"),
                keepList: keepList)
            m.trashBackend = testBin(root)
            m.jobs = TrashJobs()
            return m
        }
    }

    @Test func whatDeepCleanKeepsIsLockedAndStaysWhenItsFolderGoes() async throws {
        let box = Box()
        try box.file("App/.build/out")
        try box.file("App/node_modules/kept-pkg/x")
        try box.file("App/node_modules/other/y")
        let build = box.project + "/.build"
        let pkg = box.project + "/node_modules/kept-pkg"
        try CleanKeepList(paths: [build, pkg]).save(to: box.keepList)
        let m = box.model()
        // Shown locked and never chosen; a folder that only holds something
        // kept can still be chosen.
        #expect(m.isKeptElsewhere(build) && m.isKeptElsewhere(pkg + "/x") && !m.isKeptElsewhere(box.project + "/node_modules"))
        m.toggle(path: build)
        #expect(m.chosen.isEmpty)
        let buildItem = try #require(m.footprints.first?.items.first { $0.title == ".build" })
        #expect(m.eligible(buildItem).isEmpty)

        // Chosen anyway, as an older choice would be, with the folder that
        // holds a kept package: the kept stays, the rest goes around it.
        m.chosen = [build, box.project + "/node_modules"]
        m.trashChosen()
        while m.trashing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(box.exists("App/.build/out"))
        #expect(box.exists("App/node_modules/kept-pkg/x") && !box.exists("App/node_modules/other"))
    }

    @Test func aKeepListThatCantBeReadStopsTheMove() async throws {
        let box = Box()
        try box.file("App/.build/out")
        try Data("broken".utf8).write(to: box.keepList)
        let m = box.model()
        m.chosen = [box.project + "/.build"]
        m.trashChosen()
        #expect(!m.trashing)
        #expect(m.notice?.text == "Nothing was moved: Deep Clean's keep list couldn't be read.")
        #expect(box.exists("App/.build/out"))
    }
}
