import Foundation
import StorageKit
import Testing

@testable import MyMole

@MainActor @Suite struct ProjectOverrideTests {
    func fixture(_ body: @MainActor (ProjectsModel, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "project-override-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "Example")
        try FileManager.default.createDirectory(at: project.appending(path: ".build/release"), withIntermediateDirectories: true)
        try Data("keep release".utf8).write(to: project.appending(path: ".build/release/sentinel"))
        let item = FootprintItem(id: "synthetic.build", category: .build, title: ".build", location: project.path,
            attribution: .inside, entries: [.init(path: project.path + "/.build", bytes: 100, modified: .distantPast)])
        let footprint = ProjectFootprint(project: .init(path: project.path, markers: ["Package.swift"]), items: [item])
        let store = root.appending(path: "store")
        let model = ProjectsModel(footprints: [footprint], base: store, defaults: testDefaults(in: store), logURL: root.appending(path: "history.json"))
        // Rule tests never discover real projects or run background filesystem scans.
        model.measureProject = { _, _, _ in footprint }
        defer { model.stop() }
        try await body(model, project)
    }

    @Test func cancellingAnOverrideDoesNotWriteARuleOrSuppressItsQuestion() async throws {
        try await fixture { model, project in
            let change = ProjectsModel.RuleChange.whitelist([project.path + "/.build/release"], project: project.path)
            model.requestRule(change)
            #expect(model.pendingRule == change && model.rules.isEmpty)
            model.pendingRule = nil
            #expect(model.ruleConfirmations.asks(.projectWhitelist))
            #expect(model.rules.isEmpty)
        }
    }

    @Test func whitelistLocksDescendantsEvenInsideAChosenBuildFolder() async throws {
        try await fixture { model, project in
            let build = project.path + "/.build", release = build + "/release"
            let change = ProjectsModel.RuleChange.whitelist([release], project: project.path)
            model.requestRule(change)
            model.confirmRule(change, remind: false)
            #expect(!model.ruleConfirmations.asks(.projectWhitelist))
            #expect(model.ruleConfirmations.asks(.projectBlacklist))
            #expect(model.rules.protects(release + "/sentinel"))
            model.chosen = [build]
            #expect(model.state(of: release) == .off)
            model.toggle(path: release)
            #expect(!model.chosen.contains(release))
            let plan = model.rules.trashPaths(for: build)
            #expect(!plan.contains { $0 == release || $0.hasPrefix(release + "/") || release.hasPrefix($0 + "/") })
            let keptData = try Data(contentsOf: project.appending(path: ".build/release/sentinel"))
            #expect(keptData == Data("keep release".utf8))
        }
    }

    @Test func blacklistAddsASuggestionButNeverChoosesOrRemovesIt() async throws {
        try await fixture { model, project in
            let path = project.path + "/custom-output"
            let change = ProjectsModel.RuleChange.blacklist([path], project: project.path)
            model.requestRule(change)
            #expect(model.rules.cleanPaths[path] == nil)
            model.confirmRule(change, remind: true)
            #expect(model.rules.cleanPaths[path] == project.path)
            #expect(model.chosen.isEmpty && model.ruleConfirmations.asks(.projectBlacklist))
            #expect(!model.trashing)
        }
    }

    @Test func outdatedOverlayCannotApplyADifferentPendingRule() async throws {
        try await fixture { model, project in
            let first = ProjectsModel.RuleChange.whitelist([project.path + "/.build/release"], project: project.path)
            let other = ProjectsModel.RuleChange.blacklist([project.path + "/custom"], project: project.path)
            model.requestRule(first)
            model.confirmRule(other, remind: false)
            #expect(model.pendingRule == first && model.rules.isEmpty)
            #expect(model.ruleConfirmations.asks(.projectBlacklist))
        }
    }

    @Test func pinsPersistWithoutChangingCleanupRules() async throws {
        try await fixture { model, project in
            let second = PinnedItems(defaults: testDefaults(in: project.deletingLastPathComponent().appending(path: "store")))
            model.pins.set([project.path], pinned: true)
            second.set([project.path + "/.build"], pinned: true)
            model.pins.refresh()
            #expect(model.pins.contains(project.path) && model.rules.isEmpty && model.chosen.isEmpty)
            #expect(model.pins.contains(project.path + "/.build"))
            let paths = model.pins.paths
            model.pins.set([project.path], pinned: false)
            #expect(!model.pins.contains(project.path) && paths.contains(project.path))
            #expect(model.rules.isEmpty)
        }
    }

    @Test func nameWhitelistProtectsDescendantsWithoutProtectingUnrelatedAncestors() async throws {
        try await fixture { model, project in
            model.keepEverywhere(named: "release")
            #expect(model.isKeptElsewhere(project.path + "/.build/release/sentinel"))
            #expect(!model.isKeptElsewhere(project.path + "/.build/debug/output"))
        }
    }
}
