import Foundation
import Testing

@testable import StorageKit

/// Writes a minimal app bundle with an Info.plist.
func makeApp(_ box: Sandbox, _ rel: String, id: String?, name: String? = nil, bytes: Int = 20_000) throws {
    try box.file(rel + "/Contents/MacOS/bin", bytes: bytes)
    var info: [String: Any] = ["CFBundleShortVersionString": "1.2"]
    if let id { info["CFBundleIdentifier"] = id }
    if let name { info["CFBundleName"] = name }
    try (info as NSDictionary).write(to: box.url.appending(path: rel + "/Contents/Info.plist"))
}

@Suite struct AppFinderTests {
    @Test func findsAppsAndOneLevelOfSubfolders() throws {
        let box = try Sandbox()
        try makeApp(box, "Applications/Editor.app", id: "com.vendor.Editor", name: "Editor", bytes: 60_000)
        try makeApp(box, "Applications/Utilities/Tool.app", id: "com.vendor.Tool")
        try makeApp(box, "Applications/Deep/Deeper/Hidden.app", id: "com.vendor.Hidden")
        try box.file("Applications/readme.txt", bytes: 100)
        try box.file("Applications/Store.app/Contents/_MASReceipt/receipt", bytes: 100)

        let apps = AppFinder.find(in: [box.path + "/Applications"], workers: 2)
        #expect(Set(apps.map(\.name)) == ["Editor", "Tool", "Store"])
        let editor = try #require(apps.first)
        #expect(editor.name == "Editor" && editor.bundleID == "com.vendor.Editor" && editor.version == "1.2")
        #expect(editor.bytes >= box.allocated("Applications/Editor.app/Contents/MacOS/bin"))
        #expect(apps.first { $0.name == "Store" }?.fromAppStore == true)
        #expect(apps.first { $0.name == "Tool" }?.fromAppStore == false)
    }

    @Test func findsAnUninstallerTheAppShips() throws {
        let box = try Sandbox()
        let apps = box.path + "/Applications"
        try makeApp(box, "Applications/Plain.app", id: "com.vendor.Plain")
        try makeApp(box, "Applications/Suite.app", id: "com.vendor.Suite")
        try makeApp(box, "Applications/Suite.app/Contents/Resources/Suite Uninstaller.app", id: "com.vendor.Suite.uninstaller")
        try makeApp(box, "Applications/Vendor Studio/Studio.app", id: "com.vendor.Studio")
        try makeApp(box, "Applications/Vendor Studio/Uninstall Studio.app", id: "com.vendor.Studio.uninstall")
        try makeApp(box, "Applications/Uninstall Other.app", id: "com.other.uninstall")
        func app(_ rel: String) throws -> AppBundle { try #require(AppFinder.read(box.path + "/" + rel)) }

        #expect(AppFinder.ownUninstaller(of: try app("Applications/Suite.app"), folders: [apps])?.hasSuffix("/Suite Uninstaller.app") == true)
        #expect(AppFinder.ownUninstaller(of: try app("Applications/Vendor Studio/Studio.app"), folders: [apps])?.hasSuffix("/Uninstall Studio.app") == true)
        // An uninstaller loose in Applications belongs to no one in particular.
        #expect(AppFinder.ownUninstaller(of: try app("Applications/Plain.app"), folders: [apps]) == nil)
    }

    @Test func onlyReverseDNSBundleIDsAreMatched() {
        #expect(AppLeftovers.isWellFormed("com.vendor.Editor") && AppLeftovers.isWellFormed("org.vendor-name.App_2"))
        for id in ["", "Editor", "com..Editor", ".com.vendor", "com.vendor.", "com.vendor/Editor", "com.vendor.Ed itor"] {
            #expect(!AppLeftovers.isWellFormed(id), "\(id)")
        }
    }

    @Test func macOSAppsAreProtected() {
        #expect(AppBundle(path: "/Applications/Safari.app", name: "Safari", bundleID: "com.apple.Safari", version: nil, bytes: 0, fromAppStore: false).isProtected)
        #expect(!AppBundle(path: "/Applications/X.app", name: "X", bundleID: "com.vendor.X", version: nil, bytes: 0, fromAppStore: false).isProtected)
    }
}

@Suite struct AppLeftoverTests {
    private let editor = AppBundle(
        path: "/synthetic/Applications/Editor.app", name: "Editor", bundleID: "com.vendor.Editor", version: nil, bytes: 1,
        fromAppStore: false)

