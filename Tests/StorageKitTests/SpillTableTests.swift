import Foundation
import Testing

@testable import StorageKit

@Suite struct SpillTableTests {
    private func rows(_ n: Int) -> [SpillTable.Row] {
        (0..<n).map { i in
            SpillTable.Row(path: "/synthetic/folder-\(i % 7)/file-\(i).bin", size: Int64((i * 7_919) % 100_003),
                           modified: Date(timeIntervalSinceReferenceDate: Double(i)), kind: FileKind.allCases[i % FileKind.allCases.count])
        }
    }

    @Test func rowsReadBackExactlyAsWritten() throws {
        let box = try Sandbox()
        let input = rows(3_000)
        let table = try SpillTable(writing: input, in: box.url)
        #expect(table.count == 3_000)
        for i in [0, 1, 1_023, 1_024, 2_999] { #expect(table.row(at: i) == input[i]) }
        #expect(table.row(at: -1) == nil && table.row(at: 3_000) == nil)
        #expect(table.diskBytes > 0)
    }

    @Test func orderAndFilterMatchTheSameWorkInMemory() throws {
        let box = try Sandbox()
        let input = rows(5_000)
        let table = try SpillTable(writing: input, in: box.url)
        let bySize = try #require(table.ordered(by: .size, ascending: false))
        #expect(bySize.map { input[Int($0)].size } == input.map(\.size).sorted(by: >))
        let byName = try #require(table.ordered(by: .name, ascending: true))
        #expect(byName.count == input.count)
        let names = byName.map { input[Int($0)].name }
        #expect(zip(names, names.dropFirst()).allSatisfy { $0.localizedStandardCompare($1) != .orderedDescending })
        let filtered = try #require(table.ordered(by: .size, ascending: true, query: "FOLDER-3", keep: { $0.size > 100 }))
        let expected = input.indices.filter { input[$0].path.contains("folder-3") && input[$0].size > 100 }
        #expect(Set(filtered.map(Int.init)) == Set(expected))
    }

    @Test func onlyAFewPagesStayInMemory() throws {
        let box = try Sandbox()
        let table = try SpillTable(writing: rows(20_000), in: box.url, hotBytes: 2 * SpillTable.pageRows * 160)
        for i in stride(from: 0, to: 20_000, by: 500) { _ = table.row(at: i) }
        #expect(table.hotPages <= 2)
        // Ordering reads every page without keeping them.
        _ = table.ordered(by: .size, ascending: true)
        #expect(table.hotPages <= 2)
    }

    @Test func aStoppedWriteLeavesNothingBehind() throws {
        let box = try Sandbox()
        #expect(throws: SpillTable.Failure.self) { _ = try SpillTable(writing: rows(5_000), in: box.url, stop: { true }) }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: box.path)) ?? []).isEmpty)
    }

    @Test func aWriteThatCantStartThrows() throws {
        let box = try Sandbox()
        // The place to write is a file, not a folder.
        try box.file("blocked", bytes: 10)
        #expect(throws: SpillTable.Failure.self) { _ = try SpillTable(writing: rows(10), in: box.url.appending(path: "blocked")) }
    }

    @Test func aDamagedOrRemovedTableReadsAsNothingNeverAsWrongRows() throws {
        let box = try Sandbox()
        let table = try SpillTable(writing: rows(3_000), in: box.url, hotBytes: 1)
        let records = table.folder.appending(path: "records")
        try FileHandle(forWritingTo: records).truncate(atOffset: 100)
        #expect(table.row(at: 2_000) == nil)
        #expect(table.ordered(by: .size, ascending: true) == nil)
        table.remove()
        #expect(!FileManager.default.fileExists(atPath: table.folder.path))
        #expect(table.row(at: 0) == nil)
    }

    @Test func aTableNobodyHoldsTakesItsFilesWithIt() throws {
        let box = try Sandbox()
        var table: SpillTable? = try SpillTable(writing: rows(10), in: box.url)
        let folder = try #require(table?.folder)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(SpillTable.bytes(in: box.url) > 0)
        table = nil
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(SpillTable.bytes(in: box.url) == 0)
    }

    @Test func clearingAtLaunchRemovesOnlyTables() throws {
        let box = try Sandbox()
        let table = try SpillTable(writing: rows(10), in: box.url)
        defer { withExtendedLifetime(table) {} }
        try box.file("notes/kept.txt", bytes: 10)
        try box.folder("\(UUID().uuidString)/inner")
        SpillTable.removeAll(in: box.url)
        #expect(!FileManager.default.fileExists(atPath: table.folder.path))
        #expect(FileManager.default.fileExists(atPath: box.path + "/notes/kept.txt"), "Not a table: stays")
        // A UUID folder holding something other than a table's files stays too.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: box.path)) ?? []).count == 2)
    }
}
