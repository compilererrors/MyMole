import Foundation
import Testing

@testable import StorageKit

@Suite struct InstallerFinderTests {
    private func locations(_ box: Sandbox) -> [InstallerLocation] {
        [InstallerLocation(path: box.path + "/Downloads", depth: 2), InstallerLocation(path: box.path + "/Cache", depth: 1)]
    }

    @Test func findsInstallersByTypeWithinDepth() throws {
        let box = try Sandbox()
        try box.file("Downloads/Editor-2.4.dmg", bytes: 40_000)
        try box.file("Downloads/old/Tool.PKG", bytes: 20_000)
        try box.file("Downloads/old/deeper/Too-Deep.dmg", bytes: 10_000)
        try box.file("Downloads/Xcode_99.xip", bytes: 30_000)
        try box.file("Downloads/notes.txt", bytes: 5_000)
        try box.file("Downloads/photos.zip", bytes: 5_000)
        try box.file("Downloads/.hidden/Secret.dmg", bytes: 5_000)
        try box.file("Downloads/node_modules/Bundled.dmg", bytes: 5_000)
        try box.file("Downloads/Sample.app/Contents/Resources/Inner.dmg", bytes: 5_000)
        try box.file("Downloads/Legacy.mpkg/Contents/Archive.pax", bytes: 8_000)
        try box.file("Cache/brewed--Viewer.dmg", bytes: 6_000)
        try FileManager.default.createSymbolicLink(
            atPath: box.path + "/Downloads/Link.dmg", withDestinationPath: box.path + "/Downloads/Editor-2.4.dmg")

        let found = InstallerFinder.find(in: locations(box))
        #expect(Set(found.map(\.name)) == ["Editor-2.4.dmg", "Tool.PKG", "Xcode_99.xip", "Legacy.mpkg", "brewed--Viewer.dmg"])
        #expect(found.first?.name == "Editor-2.4.dmg")
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })
        #expect(byName["Tool.PKG"]?.kind == .package)
        #expect(byName["Xcode_99.xip"]?.kind == .archive)
        #expect(byName["Editor-2.4.dmg"]?.bytes == box.allocated("Downloads/Editor-2.4.dmg"))
        // A folder package counts as one installer, with its contents' size.
        #expect((byName["Legacy.mpkg"]?.bytes ?? 0) >= box.allocated("Downloads/Legacy.mpkg/Contents/Archive.pax"))
    }

    @Test func aCancelledScanFindsNothingMore() throws {
        let box = try Sandbox()
        try box.file("Downloads/A.dmg", bytes: 1_000)
        let p = ScanProgress()
        p.cancel()
        #expect(InstallerFinder.find(in: locations(box), progress: p).isEmpty)
    }

    @Test func isCheckedAgainBeforeTheTrash() throws {
        let box = try Sandbox()
        let locs = locations(box)
        let dmg = try box.file("Downloads/A.dmg", bytes: 1_000).path
        try box.file("Elsewhere/B.dmg", bytes: 1_000)
        try box.file("Downloads/C.txt", bytes: 1_000)

        #expect(InstallerFinder.isStillInstaller(dmg, in: locs))
        #expect(!InstallerFinder.isStillInstaller(box.path + "/Elsewhere/B.dmg", in: locs))
        #expect(!InstallerFinder.isStillInstaller(box.path + "/Downloads/C.txt", in: locs))
        #expect(!InstallerFinder.isStillInstaller(box.path + "/Downloads/../Elsewhere/B.dmg", in: locs))
        #expect(!InstallerFinder.isStillInstaller(box.path + "/Downloads", in: locs))

        // Replaced by a link since the scan: left alone.
        try FileManager.default.removeItem(atPath: dmg)
        try FileManager.default.createSymbolicLink(atPath: dmg, withDestinationPath: box.path + "/Elsewhere/B.dmg")
        #expect(!InstallerFinder.isStillInstaller(dmg, in: locs))
        try FileManager.default.removeItem(atPath: dmg)
        #expect(!InstallerFinder.isStillInstaller(dmg, in: locs))
    }

    @Test func aFileReplacedSinceTheScanOrBehindALinkIsLeftAlone() throws {
        let box = try Sandbox()
        let locs = locations(box)
        try box.file("Downloads/A.dmg", bytes: 1_000)
        let found = try #require(InstallerFinder.find(in: locs).first)
        #expect(InstallerFinder.isStillInstaller(found, in: locs))
        try box.file("Downloads/A.dmg", bytes: 90_000)
        #expect(!InstallerFinder.isStillInstaller(found, in: locs))

        try box.file("Elsewhere/Apps/B.dmg", bytes: 1_000)
        try FileManager.default.createSymbolicLink(atPath: box.path + "/Downloads/Apps", withDestinationPath: box.path + "/Elsewhere/Apps")
        #expect(!InstallerFinder.isStillInstaller(box.path + "/Downloads/Apps/B.dmg", in: locs))
    }
}

@Suite struct InstallerStoreTests {
    @Test func savedResultIsTiedToItsLocations() throws {
        let box = try Sandbox()
        let base = box.url.appending(path: "store")
        let locs = [InstallerLocation(path: "/synthetic/Downloads", depth: 2)]
        let file = InstallerFile(
            path: "/synthetic/Downloads/A.dmg", bytes: 4_096, modified: Date(timeIntervalSince1970: 1_790_000_000), kind: .diskImage)
        InstallerStore.save(InstallerListing(files: [file]), locations: locs, date: Date(timeIntervalSince1970: 1_790_000_100), base: base)

        let saved = try #require(InstallerStore.load(for: locs, base: base))
        #expect(saved.files == [file])
        #expect(saved.date == Date(timeIntervalSince1970: 1_790_000_100))
        #expect(InstallerStore.load(for: [InstallerLocation(path: "/synthetic/Desktop", depth: 2)], base: base) == nil)
    }

    @Test func olderFormatIsIgnored() throws {
        let box = try Sandbox()
        let base = box.url.appending(path: "store")
        let locs = [InstallerLocation(path: "/synthetic/Downloads", depth: 2)]
        let old = InstallerStore.Saved(version: 0, date: Date(), locations: locs, files: [])
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try JSONEncoder().encode(old).write(to: base.appending(path: "last.json"))
        #expect(InstallerStore.load(for: locs, base: base) == nil)
    }
}