    private func home() throws -> Sandbox {
        let box = try Sandbox()
        for rel in [
            "Library/Application Support/com.vendor.Editor/state", "Library/Application Support/Editor/db",
            "Library/Application Support/Vendor/shared", "Library/Caches/com.vendor.Editor/c",
            "Library/Caches/com.vendor.EditorPro/c", "Library/Containers/com.vendor.Editor/Data/x",
            "Library/Group Containers/ABCDE12345.com.vendor.Editor/x", "Library/Group Containers/group.com.vendor.Editor/x",
            "Library/Group Containers/group.com.vendor.shared/x", "Library/Preferences/com.vendor.Editor.plist",
            "Library/Preferences/com.vendor.EditorPro.plist", "Library/Preferences/ByHost/com.vendor.Editor.0A1B.plist",
            "Library/Saved Application State/com.vendor.Editor.savedState/w", "Library/Logs/Editor/log",
            "Library/HTTPStorages/com.vendor.Editor.binarycookies", "Library/LaunchAgents/com.vendor.Editor.helper.plist",
        ] {
            try box.file(rel, bytes: 1_000)
        }
        return box
    }

    @Test func findsWhatTheAppLeftAndNothingShared() throws {
        let box = try home()
        let found = AppLeftovers.find(for: editor, home: box.path, installed: [editor])
        let rel = Set(found.map { String($0.path.dropFirst(box.path.count + "/Library/".count)) })
        #expect(rel == [
            "Application Support/com.vendor.Editor", "Application Support/Editor", "Caches/com.vendor.Editor",
            "Containers/com.vendor.Editor", "Group Containers/ABCDE12345.com.vendor.Editor",
            "Group Containers/group.com.vendor.Editor", "Preferences/com.vendor.Editor.plist",
            "Preferences/ByHost/com.vendor.Editor.0A1B.plist", "Saved Application State/com.vendor.Editor.savedState",
            "Logs/Editor", "HTTPStorages/com.vendor.Editor.binarycookies", "LaunchAgents/com.vendor.Editor.helper.plist",
        ])
        #expect(found.first { $0.path.hasSuffix("/Preferences/com.vendor.Editor.plist") }?.place == "Preferences")
    }

    @Test func anotherCopyOrNameTwinHoldsBack() throws {
        let box = try home()
        let copy = AppBundle(path: "/synthetic/Other/Editor.app", name: "Editor", bundleID: "com.vendor.Editor", version: nil, bytes: 1, fromAppStore: false)
        #expect(AppLeftovers.find(for: editor, home: box.path, installed: [editor, copy]).isEmpty)

        let twin = AppBundle(path: "/synthetic/Other/Editor 2.app", name: "Editor", bundleID: "org.other.Editor", version: nil, bytes: 1, fromAppStore: false)
        let found = AppLeftovers.find(for: editor, home: box.path, installed: [editor, twin])
        #expect(!found.contains { $0.path.hasSuffix("/Application Support/Editor") })
        #expect(found.contains { $0.path.hasSuffix("/Application Support/com.vendor.Editor") })
    }

    @Test func isCheckedAgainBeforeTheTrash() throws {
        let box = try home()
        let lib = box.path + "/Library"
        #expect(AppLeftovers.isStillLeftover(lib + "/Caches/com.vendor.Editor", of: editor, home: box.path, installed: [editor]))
        #expect(!AppLeftovers.isStillLeftover(lib + "/Caches/com.vendor.EditorPro", of: editor, home: box.path, installed: [editor]))
        #expect(!AppLeftovers.isStillLeftover(lib + "/Application Support/Vendor", of: editor, home: box.path, installed: [editor]))
        #expect(!AppLeftovers.isStillLeftover(lib + "/Caches/../Caches/com.vendor.Editor", of: editor, home: box.path, installed: [editor]))
        #expect(!AppLeftovers.isStillLeftover(box.path + "/Documents/com.vendor.Editor", of: editor, home: box.path, installed: [editor]))
        try FileManager.default.removeItem(atPath: lib + "/Caches/com.vendor.Editor")
        try FileManager.default.createSymbolicLink(atPath: lib + "/Caches/com.vendor.Editor", withDestinationPath: box.path)
        #expect(!AppLeftovers.isStillLeftover(lib + "/Caches/com.vendor.Editor", of: editor, home: box.path, installed: [editor]))
    }

    @Test func onlyCachesAndAppPartsStartChosen() throws {
        let box = try home()
        let found = AppLeftovers.find(for: editor, home: box.path, installed: [editor])
        let chosen = Set(found.filter(\.kind.chosenByDefault).map { String($0.path.dropFirst(box.path.count + "/Library/".count)) })
        #expect(chosen == [
            "Caches/com.vendor.Editor", "Saved Application State/com.vendor.Editor.savedState", "Logs/Editor",
            "HTTPStorages/com.vendor.Editor.binarycookies", "LaunchAgents/com.vendor.Editor.helper.plist",
        ])
        #expect(found.first { $0.place == "Group Containers" }?.kind == .shared)
        #expect(found.first { $0.place == "Containers" }?.kind == .data)
        #expect(found.first { $0.place == "Preferences" }?.kind == .settings)
    }

    @Test func findsWhereSettingsNameTheApp() throws {
        let box = try Sandbox()
        try Data("export PATH=$PATH\nalias ed='/synthetic/Applications/Editor.app/Contents/MacOS/bin'\n".utf8)
            .write(to: box.url.appending(path: ".zshrc"))
        try FileManager.default.createDirectory(at: box.url.appending(path: ".cursor"), withIntermediateDirectories: true)
        try Data("{\n  \"servers\": {\n    \"ed\": { \"app\": \"com.vendor.Editor\" }\n  }\n}\n".utf8)
            .write(to: box.url.appending(path: ".cursor/mcp.json"))
        try Data("Editor is nice\n".utf8).write(to: box.url.appending(path: ".bashrc"))
        let found = AppMentions.find(for: editor, home: box.path)
        #expect(found == [
            AppMention(file: box.path + "/.zshrc", line: 2), AppMention(file: box.path + "/.cursor/mcp.json", line: 3),
        ])
    }

    @Test func aLooseBundleIDFindsNothing() throws {
        let box = try home()
        try box.file("Library/Caches/Editor/c", bytes: 1_000)
        let loose = AppBundle(path: "/synthetic/Applications/Editor.app", name: "Editor", bundleID: "Editor", version: nil, bytes: 1, fromAppStore: false)
        #expect(AppLeftovers.find(for: loose, home: box.path, installed: [loose]).isEmpty)
    }

    @Test func libraryFolderSwappedForALinkIsRefused() throws {
        let box = try home()
        let lib = box.path + "/Library"
        try box.file("Elsewhere/com.vendor.Editor/mine", bytes: 1_000)
        try FileManager.default.removeItem(atPath: lib + "/Caches")
        try FileManager.default.createSymbolicLink(atPath: lib + "/Caches", withDestinationPath: box.path + "/Elsewhere")
        #expect(!AppLeftovers.isStillLeftover(lib + "/Caches/com.vendor.Editor", of: editor, home: box.path, installed: [editor]))
    }

    @Test func longerBundleIDOfAnInstalledAppKeepsItsData() throws {
        let box = try home()
        let lib = box.path + "/Library"
        for rel in [
            "HTTPStorages/com.vendor.Editor.Pro", "Preferences/ByHost/com.vendor.Editor.Pro.0A1B.plist",
            "Saved Application State/com.vendor.Editor.Pro.savedState/w", "Cookies/com.vendor.Editor.Pro.binarycookies",
            "LaunchAgents/com.vendor.Editor.Pro.agent.plist", "Group Containers/group.com.vendor.Editor.Pro/x",
        ] {
            try box.file("Library/" + rel, bytes: 1_000)
        }
        let pro = AppBundle(
            path: "/synthetic/Applications/Editor Pro.app", name: "Editor Pro", bundleID: "com.vendor.Editor.Pro",
            version: nil, bytes: 1, fromAppStore: false)

        let found = AppLeftovers.find(for: editor, home: box.path, installed: [editor, pro])
        #expect(!found.contains { $0.path.contains("com.vendor.Editor.Pro") })
        #expect(found.contains { $0.path.hasSuffix("/HTTPStorages/com.vendor.Editor.binarycookies") })
        #expect(found.contains { $0.path.hasSuffix("/LaunchAgents/com.vendor.Editor.helper.plist") })
        #expect(!AppLeftovers.isStillLeftover(lib + "/HTTPStorages/com.vendor.Editor.Pro", of: editor, home: box.path, installed: [editor, pro]))

        // Without Pro installed, its data is Editor's to offer.
        let alone = AppLeftovers.find(for: editor, home: box.path, installed: [editor])
        #expect(alone.contains { $0.path.hasSuffix("/HTTPStorages/com.vendor.Editor.Pro") })
    }

    @Test func checkAgainRefusesWhatAnotherCopyOrTwinNowUses() throws {
        let box = try home()
        let lib = box.path + "/Library"
        let copy = AppBundle(path: "/synthetic/Other/Editor.app", name: "Editor", bundleID: "com.vendor.Editor", version: nil, bytes: 1, fromAppStore: false)
        #expect(!AppLeftovers.isStillLeftover(lib + "/Caches/com.vendor.Editor", of: editor, home: box.path, installed: [editor, copy]))
        let twin = AppBundle(path: "/synthetic/Other/Editor 2.app", name: "Editor", bundleID: "org.other.Editor", version: nil, bytes: 1, fromAppStore: false)
        #expect(!AppLeftovers.isStillLeftover(lib + "/Application Support/Editor", of: editor, home: box.path, installed: [editor, twin]))
        #expect(AppLeftovers.isStillLeftover(lib + "/Application Support/com.vendor.Editor", of: editor, home: box.path, installed: [editor, twin]))
    }
}

