import Foundation
import Testing

@testable import StorageKit

/// Launch agents and daemons in folders of the test's own.
@Suite struct StartupItemsTests {
    private func plist(_ dict: [String: Any], _ box: Sandbox, _ rel: String) throws {
        let path = box.path + "/" + rel
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
    }

    private func setUp() throws -> (box: Sandbox, home: String, root: String) {
        let box = try Sandbox()
        try box.file("root/Applications/Notes Helper.app/Contents/MacOS/helper", bytes: 100)
        let helper = box.path + "/root/Applications/Notes Helper.app/Contents/MacOS/helper"
        try plist(["Label": "com.vendor.notes.helper", "Program": helper, "RunAtLoad": true, "KeepAlive": true], box, "home/Library/LaunchAgents/com.vendor.notes.helper.plist")
        try plist(["Label": "com.vendor.gone", "ProgramArguments": ["/opt/vendor/bin/gone-tool", "--daemon"], "StartInterval": 3600], box, "home/Library/LaunchAgents/com.vendor.gone.plist")
        try plist(["ProgramArguments": ["sh", "-c", "true"], "Disabled": true], box, "home/Library/LaunchAgents/local.script.plist")
        try box.file("home/Library/LaunchAgents/notes.txt", bytes: 10)
        try box.file("home/Library/LaunchAgents/broken.plist", bytes: 40)
        try plist(["Label": "com.vendor.updater", "Program": helper, "RunAtLoad": true], box, "root/Library/LaunchAgents/com.vendor.updater.plist")
        try plist(["Label": "com.vendor.daemon", "Program": helper, "KeepAlive": ["SuccessfulExit": false]], box, "root/Library/LaunchDaemons/com.vendor.daemon.plist")
        return (box, box.path + "/home", box.path + "/root")
    }

    @Test func listsTheJobsWithWhatTheyRunAndWhen() throws {
        let (box, home, root) = try setUp()
        _ = box
        let listing = StartupItems.list(home: home, root: root)
        #expect(listing.unreadable.isEmpty)
        // The user's own first, then by label; what isn't a job's list is left out.
        #expect(listing.items.map(\.label) == ["com.vendor.gone", "com.vendor.notes.helper", "local.script", "com.vendor.updater", "com.vendor.daemon"])
        #expect(listing.items.map(\.scope) == [.user, .user, .user, .everyUser, .system])

        let helper = try #require(listing.items.first { $0.label == "com.vendor.notes.helper" })
        #expect(helper.app == "Notes Helper" && !helper.programMissing && helper.runsAtLoad && helper.keepsAlive)
        #expect(helper.summary == "Starts at login · stays running")

        let gone = try #require(listing.items.first { $0.label == "com.vendor.gone" })
        #expect(gone.programMissing && gone.scheduled && gone.program == "/opt/vendor/bin/gone-tool" && gone.app == nil)

        // No label of its own: its file's name. A bare command isn't called missing.
        let script = try #require(listing.items.first { $0.label == "local.script" })
        #expect(script.disabled && !script.programMissing && script.summary.hasPrefix("Turned off"))

        let daemon = try #require(listing.items.first { $0.scope == .system })
        #expect(daemon.keepsAlive && daemon.summary == "stays running")
    }

    @Test func onlyTheUsersOwnAgentsMayGoToTheTrash() throws {
        let (box, home, root) = try setUp()
        #expect(StartupItems.isStillRemovable(home + "/Library/LaunchAgents/com.vendor.gone.plist", home: home))
        #expect(!StartupItems.isStillRemovable(root + "/Library/LaunchAgents/com.vendor.updater.plist", home: home))
        #expect(!StartupItems.isStillRemovable(root + "/Library/LaunchDaemons/com.vendor.daemon.plist", home: home))
        #expect(!StartupItems.isStillRemovable(home + "/Library/LaunchAgents/notes.txt", home: home))
        #expect(!StartupItems.isStillRemovable(home + "/Library/LaunchAgents/missing.plist", home: home))
        #expect(!StartupItems.isStillRemovable(home + "/Library/LaunchAgents/sub/x.plist", home: home))
        #expect(!StartupItems.isStillRemovable(home + "/Library/LaunchAgents/../LaunchAgents/com.vendor.gone.plist", home: home))

        // A link in the folder is neither listed nor removable.
        try FileManager.default.createSymbolicLink(atPath: home + "/Library/LaunchAgents/linked.plist", withDestinationPath: root + "/Library/LaunchDaemons/com.vendor.daemon.plist")
        #expect(!StartupItems.isStillRemovable(home + "/Library/LaunchAgents/linked.plist", home: home))
        #expect(!StartupItems.list(home: home, root: root).items.contains { $0.path.hasSuffix("linked.plist") })
        _ = box
    }

