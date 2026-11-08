import Foundation
import Synchronization
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

    @Test func aDaemonWhoseJobIsntNamedAfterTheAppStays() throws {
        let box = try system()
        let daemons = "Library/LaunchDaemons/"
        func plist(_ content: [String: String]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: content, format: .xml, options: 0)
        }
        // Files named after the app whose jobs answer to other names, and
        // one with no label: it was never loaded as a job.
        try box.file(daemons + "com.vendor.Editor.Updater.plist", try plist(["Label": "com.other.Daemon"]))
        try box.file(daemons + "com.vendor.Editor.Agent.plist", try plist(["Label": "Editor Agent"]))
        try box.file(daemons + "com.vendor.Editor.Old.plist", try plist(["Program": "/usr/bin/true"]))
        let (other, loose, bare) = (
            box.path + "/" + daemons + "com.vendor.Editor.Updater.plist", box.path + "/" + daemons + "com.vendor.Editor.Agent.plist",
            box.path + "/" + daemons + "com.vendor.Editor.Old.plist")
        let fake = FakeRunner()
        let report = SystemLeftovers.remove([other, loose, bare], appID: "com.vendor.Editor", ids: ids, base: box.path, runner: fake.runner)
        #expect(report.removed == [bare])
        #expect(report.failed == [other: "Its job isn't named after the app, so it stays.", loose: "Its job isn't named after the app, so it stays."])
        // Nothing was stopped by a name that isn't the app's.
        #expect(fake.calls.withLock { $0 }.isEmpty)
        #expect(box.exists(daemons + "com.vendor.Editor.Updater.plist") && box.exists(daemons + "com.vendor.Editor.Agent.plist"))
        #expect(!box.exists(daemons + "com.vendor.Editor.Old.plist"))
    }

    @Test func nothingGoesWhenInstalledAppsCantBeRead() throws {
        let box = try system()
        try FileManager.default.removeItem(atPath: box.path + "/Applications")
        let paths = SystemLeftovers.find(ids: ids, base: box.path).map(\.path)
        let report = SystemLeftovers.remove(paths, appID: "com.vendor.Editor", ids: ids, base: box.path, runner: FakeRunner().runner)
        #expect(report.removed.isEmpty && Set(report.refused) == Set(paths))
    }

    @Test func nothingGoesWhenPartOfTheInstalledAppsCantBeRead() throws {
        // A vendor folder in Applications that can't be read.
        let box = try system()
        try box.folder("Applications/Vendor")
        #expect(chmod(box.path + "/Applications/Vendor", 0) == 0)
        defer { _ = chmod(box.path + "/Applications/Vendor", 0o755) }
        let paths = SystemLeftovers.find(ids: ids, base: box.path).map(\.path)
        #expect(SystemLeftovers.installedOwners(base: box.path) == nil)
        let report = SystemLeftovers.remove(paths, appID: "com.vendor.Editor", ids: ids, base: box.path, runner: FakeRunner().runner)
        #expect(report.removed.isEmpty && Set(report.refused) == Set(paths))

        // An app whose identity can't be read.
        let broken = try system()
        try broken.file("Applications/Editor.app/Contents/Info.plist", Data("not a plist".utf8))
        #expect(SystemLeftovers.installedOwners(base: broken.path) == nil)

        // A user's Applications folder that can't be read.
        let user = try system()
        try user.folder("Users/synthetic/Applications")
        #expect(chmod(user.path + "/Users/synthetic/Applications", 0) == 0)
        defer { _ = chmod(user.path + "/Users/synthetic/Applications", 0o755) }
        #expect(SystemLeftovers.installedOwners(base: user.path) == nil)

        // Folders that simply aren't there, and a folder that isn't a bundle, leave it complete.
        let plain = try system()
        try plain.folder("Users/synthetic")
        try plain.folder("Applications/Notes.app")
        #expect(SystemLeftovers.installedOwners(base: plain.path) == [])
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
    @Test func anUnreadableEmbeddedIdentityRefusesAllSystemRemoval() throws {
        let box = try system()
        try box.file("Applications/Other.app/Contents/Info.plist", try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "org.other.Tool"], format: .xml, options: 0))
        try box.folder("Applications/Other.app/Contents/Helpers")
        let helpers = box.path + "/Applications/Other.app/Contents/Helpers"
        #expect(chmod(helpers, 0) == 0)
        defer { _ = chmod(helpers, 0o755) }
        let wanted = SystemLeftovers.find(ids: ids, base: box.path).map(\.path)
        let fake = FakeRunner()
        #expect(SystemLeftovers.installedOwners(base: box.path) == nil)
        let report = SystemLeftovers.remove(wanted, appID: "com.vendor.Editor", ids: ids, base: box.path, runner: fake.runner)
        #expect(report.removed.isEmpty && Set(report.refused) == Set(wanted))
        #expect(fake.calls.withLock { $0 }.isEmpty)
        #expect(box.exists("Library/PrivilegedHelperTools/com.vendor.Editor.Helper"))
    }

    @Test func brokenEmbeddedMetadataCannotHideAnotherOwner() throws {
        let box = try system()
        try box.file("Applications/Other.app/Contents/Info.plist", try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "org.other.Tool"], format: .xml, options: 0))
        try box.file("Applications/Other.app/Contents/XPCServices/Shared.xpc/Contents/Info.plist", Data("broken".utf8))
        #expect(SystemLeftovers.installedOwners(base: box.path) == nil)
        let wanted = SystemLeftovers.find(ids: ids, base: box.path).map(\.path)
        let report = SystemLeftovers.remove(wanted, appID: "com.vendor.Editor", ids: ids, base: box.path, runner: FakeRunner().runner)
        #expect(report.removed.isEmpty && Set(report.refused) == Set(wanted))
    }

    @Test func anOwnerAppearingWhileTheDaemonStopsKeepsItsFiles() throws {
        let box = try system()
        let base = box.path
        let failed = Mutex(false)
        let runner = CommandRunner(run: { _, _ in
            do {
                for (relative, id) in [
                    ("Applications/Other.app/Contents/Info.plist", "org.other.Tool"),
                    ("Applications/Other.app/Contents/XPCServices/Shared.xpc/Contents/Info.plist", "com.vendor.Editor.Helper"),
                ] {
                    let path = base + "/" + relative
                    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
                        .write(to: URL(fileURLWithPath: path))
                }
            } catch { failed.withLock { $0 = true } }
            return (0, "")
        }, exists: { _ in true })
        let wanted = SystemLeftovers.find(ids: ids, base: box.path).filter { $0.kind == .appPart }.map(\.path)
        let report = SystemLeftovers.remove(wanted, appID: "com.vendor.Editor", ids: ids, base: box.path, runner: runner)
        #expect(!failed.withLock { $0 })
        #expect(report.removed.isEmpty)
        #expect(box.exists("Library/LaunchDaemons/com.vendor.Editor.Helper.plist"))
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

@Suite struct LeftStagingTests {
    @Test func stagingAnEarlierRemovalLeftIsFoundAndNotTouched() throws {
        let box = try Box()
        try box.file("Library/Caches/.mymole-removing/JOB/item")
        try box.folder("Library/Logs")
        let found = SystemCleanRules.leftStaging(at: [box.path + "/Library/Caches", box.path + "/Library/Logs"])
        #expect(found == [box.path + "/Library/Caches/.mymole-removing"])
        #expect(box.exists("Library/Caches/.mymole-removing/JOB/item"))
    }
}
