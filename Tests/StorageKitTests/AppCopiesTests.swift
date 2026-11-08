import Darwin
import Foundation
import Synchronization
import Testing

@testable import StorageKit

@Suite struct AppCopiesTests {
    private func app(_ box: Sandbox, _ path: String, id: String = "com.example.Editor", name: String = "Editor", version: String = "1.0", build: String = "100", extra: [String: Any] = [:]) throws -> String {
        try box.folder(path + "/Contents")
        var info = extra
        info["CFBundleIdentifier"] = id
        info["CFBundleName"] = name
        info["CFBundleShortVersionString"] = version
        info["CFBundleVersion"] = build
        try (info as NSDictionary).write(to: box.url.appending(path: path + "/Contents/Info.plist"))
        return box.path + "/" + path
    }

    private func runner(_ output: String = "", code: Int32 = 0) -> CommandRunner {
        CommandRunner(run: { _, _ in (code, output) }, exists: { _ in true })
    }

    @Test func inventoriesBeforeIndexingAndGroupsIDsWithoutEquatingVersionsOrNames() throws {
        let box = try Sandbox()
        let primary = try app(box, "Applications/Editor.app")
        let second = try app(box, "builds/Editor.app", version: "2.0", build: "200")
        let variant = try app(box, "builds/Editor QA.app", id: "com.example.Editor.QA", name: "Editor QA")
        let sameName = try app(box, "elsewhere/Editor.app", id: "org.other.Editor")
        let missing = box.path + "/gone.app"
        let published = Mutex(false)
        let index = CommandRunner(run: { _, args in
            #expect(published.withLock { $0 })
            #expect(args == ["-0", AppCopies.indexQuery])
            return (0, [second, variant, sameName, primary, missing].joined(separator: "\0"))
        }, exists: { _ in true })
        let found = AppCopies.inventory(in: [box.path + "/Applications"], runner: index,
                                        registered: { _ in [second, primary, missing] }, progress: ScanProgress()) { step in
            if step.copies.contains(where: { $0.id == primary }) { published.withLock { $0 = true } }
        }
        #expect(found.copies.count == 4 && found.unreadable.isEmpty)
        #expect(found.missingRegistered == [missing])
        #expect(AppCopies.counts(found.copies)["com.example.editor"] == 2)
        #expect(found.copies.first { $0.id == second }?.app.version == "2.0")
        #expect(found.copies.first { $0.id == second }?.build == "200")
        #expect(found.copies.first { $0.id == variant }?.hint != nil)
        #expect(found.copies.first { $0.id == primary }?.hint == nil)
        #expect(found.copies.allSatisfy { $0.app.sizePending && $0.app.bytes == 0 })
    }

    @Test func selectedBuildFoldersIncludeUnindexedCopiesWithoutNestedAppsOrLinks() throws {
        let box = try Sandbox()
        let build = try app(box, "project/.build/arm64/debug/Editor.app")
        _ = try app(box, "project/.build/arm64/debug/Editor.app/Contents/Helpers/Helper.app", id: "com.example.Editor.Helper")
        _ = try app(box, "project/node_modules/Package/Test.app")
        _ = try app(box, ".Trash/Editor.app")
        let outside = try app(box, "outside/Another.app", id: "org.example.Another")
        try FileManager.default.createSymbolicLink(atPath: box.path + "/project/linked", withDestinationPath: box.path + "/outside")
        try FileManager.default.createSymbolicLink(atPath: box.path + "/project/Alias.app", withDestinationPath: outside)
        let found = AppCopies.addingFolders([box.path + "/project"], to: .init(), progress: ScanProgress())
        #expect(found.copies.map(\.id) == [build] && found.copies.first?.hint == .buildFolder)
        #expect(AppCopy.read(box.path + "/.Trash/Editor.app", source: .indexed) == nil)
        #expect(AppCopy.read(build + "/Contents/Helpers/Helper.app", source: .indexed) == nil)
        let stopped = ScanProgress()
        stopped.cancel()
        #expect(AppCopies.addingFolders([box.path], to: .init(), progress: stopped).cancelled)
        #expect(AppCopies.addingFolders([box.path + "/project"], to: .init(), progress: ScanProgress(), entryLimit: 1).limited)
        for index in 0..<300 { _ = try app(box, "project/.build/release/Editor-\(index).app", version: "\(index)") }
        let many = AppCopies.addingFolders([box.path + "/project"], to: .init(), progress: ScanProgress())
        #expect(many.copies.count == 301 && AppCopies.counts(many.copies)["com.example.editor"] == 301)
    }

