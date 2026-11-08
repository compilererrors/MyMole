import Foundation
import Testing

@testable import StorageKit

/// What removed apps left, in a Library of the test's own.
@Suite struct OrphansTests {
    private func library(_ box: Sandbox) throws -> String {
        for rel in [
            "Library/Caches/com.gone.Editor/blob",
            "Library/Saved Application State/com.gone.Editor.savedState/data.data",
            "Library/Application Support/com.gone.Editor/notes.db",
            "Library/Caches/com.apple.Safari/blob",
            "Library/Caches/com.vendor.Updater/blob",
            "Library/Caches/com.known.Elsewhere/blob",
            "Library/Caches/com.running.Daemon/blob",
            "Library/Caches/com.short/blob",
            "Library/Caches/Google/blob",
            "Library/Caches/2.0.thing.cache/blob",
            "Library/Group Containers/ABCDE12345.com.gone.Editor/blob",
        ] {
            try box.file(rel, bytes: 5_000)
        }
        try box.file("Library/Preferences/com.gone.Editor.plist", bytes: 600)
        try box.file("Library/Preferences/com.gone.Editor.txt", bytes: 600)
        return box.path
    }

    private func installed(in box: Sandbox) throws -> [AppBundle] {
        try box.folder("Applications/App.app/Contents")
        try (["CFBundleIdentifier": "com.vendor.App"] as NSDictionary)
            .write(to: box.url.appending(path: "Applications/App.app/Contents/Info.plist"))
        return [try #require(AppFinder.metadata(box.path + "/Applications/App.app"))]
    }

    private func known(_ id: String) -> Bool { id == "com.known.Elsewhere" }

    @Test func findsOnlyWhatNothingOnTheMacAnswersTo() throws {
        let box = try Sandbox()
        let home = try library(box)
        let installed = try installed(in: box)
        let found = Orphans.find(home: home, installed: installed, known: known, running: ["com.running.Daemon"])
        let names = Set(found.map { String($0.path.dropFirst(home.count + "/Library/".count)) })
        #expect(names == [
            "Caches/com.gone.Editor", "Saved Application State/com.gone.Editor.savedState",
            "Application Support/com.gone.Editor", "Preferences/com.gone.Editor.plist",
        ])
        #expect(Set(found.map(\.bundleID)) == ["com.gone.Editor"])
        // Caches and window states start chosen; settings and data never do.
        let byPlace = Dictionary(uniqueKeysWithValues: found.map { ($0.leftover.place, $0.kind.chosenByDefault) })
        #expect(byPlace["Caches"] == true && byPlace["Saved Application State"] == true)
        #expect(byPlace["Preferences"] == false && byPlace["Application Support"] == false)
    }

    @Test func anAppOfTheSameVendorClaimsItsHelpers() throws {
        let box = try Sandbox()
        let home = try library(box)
        let installed = try installed(in: box)
        let found = Orphans.find(home: home, installed: [], known: { _ in false }, running: [])
        // Without the vendor's app installed, its updater is a leftover too.
        #expect(found.contains { $0.bundleID == "com.vendor.Updater" })
        let withApp = Orphans.find(home: home, installed: installed, known: { _ in false }, running: [])
        #expect(!withApp.contains { $0.bundleID == "com.vendor.Updater" })
    }

    @Test func isCheckedAgainBeforeTheTrash() throws {
        let box = try Sandbox()
        let home = try library(box)
        let installed = try installed(in: box)
        let cache = home + "/Library/Caches/com.gone.Editor"
        #expect(Orphans.isStillOrphan(cache, home: home, installed: installed, known: known, running: []))
        // Installed again meanwhile, or running now: it's the app's again.
        let back = installed + [AppBundle(path: "/Applications/Editor.app", name: "Editor", bundleID: "com.gone.Editor", version: "2", bytes: 1, fromAppStore: false)]
        #expect(!Orphans.isStillOrphan(cache, home: home, installed: back, known: known, running: []))
        #expect(!Orphans.isStillOrphan(cache, home: home, installed: installed, known: known, running: ["com.gone.Editor"]))
        // Not directly in a searched folder, or not there at all.
        #expect(!Orphans.isStillOrphan(cache + "/blob", home: home, installed: installed, known: known, running: []))
        #expect(!Orphans.isStillOrphan(home + "/Library/Caches/com.gone.Missing", home: home, installed: installed, known: known, running: []))
        // Swapped for a link: left alone.
        try FileManager.default.removeItem(atPath: cache)
        try FileManager.default.createSymbolicLink(atPath: cache, withDestinationPath: home + "/Library/Caches/Google")
        #expect(!Orphans.isStillOrphan(cache, home: home, installed: installed, known: known, running: []))
    }
}

