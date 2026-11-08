import Foundation
import StorageKit
import Testing

@testable import MyMole

/// Large Files by place: a folder and everything below it, nothing beside it.
@Suite struct LargeFilesPlaceTests {
    private func file(in folder: String) -> LargeFile {
        LargeFile(path: folder + "/a.zip", name: "a.zip", folder: folder, size: 1, modified: .now, kind: .archives)
    }

    @Test func aPlaceHoldsItsFolderAndWhatsInside() {
        let home = "/Users/synthetic"
        let downloads = home + "/Downloads"
        #expect(LargeFilesView.Place.downloads.contains(file(in: downloads), home: home))
        #expect(LargeFilesView.Place.downloads.contains(file(in: downloads + "/old/zips"), home: home))
        // A folder that only starts with the same name isn't in it.
        #expect(!LargeFilesView.Place.downloads.contains(file(in: downloads + " Backup"), home: home))
        #expect(!LargeFilesView.Place.desktop.contains(file(in: downloads), home: home))
        #expect(LargeFilesView.Place.anywhere.contains(file(in: "/Volumes/External"), home: home))
    }
}
