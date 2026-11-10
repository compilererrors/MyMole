import Foundation
import Testing
@testable import MyMole
@testable import StorageKit

@Suite struct DiskMapPipelineTests {
    @Test func sessionRetirementPreventsLateReadersAndJoinsAdmittedMetadataReaders() {
        let walking = DiskScanSession()
        #expect(!walking.retire() && !walking.beginFinalization())
        let finalizing = DiskScanSession()
        #expect(finalizing.beginFinalization())
        #expect(finalizing.retire())
        finalizing.finish()
        #expect(!finalizing.retire() && !finalizing.beginFinalization())
    }

    @Test func partialPresentationTransfersPublishedBranchesAndReplacesUnknownOnes() {
        let root = Folder(name: "synthetic", parent: nil, rootPath: "/synthetic")
        let ready = Folder(name: "ready", parent: root)
        ready.listedFiles = [FileItem(name: "file.bin", size: 2_000_000, modified: .distantPast, kind: .other)]
        ready.ownBytes[.other] = 2_000_000
        ready.finish()
        let pending = Folder(name: "pending", parent: root)
        root.subfolders = [ready, pending]
        let copy = root.partialPresentation(published: [ready.id])
        #expect(copy !== root && copy.find(path: "/synthetic/ready") === ready)
        #expect(ready.parent === copy && ready.path == "/synthetic/ready")
        let unknown = copy.find(path: "/synthetic/pending")
        #expect(unknown !== pending && unknown?.wasNotScanned == true)
        pending.listedFiles = [FileItem(name: "late.bin", size: 9, modified: .distantPast, kind: .other)]
        #expect(unknown?.listedFiles.isEmpty == true && copy.size == 2_000_000)
        #expect(!copy.riskComplete)
    }

    private func tree(files: Int) -> Folder {
        let root = Folder(name: "synthetic", parent: nil, rootPath: "/synthetic")
        root.listedFiles = (0..<files).map {
            FileItem(name: "file-\($0).bin", size: Int64(($0 * 7919) % 100_000) + 1_048_576,
                     modified: .distantPast, kind: .other)
        }
        return root
    }

    @Test func boundedCollectionMatchesFullSortingAndStopsWithoutFinishingTheList() {
        let root = tree(files: 50_000)
        let largest = StorageModel.collectLargeFiles(root, limit: 37)
        let expected = root.listedFiles.sorted { a, b in a.size == b.size ? a.name < b.name : a.size > b.size }.prefix(37)
        #expect(largest.map(\.name) == expected.map(\.name))
        #expect(StorageModel.collectLargeFiles(root, limit: 0).isEmpty)
        var checks = 0
        let stopped = StorageModel.collectLargeFiles(root, limit: 37) { checks += 1; return checks > 3 }
        #expect(stopped.isEmpty && checks <= 8)
    }

    @Test func cancelledIndexAndSnapshotAreExplicitlyIncomplete() {
        let root = tree(files: 10_000)
        root.listedFiles = root.listedFiles.map { FileItem(name: $0.name, size: $0.size + 100_000_000, modified: $0.modified, kind: $0.kind) }
        var checks = 0
        let index = ScanIndex(root) { checks += 1; return checks > 10 }
        #expect(index.truncated && index.entries.count < 100)
        var stoppedOnce = false
        let snapshot = Snapshot(of: root, stop: {
            if !stoppedOnce { stoppedOnce = true; return true }
            return false
        })
        #expect(snapshot.incomplete)
    }
}
