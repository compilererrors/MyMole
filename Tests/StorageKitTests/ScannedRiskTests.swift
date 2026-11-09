import Foundation
import Testing

@testable import StorageKit

@Suite struct ScannedRiskTests {
    @Test(arguments: [
        "hidden/.aws/key", "hidden/.kube/config", "hidden/.azure/token", "hidden/.netrc", "hidden/.npmrc",
        "hidden/.docker/config.json", "hidden/.config/gh/hosts", "hidden/.config/gcloud/token",
        "Library/Safari/history", "Library/Application Support/Google/Chrome/Default/history",
        "Library/Application Support/Firefox/Profiles/default/history", "Library/Application Support/BraveSoftware/history",
        "Library/Application Support/Microsoft Edge/history", "Library/Application Support/Arc/history",
        "discard/.Trash/file", "Library/Application Support/MobileSync/Backup/device/file",
        "Library/Mobile Documents/cloud/file", "Library/CloudStorage/provider/file",
        "images/Album.photoslibrary/original", "Documents/personal", "Library/Mail/data", "Library/Messages/data",
        "images/Docker.raw", "images/guest.vmwarevm/data", "images/guest.pvm/data", "images/guest.utm/data",
        "images/guest.vdi", "images/guest.vmdk.backup", "images/guest.qcow2",
        "VirtualBox VMs/guest/data", "Parallels/guest/data", "Library/Developer/Xcode/Archives/archive/data",
        "Library/Group Containers/shared/data", "Library/Developer/CoreSimulator/Devices/device/data",
    ]) func warningsIncludeSmallFilesWithoutAnotherWalk(_ relative: String) throws {
        let box = try Sandbox()
        try box.file(relative, bytes: 1)
        let result = StorageScanner.scan(path: box.path, workers: 2)
        let expected = try #require(PathRisk.of(box.path + "/" + relative))
        #expect(result.root.scannedRisk?.level == expected.level)
        #expect(result.root.scannedRisk?.reason == "Inside: " + expected.reason)
        #expect(result.root.riskComplete)
        // The warning is the scan's metadata, independent of subsequent reads.
        try FileManager.default.removeItem(at: box.url.appending(path: relative))
        #expect(result.root.scannedRisk?.reason == "Inside: " + expected.reason)
    }

    @Test func skippedAndCancelledTreesCannotClaimCompleteRiskInformation() throws {
        let box = try Sandbox()
        try box.file("omitted/.netrc", bytes: 1)
        let result = StorageScanner.scan(path: box.path, skip: [box.path + "/omitted"])
        #expect(result.root.scannedRisk == nil && !result.root.riskComplete)
        let cancelled = ScanProgress()
        cancelled.cancel()
        #expect(!StorageScanner.scan(path: box.path, progress: cancelled).root.riskComplete)
    }

    @Test func hardLinkedCredentialNamesAreCheckedEvenWhenTheirBlocksWereCountedElsewhere() throws {
        let box = try Sandbox()
        let original = try box.file("ordinary/data", bytes: 2)
        try box.folder("hidden")
        try FileManager.default.linkItem(at: original, to: box.url.appending(path: "hidden/.netrc"))
        let result = StorageScanner.scan(path: box.path, workers: 1)
        #expect(result.root.scannedRisk?.reason.contains("Sign-in keys") == true)
    }
}
