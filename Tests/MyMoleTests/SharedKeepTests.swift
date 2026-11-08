import Foundation
import StorageKit
import Testing

@testable import MyMole

@MainActor
@Suite struct SharedKeepTests {
    @Test func listsReadOffTheMainThreadAreTakenIn() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "shared-keep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let protections = UserProtections(root: root)
        let keep = SharedKeep(protections: protections)
        #expect(!keep.protects("/synthetic/Downloads/a.dmg"))
        _ = try CleanKeepList.update(at: protections.keepList) { $0.paths.insert("/synthetic/Downloads/a.dmg") }
        let read = await keep.reloaded()
        #expect(read.protects("/synthetic/Downloads/a.dmg") && read.isOnOwnList("/synthetic/Downloads/a.dmg"))
        #expect(read.problem == nil)
    }
}
