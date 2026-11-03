import Foundation
import Testing

@testable import PrivilegedKit
import StorageKit

/// System-wide leftovers in a synthetic system folder of the box: what's
/// found, what the helper's rules let it remove, and the order it goes in.
@Suite struct SystemLeftoversTests {
    let ids = ["com.vendor.Editor", "com.vendor.Editor.Helper"]

    func system() throws -> Box {
        let box = try Box()
        // Ownership is checked against the apps installed here.
        try box.folder("Applications")
        try box.file("Library/LaunchDaemons/com.vendor.Editor.Helper.plist", try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.vendor.Editor.Helper"], format: .xml, options: 0))
        try box.file("Library/LaunchDaemons/com.other.Daemon.plist")
        try box.file("Library/PrivilegedHelperTools/com.vendor.Editor.Helper")
        try box.file("Library/Application Support/com.vendor.Editor/state.db")
        try box.file("Library/Application Support/Editor/state.db")
        try box.file("Library/Preferences/com.vendor.Editor.plist")
        try box.file("Library/Caches/com.vendor.Editor/c")
        try box.file("Library/Caches/com.vendor.EditorX/c")
        try box.file("private/var/db/receipts/com.vendor.Editor.pkg.bom")
        try box.file("private/var/db/receipts/com.vendor.Editor.pkg.plist")
        try box.file("private/var/db/receipts/com.apple.pkg.Thing.bom")
        try FileManager.default.createSymbolicLink(
            atPath: box.path + "/Library/Caches/com.vendor.Editor.Helper", withDestinationPath: box.path + "/Library/Preferences")
        return box
    }

    @Test func findsByExactIDsOnlyDaemonsFirst() throws {
        let box = try system()
        let found = SystemLeftovers.find(ids: ids, base: box.path)
        let rel = found.map { String($0.path.dropFirst(box.path.count)) }
        #expect(rel == [
            "/Library/LaunchDaemons/com.vendor.Editor.Helper.plist",
            "/Library/PrivilegedHelperTools/com.vendor.Editor.Helper",
            "/Library/Caches/com.vendor.Editor",
            "/Library/Preferences/com.vendor.Editor.plist",
            "/Library/Application Support/com.vendor.Editor",
            "/private/var/db/receipts/com.vendor.Editor.pkg.bom",
            "/private/var/db/receipts/com.vendor.Editor.pkg.plist",
        ])
        #expect(found.first { $0.place == "/Library/Preferences" }?.kind.chosenByDefault == false)
        #expect(found.first { $0.place == "/Library/LaunchDaemons" }?.kind.chosenByDefault == true)
    }

    @Test func idsTooLooseOrApplesFindNothing() throws {
        let box = try system()
        #expect(SystemLeftovers.find(ids: ["vendor.Editor", "com.apple.pkg.Thing", "com.vendor"], base: box.path).isEmpty)
        #expect(!SystemLeftovers.isUsable("com.apple.Safari") && !SystemLeftovers.isUsable("com.vendor"))
    }

    @Test func removesWhatTheRulesAllowAndStopsTheJobFirst() throws {
        let box = try system()
        let fake = FakeRunner()
        let wanted = SystemLeftovers.find(ids: ids, base: box.path).map(\.path)
        let sneaky = [
            box.path + "/Library/LaunchDaemons/com.other.Daemon.plist", box.path + "/Library/Application Support/Editor",
            box.path + "/Library/Caches/com.vendor.EditorX", box.path + "/Library/Caches/com.vendor.Editor.Helper",
            box.path + "/Library/Caches/./com.vendor.Editor", box.path + "/Library/Caches",
        ]
        let report = SystemLeftovers.remove(wanted + sneaky, appID: "com.vendor.Editor", ids: ids, base: box.path, runner: fake.runner)
        #expect(Set(report.removed) == Set(wanted))
        #expect(Set(report.refused) == Set(sneaky))
        #expect(fake.calls.withLock { $0 } == [[SystemLeftovers.launchctl, "bootout", "system/com.vendor.Editor.Helper"]])
        #expect(box.exists("Library/LaunchDaemons/com.other.Daemon.plist"))
        #expect(box.exists("Library/Application Support/Editor/state.db"))
        #expect(box.exists("Library/Caches/com.vendor.EditorX/c"))
        #expect(box.exists("Library/Preferences"))
        #expect(!box.exists("Library/LaunchDaemons/.mymole-removing"))
    }

    @Test func nothingGoesWhenInstalledAppsCantBeRead() throws {
        let box = try system()
        try FileManager.default.removeItem(atPath: box.path + "/Applications")
        let paths = SystemLeftovers.find(ids: ids, base: box.path).map(\.path)
        let report = SystemLeftovers.remove(paths, appID: "com.vendor.Editor", ids: ids, base: box.path, runner: FakeRunner().runner)
        #expect(report.removed.isEmpty && Set(report.refused) == Set(paths))
    }

    @Test func idsOutsideTheVendorAreIgnoredAndStuckJobsStay() throws {
        let box = try system()
        try box.file("Library/Caches/com.other.Thing/c")
        let other = box.path + "/Library/Caches/com.other.Thing"
        let daemon = box.path + "/Library/LaunchDaemons/com.vendor.Editor.Helper.plist"
        let stuck = FakeRunner(codes: [SystemLeftovers.launchctl: 5])
        let report = SystemLeftovers.remove([other, daemon], appID: "com.vendor.Editor", ids: ids + ["com.other.Thing"], base: box.path, runner: stuck.runner)
        #expect(report.refused == [other])
        #expect(report.failed[daemon] != nil)
        #expect(box.exists("Library/Caches/com.other.Thing/c") && box.exists("Library/LaunchDaemons/com.vendor.Editor.Helper.plist"))
    }

    @Test func nothingGoesWhileTheAppIsStillInstalled() throws {
        let box = try system()
        try box.file("Applications/Editor.app/Contents/Info.plist", try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.vendor.Editor"], format: .xml, options: 0))
        let paths = SystemLeftovers.find(ids: ids, base: box.path).map(\.path)
        let fake = FakeRunner()
        let report = SystemLeftovers.remove(paths, appID: "com.vendor.Editor", ids: ids, base: box.path, runner: fake.runner)
        #expect(report.removed.isEmpty && report.refused.count == paths.count)
        #expect(fake.calls.withLock { $0 }.isEmpty)
        #expect(box.exists("Library/PrivilegedHelperTools/com.vendor.Editor.Helper"))
    }
}

