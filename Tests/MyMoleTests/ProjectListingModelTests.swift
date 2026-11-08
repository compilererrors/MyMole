import Foundation
import StorageKit
import Testing

@testable import MyMole

/// The Projects pane on a search folder that can't be read.
@MainActor
@Suite struct ProjectListingModelTests {
    @Test func anUnreadableRootShowsAsIncompleteNotAsNoProjects() async throws {
        let box = FileManager.default.temporaryDirectory.appending(path: "projects-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: box) }
        let root = box.appending(path: "roots")
        let project = root.appending(path: "web")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appending(path: "package.json"))
        let store = box.appending(path: "store")
        let defaults = testDefaults(in: store)
        defaults.set([root.path], forKey: "projects.roots")

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        let model = ProjectsModel(
            base: store, defaults: defaults, logURL: box.appending(path: "history.json"), keepList: box.appending(path: "keep.json"))
        await model.restoreJob?.value
        model.scan()
        await model.scanJob?.value
        while model.scanning { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.footprints.isEmpty)
        // The model also looks in the real home folder, which the test
        // sandbox closes, so other places may be listed beside the root.
        #expect(model.incomplete && model.unreadablePlaces.contains(root.path))
    }
}