    @Test func aJobListThatDoesntReadAsOneIsSaidAndALinkIsNot() throws {
        let (box, home, root) = try setUp()
        try FileManager.default.createSymbolicLink(atPath: home + "/Library/LaunchAgents/elsewhere.plist", withDestinationPath: home + "/Library/LaunchAgents/notes.txt")
        let listing = StartupItems.list(home: home, root: root)
        #expect(listing.broken == [home + "/Library/LaunchAgents/broken.plist"])
        #expect(!listing.items.contains { $0.path.hasSuffix("broken.plist") })
        _ = box
    }

    @Test func aFolderThatIsNotThereIsNotAProblem() throws {
        let box = try Sandbox()
        let listing = StartupItems.list(home: box.path + "/home", root: box.path + "/root")
        #expect(listing.items.isEmpty && listing.unreadable.isEmpty)
    }
}

/// Plug-ins in a Library and a system folder of the test's own.
@Suite struct PluginsTests {
    @Test func listsPluginsByKindAndOnlyTheUsersOwnCanGo() throws {
        let box = try Sandbox()
        let home = box.path + "/home", root = box.path + "/root"
        try box.file("home/Library/QuickLook/Markdown.qlgenerator/Contents/MacOS/x", bytes: 4_000)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Markdown QL", "CFBundleIdentifier": "com.vendor.ql"], format: .xml, options: 0)
            .write(to: box.url.appending(path: "home/Library/QuickLook/Markdown.qlgenerator/Contents/Info.plist"))
        try box.file("home/Library/Audio/Plug-Ins/Components/Synth.component/Contents/MacOS/y", bytes: 4_000)
        try box.file("home/Library/Services/Resize.workflow/Contents/document.wflow", bytes: 2_000)
        try box.file("home/Library/QuickLook/notes.txt", bytes: 100)
        try box.file("root/Library/Spotlight/Archive.mdimporter/Contents/MacOS/z", bytes: 4_000)

        let listing = Plugins.list(home: home, root: root)
        let byName = Dictionary(uniqueKeysWithValues: listing.items.map { ($0.label, $0) })
        #expect(Set(byName.keys) == ["Markdown QL", "Synth", "Resize", "Archive"])
        #expect(byName["Markdown QL"]?.plugin == .quickLook && byName["Markdown QL"]?.program == "com.vendor.ql")
        #expect(byName["Synth"]?.plugin == .audioUnit && byName["Resize"]?.plugin == .service)
        #expect(byName["Archive"]?.scope == .everyUser && byName["Markdown QL"]?.scope == .user)
        #expect((byName["Synth"]?.bytes ?? 0) >= 4_000)

        #expect(Plugins.isStillRemovable(home + "/Library/QuickLook/Markdown.qlgenerator", home: home))
        // Not the kind's ending, not the user's own, or not directly in the folder.
        #expect(!Plugins.isStillRemovable(home + "/Library/QuickLook/notes.txt", home: home))
        #expect(!Plugins.isStillRemovable(root + "/Library/Spotlight/Archive.mdimporter", home: home))
        #expect(!Plugins.isStillRemovable(home + "/Library/QuickLook/Markdown.qlgenerator/Contents", home: home))
    }
}

@Suite struct LaunchdStatusTests {
    @Test func runningLoadedAndAbsentJobsAreToldApart() {
        let out = "PID\tStatus\tLabel\n412\t0\tcom.vendor.notes.helper\n-\t0\tcom.vendor.gone\n"
        let runner = CommandRunner(run: { _, args in args == ["list"] ? (0, out) : (1, "") }, exists: { _ in true })
        let live = LaunchdStatus.loaded(runner: runner)
        #expect(live?["com.vendor.notes.helper"] == .running(pid: 412))
        #expect(live?["com.vendor.gone"] == .loaded)
        #expect(live?["local.script"] == nil)
        #expect(LaunchdStatus.loaded(runner: CommandRunner(run: { _, _ in (1, "") }, exists: { _ in true })) == nil)
    }

    @Test func aStoppedPluginListingReadsNothingMore() throws {
        let box = try Sandbox()
        try box.file("home/Library/QuickLook/A.qlgenerator/Contents/MacOS/a", bytes: 100)
        let stopped = ScanProgress()
        stopped.cancel()
        #expect(Plugins.list(home: box.path + "/home", root: box.path + "/root", progress: stopped).items.isEmpty)
        #expect(!Plugins.list(home: box.path + "/home", root: box.path + "/root").items.isEmpty)
    }
}
