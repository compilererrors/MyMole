import Darwin
import Foundation
import Testing

@testable import StorageKit

/// Crash reports, recent-document lists, Finder locks and disk images, in
/// folders of the test's own.
@Suite struct UninstallExtrasTests {
    let editor = AppBundle(
        path: "/synthetic/Applications/Editor.app", name: "Editor", bundleID: "com.vendor.Editor", version: nil, bytes: 1,
        fromAppStore: false)

    @Test func crashReportsRecentListsAndScriptGroupsAreTheApps() throws {
        let box = try Sandbox()
        for rel in [
            "Library/Logs/DiagnosticReports/Editor-2026-11-06-101112.ips", "Library/Logs/DiagnosticReports/Editor_2026-11-06.crash",
            "Library/Logs/DiagnosticReports/EditorPro-2026-11-06-101112.ips", "Library/Logs/DiagnosticReports/Editor-notes.txt",
            "Library/Application Support/CrashReporter/Editor_0A1B2C3D.plist",
            "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.vendor.editor.sfl3",
            "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.vendor.editorpro.sfl3",
            "Library/Application Scripts/ABCDE12345.com.vendor.Editor/s", "Library/Application Scripts/group.com.vendor.Editor/s",
        ] {
            try box.file(rel, bytes: 500)
        }
        let found = AppLeftovers.find(for: editor, home: box.path, installed: [editor])
        let rel = Set(found.map { String($0.path.dropFirst(box.path.count + "/Library/".count)) })
        #expect(rel == [
            "Logs/DiagnosticReports/Editor-2026-11-06-101112.ips", "Logs/DiagnosticReports/Editor_2026-11-06.crash",
            "Application Support/CrashReporter/Editor_0A1B2C3D.plist",
            "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.vendor.editor.sfl3",
            "Application Scripts/ABCDE12345.com.vendor.Editor", "Application Scripts/group.com.vendor.Editor",
        ])
        // Reports and lists are rebuilt: they start chosen.
        #expect(found.filter { !$0.place.hasPrefix("Application Scripts") }.allSatisfy { $0.kind == .rebuildable })
        for l in found { #expect(AppLeftovers.isStillLeftover(l.path, of: editor, home: box.path, installed: [editor])) }
    }

    @Test func aNameAnotherAppHasMatchesNoReports() throws {
        let box = try Sandbox()
        try box.file("Library/Logs/DiagnosticReports/Editor-2026-11-06-101112.ips", bytes: 500)
        let twin = AppBundle(path: "/synthetic/Other/Editor.app", name: "Editor", bundleID: "com.other.Editor", version: nil, bytes: 1, fromAppStore: false)
        #expect(AppLeftovers.find(for: editor, home: box.path, installed: [editor, twin]).isEmpty)
    }

    @Test func aMacOSAppsCachesAndSettingsAreFoundButNeverItsData() throws {
        let box = try Sandbox()
        for rel in [
            "Library/Caches/com.apple.Safari/c", "Library/Preferences/com.apple.Safari.plist",
            "Library/Containers/com.apple.Safari/Data/x", "Library/Application Support/com.apple.Safari/db",
            "Library/Group Containers/group.com.apple.Safari/x",
        ] {
            try box.file(rel, bytes: 500)
        }
        let safari = AppBundle(path: "/Applications/Safari.app", name: "Safari", bundleID: "com.apple.Safari", version: nil, bytes: 1, fromAppStore: false)
        #expect(safari.isProtected)
        let found = AppLeftovers.find(for: safari, home: box.path, installed: [safari])
        #expect(Set(found.map(\.place)) == ["Caches", "Preferences"])
        let data = box.path + "/Library/Containers/com.apple.Safari"
        #expect(!AppLeftovers.isStillLeftover(data, of: safari, home: box.path, installed: [safari]))
    }

    @Test func aLockedItemIsUnlockedToMoveAndLockedAgainWhenItStays() throws {
        let box = try Sandbox()
        try box.folder("Bin")
        let locked = try box.file("Library/Caches/com.vendor.Editor/c", bytes: 500).path
        let folder = (locked as NSString).deletingLastPathComponent
        #expect(chflags(folder, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(folder, 0) }
        #expect(Locks.isLocked(folder))
        // A plain move fails on the lock; the unlocking one moves it, unlocked.
        let bin = TrashBackend.folder(box.path + "/Bin")
        #expect(bin.moveOne(folder).trashed == nil)
        let moved = try #require(bin.unlockingLocked().moveOne(folder).trashed)
        #expect(!Locks.isLocked(moved.path))
        _ = chflags(moved.path, 0)

        // A move that fails anyway leaves the item locked as it was.
        let other = try box.file("Library/Logs/x.log", bytes: 10).path
        #expect(chflags(other, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(other, 0) }
        let nowhere = TrashBackend { _ in (nil, "No room") }.unlockingLocked()
        #expect(nowhere.moveOne(other).trashed == nil)
        #expect(Locks.isLocked(other))
    }

    @Test func theImageAnAppRunsFromIsFoundByItsMountPoint() {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>images</key><array>
            <dict><key>image-path</key><string>/Users/synthetic/Downloads/Editor.dmg</string>
            <key>system-entities</key><array>
            <dict><key>dev-entry</key><string>/dev/disk9</string></dict>
            <dict><key>dev-entry</key><string>/dev/disk9s1</string><key>mount-point</key><string>/Volumes/Editor</string></dict>
            </array></dict>
            <dict><key>image-path</key><string>/Users/synthetic/Downloads/Editor 2.dmg</string>
            <key>system-entities</key><array>
            <dict><key>mount-point</key><string>/Volumes/Editor 1</string></dict></array></dict>
            </array></dict></plist>
            """
        let runner = CommandRunner(run: { _, args in args == ["info", "-plist"] ? (0, plist) : (1, "") }, exists: { _ in true })
        let found = DiskImages.image(holding: "/Volumes/Editor/Editor.app", runner: runner)
        #expect(found == MountedImage(image: "/Users/synthetic/Downloads/Editor.dmg", mountPoint: "/Volumes/Editor"))
        // "/Volumes/Editor 1" isn't inside "/Volumes/Editor".
        #expect(DiskImages.image(holding: "/Volumes/Editor 1/Editor.app", runner: runner)?.name == "Editor 2.dmg")
        #expect(DiskImages.image(holding: "/Applications/Editor.app", runner: runner) == nil)
        let failing = CommandRunner(run: { _, _ in (1, "") }, exists: { _ in true })
        #expect(DiskImages.image(holding: "/Volumes/Editor/Editor.app", runner: failing) == nil)
    }

    @Test func onlyADiskImageFileMayGo() throws {
        let box = try Sandbox()
        let dmg = try box.file("Downloads/Editor.dmg", bytes: 500).path
        let text = try box.file("Downloads/Editor.txt", bytes: 500).path
        #expect(DiskImages.mayGo(dmg, home: box.path))
        #expect(!DiskImages.mayGo(text, home: box.path))
        #expect(!DiskImages.mayGo(box.path + "/Downloads/Gone.dmg", home: box.path))
    }

    @Test func eachLeftoverSaysHowItsTiedAndANameAloneIsNeverChosen() throws {
        let box = try Sandbox()
        for rel in [
            "Library/Caches/com.vendor.Editor/c", "Library/Logs/Editor/log", "Library/Logs/DiagnosticReports/Editor-2026-11-06.ips",
            "Library/Caches/com.vendor.Editor.Helper/c", "Library/Group Containers/TEAMID1234.shared.editor/x",
        ] {
            try box.file(rel, bytes: 500)
        }
        let identity = AppIdentity(helperIDs: ["com.vendor.Editor.Helper"], groups: ["TEAMID1234.shared.editor"])
        let found = AppLeftovers.find(for: editor, home: box.path, installed: [editor], identity: identity)
        let by = Dictionary(uniqueKeysWithValues: found.map { (String($0.path.dropFirst(box.path.count + "/Library/".count)), $0) })
        #expect(by["Caches/com.vendor.Editor"]?.evidence == .bundleID && by["Caches/com.vendor.Editor"]?.chosenByDefault == true)
        #expect(by["Caches/com.vendor.Editor.Helper"]?.evidence == .helper)
        #expect(by["Group Containers/TEAMID1234.shared.editor"]?.evidence == .group)
        #expect(by["Logs/Editor"]?.evidence == .name && by["Logs/Editor"]?.chosenByDefault == false)
        #expect(by["Logs/DiagnosticReports/Editor-2026-11-06.ips"]?.evidence == .name)
    }

    private let chrome = AppBundle(
        path: "/synthetic/Applications/Google Chrome.app", name: "Google Chrome", bundleID: "com.google.Chrome", version: nil, bytes: 1,
        fromAppStore: false)

    @Test func chromesFoldersInGooglesFolderAndGooglesSharedFilesAreFound() throws {
        let box = try Sandbox()
        for rel in [
            "Library/Application Support/Google/Chrome/Default/Bookmarks", "Library/Caches/Google/Chrome/Default/Cache/a",
            "Library/Application Support/Google/Earth/x", "Library/Google/GoogleSoftwareUpdate/Actives/x",
            "Library/LaunchAgents/com.google.keystone.agent.plist", "Library/Caches/com.google.SoftwareUpdate/x",
            "Library/Preferences/com.google.Chrome.plist",
        ] {
            try box.file(rel, bytes: 500)
        }
        let found = AppLeftovers.find(for: chrome, home: box.path, installed: [chrome])
        let by = Dictionary(uniqueKeysWithValues: found.map { (String($0.path.dropFirst(box.path.count + "/Library/".count)), $0) })
        // The profile: Chrome's own, in Google's folder; data, so not chosen. Its cache is.
        #expect(by["Application Support/Google/Chrome"]?.evidence == .vendorFolder && by["Application Support/Google/Chrome"]?.chosenByDefault == false)
        #expect(by["Caches/Google/Chrome"]?.chosenByDefault == true)
        // Another Google product's folder is never Chrome's.
        #expect(by["Application Support/Google/Earth"] == nil)
        // Google's updater, for the last Google app: offered, never chosen.
        #expect(by["LaunchAgents/com.google.keystone.agent.plist"]?.evidence == .vendor)
        #expect(by["LaunchAgents/com.google.keystone.agent.plist"]?.chosenByDefault == false)
        #expect(by["Google"]?.evidence == .vendor && by["Caches/com.google.SoftwareUpdate"] != nil)
        #expect(by["Preferences/com.google.Chrome.plist"]?.evidence == .bundleID)
        for l in found { #expect(AppLeftovers.isStillLeftover(l.path, of: chrome, home: box.path, installed: [chrome])) }

        // Another Google app still installed: what's Google's stays out.
        let drive = AppBundle(path: "/synthetic/Applications/Google Drive.app", name: "Google Drive", bundleID: "com.google.drivefs", version: nil, bytes: 1, fromAppStore: false)
        let withDrive = AppLeftovers.find(for: chrome, home: box.path, installed: [chrome, drive])
        #expect(!withDrive.contains { $0.evidence == .vendor })
        #expect(withDrive.contains { $0.path.hasSuffix("Application Support/Google/Chrome") })
        #expect(!AppLeftovers.isStillLeftover(box.path + "/Library/LaunchAgents/com.google.keystone.agent.plist", of: chrome, home: box.path, installed: [chrome, drive]))
    }
}
