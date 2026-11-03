import Darwin
import Foundation
import Testing

@testable import StorageKit

/// A search folder that's there but can't be read makes the result
/// incomplete, so it never replaces a complete saved one; a folder that
/// isn't there at all is just empty. Everything is in the test's own folder.
@Suite struct ListingCompletenessTests {
    @Test func anUnreadableInstallerFolderKeepsTheCompleteResult() throws {
        let box = try Sandbox()
        try box.file("Downloads/Setup.dmg", bytes: 8_192)
        let locations = [
            InstallerLocation(path: box.path + "/Downloads", depth: 2),
            InstallerLocation(path: box.path + "/Missing", depth: 2),
        ]
        let base = box.url.appending(path: "store")
        let complete = InstallerFinder.list(in: locations)
        #expect(complete.isComplete && complete.files.count == 1)
        InstallerStore.save(complete, locations: locations, base: base)

        #expect(chmod(box.path + "/Downloads", 0) == 0)
        defer { chmod(box.path + "/Downloads", 0o700) }
        let closed = InstallerFinder.list(in: locations)
        #expect(closed.files.isEmpty && closed.unreadable == [box.path + "/Downloads"] && !closed.isComplete)
        InstallerStore.save(closed, locations: locations, base: base)
        #expect(InstallerStore.load(for: locations, base: base)?.files.count == 1)
    }

    @Test func anUnreadableAppFolderKeepsTheCompleteResult() throws {
        let box = try Sandbox()
        try makeApp(box, "Applications/Editor.app", id: "com.vendor.Editor")
        let folders = [box.path + "/Applications", box.path + "/Missing"]
        let base = box.url.appending(path: "store")
        let complete = AppFinder.list(in: folders, workers: 1)
        #expect(complete.isComplete && complete.apps.count == 1)
        AppStore.save(complete, folders: folders, base: base)

        #expect(chmod(box.path + "/Applications", 0) == 0)
        defer { chmod(box.path + "/Applications", 0o700) }
        let closed = AppFinder.list(in: folders, workers: 1)
        #expect(closed.apps.isEmpty && !closed.isComplete)
        AppStore.save(closed, folders: folders, base: base)
        #expect(AppStore.load(folders: folders, base: base)?.apps.count == 1)
    }

    @Test func closedAppContainersMakeADeepCleanScanIncomplete() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/com.vendor.Editor/blob", bytes: 4_000)
        try box.folder("Library/Containers/com.vendor.Player/Data/Library/Caches")
        #expect(CleanScanner.list(home: box.path, workers: 1).isComplete)
        #expect(chmod(box.path + "/Library/Containers", 0) == 0)
        defer { chmod(box.path + "/Library/Containers", 0o700) }
        let closed = CleanScanner.list(home: box.path, workers: 1)
        #expect(closed.unreadable == [box.path + "/Library/Containers"] && !closed.isComplete)
        #expect(closed.candidates.contains { $0.path.hasSuffix("com.vendor.Editor") })
    }
}

/// Data outside projects that's there but can't be read makes every
/// project's result incomplete, so it isn't saved as the last complete one.
@Suite struct ProjectOutsideCompletenessTests {
    @Test func aClosedLibraryFolderMakesTheScanIncomplete() throws {
        let box = try Sandbox()
        try box.file("home/Work/Lantern/Package.swift", bytes: 100)
        try box.file("home/Library/Caches/com.vendor.lantern/blob", bytes: 4_000)
        let home = box.path + "/home"
        let roots = [home + "/Work"]
        let open = ProjectScanner.scan(roots: roots, home: home, workers: 1)
        #expect(open.count == 1 && !open[0].incomplete && open[0].outsideBytes > 0)

        #expect(chmod(home + "/Library/Caches", 0) == 0)
        defer { chmod(home + "/Library/Caches", 0o700) }
        let outside = ProjectAttribution.find(for: open.map(\.project), home: home)
        #expect(outside.unreadable == [home + "/Library/Caches"])
        let closed = ProjectScanner.scan(roots: roots, home: home, workers: 1)
        #expect(closed.count == 1 && closed[0].incomplete)
        #expect(ProjectScanner.rescan(closed[0].project, among: [closed[0].project], home: home).incomplete)

        let base = box.url.appending(path: "store")
        ProjectStore.save(open, roots: roots, base: base)
        ProjectStore.save(closed, roots: roots, base: base)
        #expect(ProjectStore.loadLast(roots: roots, base: base)?.footprints.first?.incomplete == false)
    }
}
