import Foundation
import Testing

@testable import StorageKit

@Suite struct DownloadsReviewTests {
    @Test func everyFileIsListedOldestFirstAndAPackageAsOne() throws {
        let box = try Sandbox()
        let old = try box.file("Downloads/old.pdf", bytes: 100)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old.path)
        try box.file("Downloads/new.zip", bytes: 200)
        try box.file("Downloads/Editor.app/Contents/MacOS/bin", bytes: 300)
        try box.file("Downloads/a/b/c/deep.txt", bytes: 10)
        let (items, truncated) = DownloadsReview.list(box.path + "/Downloads", depth: 3)
        #expect(!truncated)
        #expect(items.first?.name == "old.pdf")
        #expect(items.contains { $0.name == "Editor.app" && $0.isFolder })
        #expect(!items.contains { $0.path.contains("Editor.app/") })
        // Past the depth, not read.
        #expect(!items.contains { $0.name == "deep.txt" })
    }
}