/// Spotlight's answer is faked: the query, its output and its failures.
@Suite struct AppSiblingsTests {
    final class Calls: @unchecked Sendable { var args: [[String]] = [] }

    func runner(code: Int32 = 0, output: String, calls: Calls = Calls()) -> CommandRunner {
        CommandRunner(run: { _, a in calls.args.append(a); return (code, output) }, exists: { _ in true })
    }

    let app = AppBundle(path: "/Applications/App.app", name: "App", bundleID: "com.vendor.App", version: nil, bytes: 0, fromAppStore: false)

    @Test func findsEditionsElsewhereByTheirOwnID() throws {
        let box = try Sandbox()
        let pro = box.path + "/Volumes/External/App Pro.app"
        try box.file("Volumes/External/App Pro.app/Contents/MacOS/bin", bytes: 1)
        let info: NSDictionary = ["CFBundleIdentifier": "com.vendor.App.Pro"]
        #expect(info.write(toFile: pro + "/Contents/Info.plist", atomically: true))
        let unreadable = box.path + "/Volumes/Other/App.app"
        let calls = Calls()
        let output = [app.path, pro, unreadable, box.path + "/.Trash/App.app", "relative/App.app"].joined(separator: "\0") + "\0"
        let found = try #require(AppSiblings.find(for: app, runner: runner(output: output, calls: calls)))
        #expect(found.map(\.path) == [pro, unreadable])
        #expect(found.map(\.bundleID) == ["com.vendor.App.Pro", "com.vendor.App"])
        let query = try #require(calls.args.first?.last)
        #expect(query.contains("kMDItemCFBundleIdentifier == \"com.vendor.App*\"c"))
        #expect(calls.args.first?.first == "-0")
    }

