import Foundation
import StorageKit
import Testing

@testable import MyMole

/// Choosing folders and files inside a project's entries, in a synthetic
/// project folder; nothing is moved.
@MainActor
@Suite struct ProjectChoiceTests {
    final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "choice-\(UUID().uuidString)").path
        init() throws {
            for f in ["App/.local/a/one.log", "App/.local/a/two.log", "App/.local/b/three.log", "App/.local/c.txt", "App/.build/x.o"] {
                let url = URL(fileURLWithPath: root + "/" + f)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 1, count: 4096).write(to: url)
            }
        }
        deinit { try? FileManager.default.removeItem(atPath: root) }
        var project: String { root + "/App" }
    }

    private func model(_ box: Box) -> (ProjectsModel, FootprintItem, FootprintItem) {
        let p = box.project
        let local = FootprintItem(
            id: p + "#local", category: .localData, title: ".local", location: p, attribution: .inside,
            entries: [FootprintEntry(path: p + "/.local", bytes: 16384, modified: .distantPast)])
        let build = FootprintItem(
            id: p + "#build", category: .build, title: ".build", location: p, attribution: .inside,
            entries: [FootprintEntry(path: p + "/.build", bytes: 4096, modified: .distantPast)])
        let source = FootprintItem(
            id: p + "#source", category: .source, title: "Source", location: p, attribution: .inside,
            entries: [FootprintEntry(path: p + "/Sources", bytes: 100, modified: .distantPast)])
        let f = ProjectFootprint(project: DevProject(path: p, markers: [".git"]), items: [local, build, source])
        let store = URL(fileURLWithPath: box.root + "/store")
        let m = ProjectsModel(footprints: [f], base: store, defaults: testDefaults(in: store), logURL: store.appending(path: "history.json"))
        return (m, local, build)
    }

    @Test func choosingInsideAnEntryChoosesOnlyThatPart() async throws {
        let box = try Box()
        let (m, local, _) = model(box)
        let a = box.project + "/.local/a"
        m.toggle(path: a)
        #expect(m.chosen == [a])
        #expect(m.state(of: a) == .on)
        #expect(m.state(of: a + "/one.log") == .on)
        #expect(m.state(of: box.project + "/.local") == .mixed)
        #expect(m.check(local) == .mixed)
        let picked = try #require(m.chosenEntries.first)
        #expect(picked.part && picked.entry.path == a && picked.project == box.project)
        // Its size is measured off the main thread and arrives.
        for _ in 0..<100 where (m.chosenEntries.first?.entry.bytes ?? 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(m.chosenBytes == 8192)
    }

    @Test func unchoosingInsideAChosenEntryKeepsTheRestChosen() throws {
        let box = try Box()
        let (m, local, _) = model(box)
        m.toggle(local)
        #expect(m.check(local) == .on)
        let one = box.project + "/.local/a/one.log"
        m.toggle(path: one)
        let l = box.project + "/.local"
        // One path is left out, however many entries surround it.
        #expect(m.chosen == [l] && m.excluded == [one])
        #expect(m.state(of: one) == .off)
        #expect(m.state(of: l + "/a/two.log") == .on && m.state(of: l + "/b") == .on)
        #expect(m.state(of: l + "/a") == .mixed)
        #expect(m.check(local) == .mixed)
        // The whole entry goes, without what's left out of it.
        let picked = try #require(m.chosenEntries.first)
        #expect(m.chosenEntries.count == 1 && picked.entry.path == l && picked.part)
        #expect(picked.entry.bytes == 16384 - 4096)
        #expect(m.excluded(inside: l) == [one])
        // Ticked again, it's back in.
        m.toggle(path: one)
        #expect(m.chosen == [l] && m.excluded.isEmpty && m.check(local) == .on)
    }

    @Test func somethingInsideALeftOutFolderCanBeChosenAgain() throws {
        let box = try Box()
        let (m, local, _) = model(box)
        let l = box.project + "/.local"
        m.toggle(local)
        m.toggle(path: l + "/a")
        m.toggle(path: l + "/a/two.log")
        #expect(m.chosen == [l, l + "/a/two.log"] && m.excluded == [l + "/a"])
        #expect(m.state(of: l + "/a/one.log") == .off && m.state(of: l + "/a/two.log") == .on)
        #expect(m.state(of: l + "/a") == .mixed)
        // Two picks that don't overlap: the folder without "a", and the file in "a".
        #expect(Set(m.chosenEntries.map(\.entry.path)) == [l, l + "/a/two.log"])
        // The entry's box chooses it whole, then nothing.
        m.toggle(local)
        #expect(m.chosen == [l] && m.excluded.isEmpty)
        m.toggle(local)
        #expect(m.chosen.isEmpty && m.excluded.isEmpty)
    }

    @Test func choosingAFolderAbsorbsWhatWasChosenInsideIt() throws {
        let box = try Box()
        let (m, local, _) = model(box)
        let l = box.project + "/.local"
        m.toggle(path: l + "/a/one.log")
        #expect(m.state(of: l + "/a") == .mixed)
        // Partly chosen, a box chooses the whole; chosen, it unchooses.
        m.toggle(path: l + "/a")
        #expect(m.chosen == [l + "/a"])
        #expect(m.check(local) == .mixed)
        m.toggle(local)
        #expect(m.chosen == [l] && m.check(local) == .on)
        m.toggle(local)
        #expect(m.chosen.isEmpty && m.check(local) == .off)
    }

    @Test func onlyRemovableEntriesCanBeChosen() throws {
        let box = try Box()
        let (m, _, build) = model(box)
        m.toggle(path: box.project + "/Sources/main.swift")
        #expect(m.chosen.isEmpty)
        m.toggle(path: box.project + "/.build/x.o")
        m.clearChoice(in: [box.project])
        #expect(m.chosen.isEmpty && m.check(build) == .off)
    }

    @Test func dataTiedByANameAloneIsNeverChosenForTheUser() throws {
        let box = try Box()
        let p = box.project
        let outside = box.root + "/Caches/com.vendor.App"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let named = FootprintItem(
            id: p + "#named", category: .build, title: "com.vendor.App", location: outside, attribution: .nameMatch,
            entries: [FootprintEntry(path: outside, bytes: 4096, modified: .distantPast)])
        let build = FootprintItem(
            id: p + "#build", category: .build, title: ".build", location: p, attribution: .inside,
            entries: [FootprintEntry(path: p + "/.build", bytes: 4096, modified: .distantPast)])
        let f = ProjectFootprint(project: DevProject(path: p, markers: [".git"]), items: [named, build])
        let store = URL(fileURLWithPath: box.root + "/store")
        let m = ProjectsModel(footprints: [f], base: store, defaults: testDefaults(in: store), logURL: store.appending(path: "history.json"))
        m.chooseRebuildable(in: [f.id])
        #expect(m.chosen == [p + "/.build"])
        #expect(m.notice?.text.contains("matched by name only") == true)
    }
}