    @Test func indexFailureIsNotReportedAsAnEmptyCompleteSearchAndAliasesDontAddCopies() throws {
        let box = try Sandbox()
        let path = try app(box, "Applications/Editor.app")
        try FileManager.default.createSymbolicLink(atPath: box.path + "/alias", withDestinationPath: box.path + "/Applications")
        let unavailable = AppCopies.inventory(in: [box.path + "/Applications"], runner: runner(path, code: CommandRunner.timedOut), registered: { _ in nil }, progress: ScanProgress())
        #expect(unavailable.copies.count == 1 && unavailable.indexedUnavailable && unavailable.registrationUnavailable)
        let aliases = AppCopies.inventory(in: [box.path + "/Applications"], runner: runner(box.path + "/alias/Editor.app"), registered: { _ in [] }, progress: ScanProgress())
        #expect(aliases.copies.count == 1)
        #expect(aliases.copies.first?.sources == [.applications, .indexed])
        let locked = try app(box, "locked/Editor.app")
        let parent = box.path + "/locked"
        #expect(chmod(parent, 0) == 0)
        defer { _ = chmod(parent, 0o755) }
        let unreadable = AppCopies.inventory(in: [box.path + "/Applications"], runner: runner(locked), registered: { _ in [] }, progress: ScanProgress())
        #expect(unreadable.unreadable.contains(locked))
    }

    @Test func integrationsExposeDeclarationsAndProvidersWithoutExecutingTheApp() throws {
        let box = try Sandbox()
        let path = try app(box, "Applications/Editor.app", extra: [
            "NSServices": [["NSMenuItem": ["default": "Editor/Format Selection"], "NSMessage": "formatSelection"]],
            "CFBundleDocumentTypes": [["CFBundleTypeName": "Text", "CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.plain-text"]]],
            "CFBundleURLTypes": [["CFBundleURLName": "Editor link", "CFBundleURLSchemes": ["example-editor"]]],
        ])
        _ = try app(box, "Applications/Editor.app/Contents/PlugIns/Finder.appex", id: "com.example.Editor.Finder", name: "Editor Finder", extra: [
            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.FinderSync"],
        ])
        let copy = try #require(AppCopy.read(path, source: .applications))
        #expect(Set(copy.integrations.items.map(\.kind)) == [.service, .documents, .urls, .finder])
        #expect(copy.integrations.items.first { $0.kind == .service }?.name == "Format Selection")
        #expect(copy.integrations.items.first { $0.kind == .finder }?.detail.contains("com.example.Editor.Finder") == true)
        try box.file("Applications/Editor.app/Contents/PlugIns/Unreadable.appex/Contents/Info.plist", bytes: 20)
        let incomplete = try #require(AppCopy.read(path, source: .applications))
        #expect(!incomplete.integrations.unreadable.isEmpty)
        let before = copy
        try FileManager.default.moveItem(atPath: path, toPath: box.path + "/Applications/Moved.app")
        _ = try app(box, "Applications/Editor.app")
        #expect(!before.isCurrent())
    }

    @Test func rememberedCopiesAreFreshEvidenceAndUnreadableOwnershipFailsClosed() throws {
        let box = try Sandbox()
        let path = try app(box, "project/.build/Editor.app")
        let registry = KnownAppCopies()
        registry.remember([try #require(AppFinder.metadata(path))])
        #expect(try #require(registry.adding(to: [])).count == 1)
        try Data("broken identity".utf8).write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        #expect(registry.adding(to: []) == nil)
        try FileManager.default.removeItem(atPath: path)
        #expect(registry.adding(to: []) == [])
    }
}