    @Test func aFailedOrStuckLookupIsNoAnswer() {
        #expect(AppSiblings.find(for: app, runner: runner(code: 1, output: "")) == nil)
        #expect(AppSiblings.find(for: app, runner: runner(code: CommandRunner.timedOut, output: "")) == nil)
        let missing = CommandRunner(run: { _, _ in (0, "") }, exists: { _ in false })
        #expect(AppSiblings.find(for: app, runner: missing) == nil)
        #expect(AppSiblings.find(for: app, runner: runner(output: "")) == [])
    }

    @Test func anIDThatCouldBendTheQueryIsNeverAsked() {
        let calls = Calls()
        for id in ["com.vendor.App\" || true || \"", "com.vendor.*", "single"] {
            let odd = AppBundle(path: "/Applications/X.app", name: "X", bundleID: id, version: nil, bytes: 0, fromAppStore: false)
            #expect(AppSiblings.find(for: odd, runner: runner(output: "", calls: calls)) == nil)
        }
        #expect(calls.args.isEmpty)
    }
}

/// What an app carries, read from its bundle, and the leftovers it ties in.
@Suite struct AppIdentityTests {
    func app(_ box: Sandbox) -> AppBundle {
        AppBundle(path: box.path + "/Applications/Editor.app", name: "Editor", bundleID: "com.vendor.Editor", version: nil, bytes: 0, fromAppStore: false)
    }