@Suite struct OrphanListingTests {
    @Test func aHelperInAnotherNamespaceStillHasAnOwnerAndUnknownMetadataBlocksTheSearch() throws {
        let box = try Sandbox()
        for (path, id) in [("Applications/Viewer.app", "org.current.Viewer"),
                           ("Applications/Viewer.app/Contents/XPCServices/Worker.xpc", "com.shared.Worker")] {
            try box.folder(path + "/Contents")
            try (["CFBundleIdentifier": id] as NSDictionary).write(to: box.url.appending(path: path + "/Contents/Info.plist"))
        }
        try box.file("Library/Caches/com.shared.Worker/cache", bytes: 100)
        try box.file("Library/Preferences/com.shared.Worker.plist", bytes: 100)
        try box.file("Library/Caches/com.gone.Editor/cache", bytes: 100)
        let apps = [try #require(AppFinder.metadata(box.path + "/Applications/Viewer.app"))]
        let found = Orphans.list(home: box.path, installed: apps, known: { _ in false }, running: [])
        #expect(found.orphans.map(\.bundleID) == ["com.gone.Editor"] && !found.unknownOwners)
        #expect(!Orphans.isStillOrphan(box.path + "/Library/Caches/com.shared.Worker", home: box.path, installed: apps, known: { _ in false }, running: []))
        try Data("unreadable identity".utf8).write(to: box.url.appending(path: "Applications/Viewer.app/Contents/XPCServices/Worker.xpc/Contents/Info.plist"))
        let unknown = Orphans.list(home: box.path, installed: apps, known: { _ in false }, running: [])
        #expect(unknown.unknownOwners && unknown.orphans.isEmpty)
        #expect(!Orphans.isStillOrphan(box.path + "/Library/Caches/com.gone.Editor", home: box.path, installed: apps, known: { _ in false }, running: []))
    }

    @Test func registrationIsReadOncePerIdentityAndCancellationIsNotACompleteListing() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/com.gone.Editor/blob", bytes: 100)
        try box.file("Library/Preferences/com.gone.Editor.plist", bytes: 100)
        var calls = 0
        let listing = Orphans.list(home: box.path, installed: [], known: { _ in calls += 1; return false }, running: [])
        #expect(calls == 1 && listing.orphans.count == 2 && !listing.cancelled)
        let progress = ScanProgress()
        let stopped = Orphans.list(home: box.path, installed: [], known: { _ in progress.cancel(); return false }, running: [], progress: progress)
        #expect(stopped.cancelled && stopped.orphans.isEmpty)
    }

    @Test func linkedSearchFoldersAndPartlyUnreadableDataAreNotOffered() throws {
        let box = try Sandbox()
        try box.file("outside/com.gone.Editor/blob", bytes: 100)
        try box.folder("Library")
        try FileManager.default.createSymbolicLink(atPath: box.path + "/Library/Caches", withDestinationPath: box.path + "/outside")
        try box.file("Library/Application Support/com.gone.Editor/private/blob", bytes: 100)
        let privateFolder = box.path + "/Library/Application Support/com.gone.Editor/private"
        #expect(chmod(privateFolder, 0) == 0)
        defer { _ = chmod(privateFolder, 0o755) }
        let listing = Orphans.list(home: box.path, installed: [], known: { _ in false }, running: [])
        #expect(listing.orphans.isEmpty)
        #expect(Set(listing.unreadable) == [box.path + "/Library/Caches", box.path + "/Library/Application Support/com.gone.Editor"])
    }

    @Test func aFolderThatCantBeReadIsSaidAndAMissingOneIsNot() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/com.gone.Editor/blob", bytes: 100)
        try box.folder("Library/Preferences")
        #expect(chmod(box.path + "/Library/Preferences", 0) == 0)
        defer { _ = chmod(box.path + "/Library/Preferences", 0o755) }
        let listing = Orphans.list(home: box.path, installed: [], known: { _ in false }, running: [])
        #expect(listing.orphans.map(\.bundleID) == ["com.gone.Editor"])
        #expect(listing.unreadable == [box.path + "/Library/Preferences"])
    }

    @Test func theAppsInstalledNowAreReadQuicklyOrNotAtAll() throws {
        let box = try Sandbox()
        try box.folder("Applications/Editor.app/Contents")
        let info: NSDictionary = ["CFBundleIdentifier": "com.vendor.Editor"]
        try info.write(to: box.url.appending(path: "Applications/Editor.app/Contents/Info.plist"))
        try box.folder("Applications/Utilities/Tool.app/Contents")
        try (["CFBundleIdentifier": "com.vendor.Tool"] as NSDictionary)
            .write(to: box.url.appending(path: "Applications/Utilities/Tool.app/Contents/Info.plist"))
        let apps = try #require(AppFinder.installedNow(in: [box.path + "/Applications", box.path + "/Missing"]))
        #expect(Set(apps.map(\.name)) == ["Editor", "Tool"])
        #expect(apps.first { $0.name == "Editor" }?.bundleID == "com.vendor.Editor")
        #expect(chmod(box.path + "/Applications/Utilities", 0) == 0)
        defer { _ = chmod(box.path + "/Applications/Utilities", 0o755) }
        #expect(AppFinder.installedNow(in: [box.path + "/Applications"]) == nil)
    }
}