/// Removal that a link inside the tree can't send elsewhere.
@Suite struct SecureRemoveTests {
    @Test func removesTheTreeAndNothingALinkPointsAt() throws {
        let box = try Box()
        try box.file("outside/precious")
        try box.file("tree/a/b/c/file")
        try box.file("tree/top")
        try FileManager.default.createSymbolicLink(atPath: box.path + "/tree/a/out", withDestinationPath: box.path + "/outside")
        try FileManager.default.createSymbolicLink(atPath: box.path + "/tree/a/b/file-link", withDestinationPath: box.path + "/outside/precious")
        #expect(SecureRemove.removeTree(box.path + "/tree"))
        #expect(!box.exists("tree"))
        #expect(box.exists("outside/precious"))
    }

    @Test func aLinkAsTheItemIsRemovedItselfAndAFileToo() throws {
        let box = try Box()
        try box.file("outside/precious")
        try FileManager.default.createSymbolicLink(atPath: box.path + "/link", withDestinationPath: box.path + "/outside")
        #expect(SecureRemove.removeTree(box.path + "/link"))
        #expect(box.exists("outside/precious"))
        let f = try box.file("single")
        #expect(SecureRemove.removeTree(f) && !box.exists("single"))
        #expect(SecureRemove.removeTree(box.path + "/missing"))
        #expect(!SecureRemove.removeTree(box.path + "/.."))
    }
}