    @Test func readsHelpersInTheVendorsOwnNamespace() throws {
        let box = try Sandbox()
        try makeApp(box, "Applications/Editor.app", id: "com.vendor.Editor")
        try makeApp(box, "Applications/Editor.app/Contents/Library/LoginItems/Launcher.app", id: "com.vendor.EditorLauncher")
        try box.file("Applications/Editor.app/Contents/Library/LaunchServices/com.vendor.Editor.PrivilegedHelper", bytes: 10)
        try makeApp(box, "Applications/Editor.app/Contents/XPCServices/Renderer.xpc", id: "com.vendor.Editor.Renderer")
        // An updater framework's service is shared by many apps: not this one's.
        try makeApp(box, "Applications/Editor.app/Contents/XPCServices/Installer.xpc", id: "org.updater-project.Installer")
        try makeApp(box, "Applications/Editor.app/Contents/PlugIns/Share.appex", id: "com.apple.share.Thing")
        let jobs = box.url.appending(path: "Applications/Editor.app/Contents/Library/LaunchDaemons")
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try (["Label": "com.vendor.editord"] as NSDictionary).write(to: jobs.appending(path: "com.vendor.editord.plist"))

        let identity = AppIdentity.of(app(box))
        #expect(identity.helperIDs == ["com.vendor.Editor.PrivilegedHelper", "com.vendor.Editor.Renderer", "com.vendor.EditorLauncher", "com.vendor.editord"])
        #expect(identity.groups.isEmpty)
    }

    @Test func helperAndGroupLeftoversAreTiedIn() throws {
        let box = try Sandbox()
        let me = app(box)
        try box.file("Library/Application Support/com.vendor.EditorLauncher/state", bytes: 100)
        try box.file("Library/Caches/com.vendor.Editor.Renderer/c", bytes: 100)
        try box.file("Library/Group Containers/ABCDE12345.com.vendor.shared/db", bytes: 100)
        try box.file("Library/Group Containers/ABCDE12345.com.vendor.other/db", bytes: 100)
        try box.file("Library/Application Support/com.vendor.Unrelated/x", bytes: 100)
        let identity = AppIdentity(helperIDs: ["com.vendor.EditorLauncher", "com.vendor.Editor.Renderer"], groups: ["ABCDE12345.com.vendor.shared"])
        let found = AppLeftovers.find(for: me, home: box.path, installed: [me], identity: identity)
        #expect(Set(found.map(\.name)) == ["com.vendor.EditorLauncher", "com.vendor.Editor.Renderer", "ABCDE12345.com.vendor.shared"])
        #expect(found.first { $0.name == "ABCDE12345.com.vendor.shared" }?.kind == .shared)
        // Without the identity, only the app's own ID and name count.
        #expect(AppLeftovers.find(for: me, home: box.path, installed: [me]).isEmpty)
        for l in found {
            #expect(AppLeftovers.isStillLeftover(l.path, of: me, home: box.path, installed: [me], identity: identity), "\(l.path)")
        }
    }

    @Test func aHelperIDThatIsAnInstalledAppStaysThatApps() throws {
        let box = try Sandbox()
        let me = app(box)
        let launcher = AppBundle(path: "/synthetic/Launcher.app", name: "Launcher", bundleID: "com.vendor.EditorLauncher", version: nil, bytes: 0, fromAppStore: false)
        try box.file("Library/Application Support/com.vendor.EditorLauncher/state", bytes: 100)
        let identity = AppIdentity(helperIDs: ["com.vendor.EditorLauncher"])
        #expect(AppLeftovers.find(for: me, home: box.path, installed: [me, launcher], identity: identity).isEmpty)
    }

    @Test func groupIDsAreReadStrictly() {
        #expect(AppIdentity.isGroupID("group.com.vendor.Shared"))
        #expect(AppIdentity.isGroupID("ABCDE12345.com.vendor.Shared"))
        #expect(!AppIdentity.isGroupID("ABCDE.com.vendor.Shared"))
        #expect(!AppIdentity.isGroupID("group."))
        #expect(!AppIdentity.isGroupID("shared"))
        #expect(AppIdentity.namespace(of: "com.vendor.Editor") == "com.vendor.")
        #expect(AppIdentity.namespace(of: "vendor.Editor") == nil)
    }
}
