import Foundation
import Testing

@testable import StorageKit

@Suite struct FootprintEntryTests {
    @Test func savedEntriesFromBeforeDirectoryHintsStillDecode() throws {
        let data = Data(#"{"path":"/synthetic/project/build","bytes":4096,"modified":0}"#.utf8)
        let entry = try JSONDecoder().decode(FootprintEntry.self, from: data)
        #expect(entry.path == "/synthetic/project/build" && entry.isDirectory == nil)
    }

    @Test(arguments: [true, false]) func scanDirectoryHintsSurviveSavingAndRestoring(_ directory: Bool) throws {
        let entry = FootprintEntry(path: "/synthetic/project/output", bytes: 4096, modified: .distantPast, isDirectory: directory)
        let restored = try JSONDecoder().decode(FootprintEntry.self, from: JSONEncoder().encode(entry))
        #expect(restored == entry && restored.isDirectory == directory)
    }
}
