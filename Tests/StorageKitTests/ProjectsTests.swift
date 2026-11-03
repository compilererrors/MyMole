import Foundation
import Testing

@testable import StorageKit

@Suite struct ProjectFinderTests {
    @Test func findsProjectsButNotInsideThem() throws {
        let box = try Sandbox()
        try box.file("Work/Alpha/Package.swift", bytes: 100)
        try box.file("Work/Alpha/packages/inner/package.json", bytes: 100)
        try box.file("Work/group/Beta/package.json", bytes: 100)
        try box.folder("Work/group/Beta/.git")
        try box.file("Work/notes/readme.txt", bytes: 100)
        try box.file("Work/Delta/Delta.xcodeproj/project.pbxproj", bytes: 100)
        try box.file("Work/.hidden/Package.swift", bytes: 100)

        let found = ProjectFinder.find(roots: [box.path + "/Work"])
        #expect(found.map(\.name).sorted() == ["Alpha", "Beta", "Delta"])
        let beta = try #require(found.first { $0.name == "Beta" })
        #expect(beta.markers == [".git", "package.json"])
        #expect(beta.kind == "Node · Git")
        #expect(found.first { $0.name == "Delta" }?.kind == "Xcode")
    }

    @Test func aRootWithAProjectFileStillListsItsProjects() throws {
        let box = try Sandbox()
        try box.file("Work/Makefile", bytes: 100)
        try box.file("Work/A/go.mod", bytes: 100)
        #expect(ProjectFinder.find(roots: [box.path + "/Work"]).map(\.name) == ["A"])
        try FileManager.default.removeItem(atPath: box.path + "/Work/A")
        #expect(ProjectFinder.find(roots: [box.path + "/Work"]).map(\.name) == ["Work"])
    }

    @Test func ownerIsTheLongestMatch() {
        let projects = [DevProject(path: "/w/as", markers: []), DevProject(path: "/w/as-tests", markers: [])]
        #expect(ProjectFinder.owner(of: "/w/as-tests/src", in: projects)?.path == "/w/as-tests")
        #expect(ProjectFinder.owner(of: "/w/as", in: projects)?.path == "/w/as")
        #expect(ProjectFinder.owner(of: "/w/asx", in: projects) == nil)
    }
}

@Suite struct ProjectArtifactTests {
    @Test func sortsAProjectIntoItsParts() throws {
        let box = try Sandbox()
        try box.file("P/Package.swift", bytes: 1_000)
        try box.file("P/Sources/main.swift", bytes: 20_000)
        try box.file("P/.git/objects/pack", bytes: 50_000)
        try box.file("P/.build/debug/app", bytes: 300_000)
        try box.file("P/.local/run-1/out.bin", bytes: 200_000)
        try box.file("P/build/out.o", bytes: 40_000)  // beside Package.swift: output
        try box.file("P/Sources/build/notes.txt", bytes: 5_000)  // no project file beside it: source
        try box.file("P/web/package.json", bytes: 100)
        try box.file("P/web/node_modules/a/index.js", bytes: 60_000)
        try box.file("P/web/packages/x/node_modules/b/index.js", bytes: 30_000)
        try box.file("P/.claude/worktrees/w1/Package.swift", bytes: 10_000)
        try box.file("P/.claude/settings.json", bytes: 100)

        let project = DevProject(path: box.path + "/P", markers: ["Package.swift"])
        let fp = ProjectScanner.measure(ProjectFootprint(project: project, items: [], measured: false))
        #expect(fp.measured)
        let byID = Dictionary(uniqueKeysWithValues: fp.items.map { ($0.id, $0) })

        #expect(byID["inside:.build"]?.category == .build)
        #expect(byID["inside:.build"]?.bytes == box.allocated("P/.build/debug/app"))
        #expect(byID["inside:.local"]?.category == .localData)
        #expect(byID["inside:build"]?.entries.map(\.path) == [box.path + "/P/build"])
        #expect(byID["inside:.git"]?.category == .git)
        #expect(byID["inside:worktrees"]?.category == .worktrees)
        let modules = try #require(byID["inside:node_modules"])
        #expect(modules.category == .dependencies)
        #expect(modules.entries.count == 2)
        #expect(modules.entries.first?.path == box.path + "/P/web/node_modules")  // largest first

        // Whatever isn't claimed is source, and nothing is counted twice.
        let total = StorageScanner.scan(path: project.path).root.size
        #expect(fp.bytes == total)
        let source = try #require(byID["inside:source"])
        #expect(source.bytes == box.allocated("P/Package.swift") + box.allocated("P/Sources/main.swift")
            + box.allocated("P/Sources/build/notes.txt") + box.allocated("P/web/package.json")
            + box.allocated("P/.claude/settings.json"))
        #expect(!source.removable && byID["inside:.git"]?.removable == false)
        // One source entry per top-level folder, less what's claimed in it,
        // plus the loose files of the project folder itself.
        let parts = Dictionary(uniqueKeysWithValues: source.entries.map { ($0.path, $0.bytes) })
        #expect(parts[project.path] == box.allocated("P/Package.swift"))
        #expect(parts[project.path + "/Sources"] == box.allocated("P/Sources/main.swift") + box.allocated("P/Sources/build/notes.txt"))
        #expect(parts[project.path + "/web"] == box.allocated("P/web/package.json"))
        #expect(parts[project.path + "/.build"] == nil)
        #expect(fp.removableBytes == fp.bytes - source.bytes - byID["inside:.git"]!.bytes)
    }
}

@Suite struct ProjectAttributionTests {
    /// A home folder with traces of a project called Brightpad in the places
    /// tools really put them.
    private func home() throws -> (Sandbox, DevProject, DevProject) {
        let box = try Sandbox()
        try box.file("Workspace/Brightpad/Package.swift", bytes: 100)
        try box.file("Workspace/lumen/index.html", bytes: 100)
        let qz = DevProject(path: box.path + "/Workspace/Brightpad", markers: ["Package.swift"])
        let other = DevProject(path: box.path + "/Workspace/lumen", markers: [".git"])

        func write(_ rel: String, _ text: String) throws {
            let u = box.url.appending(path: rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        // Codex: the first line records the working directory.
        try write(
            ".codex/sessions/2026/10/29/rollout-a.jsonl",
            #"{"type":"session_meta","payload":{"id":"a","cwd":"\#(qz.path)/Sources","originator":"codex"}}"# + "\n{}\n")
        try write(
            ".codex/archived_sessions/rollout-b.jsonl",
            #"{"type":"session_meta","payload":{"cwd":"\#(qz.path)"}}"# + "\n")
        try write(".codex/sessions/2026/10/30/rollout-c.jsonl", #"{"payload":{"cwd":"/elsewhere"}}"#)
        // Claude Code: one folder per working directory, worktrees included.
        let key = ProjectAttribution.claudeKey(qz.path)
        try write(".claude/projects/\(key)/s1.jsonl", "{}")
        try write(".claude/projects/\(key)--claude-worktrees-brave/s2.jsonl", "{}")
        // Xcode: info.plist names the workspace.
        let dd = box.url.appending(path: "Library/Developer/Xcode/DerivedData/Brightpad-abc")
        try FileManager.default.createDirectory(at: dd, withIntermediateDirectories: true)
        try (["WorkspacePath": qz.path + "/Brightpad.xcworkspace"] as NSDictionary).write(to: dd.appending(path: "info.plist"))
        // ~/Library: matched by name only.
        try box.file("Library/Containers/com.brightpad.workflow.1f7e/Data/x", bytes: 4_000)
        try box.file("Library/Containers/com.lumen.brightpad/Data/x", bytes: 4_000)
        try box.file("Library/Containers/com.apple.brightpad/Data/x", bytes: 4_000)
        try box.file("Library/Containers/com.vendor.unrelated/Data/x", bytes: 4_000)
        try box.file("Library/Application Support/Brightpad/state.db", bytes: 4_000)
        try write("Library/Preferences/com.brightpad.app.plist", "x")
        return (box, qz, other)
    }

    @Test func attributesOutsideDataToItsProject() throws {
        let (box, qz, other) = try home()
        let items = ProjectAttribution.items(for: [qz, other], home: box.path)
        let mine = Dictionary(uniqueKeysWithValues: (items[qz.path] ?? []).map { ($0.id, $0) })

        let codex = try #require(mine["codex:sessions"])
        #expect(codex.attribution == .recorded && codex.category == .agentSessions)
        #expect(Set(codex.entries.map { ($0.path as NSString).lastPathComponent }) == ["rollout-a.jsonl", "rollout-b.jsonl"])

        let claude = try #require(mine["claude:projects"])
        #expect(Set(claude.entries.map { ($0.path as NSString).lastPathComponent }) == ["s1.jsonl", "s2.jsonl"])

        #expect(mine["xcode:deriveddata"]?.entries.count == 1)

        let containers = try #require(mine["library:Containers"])
        #expect(containers.attribution == .nameMatch)
        // The product part wins over the vendor part, and Apple's are never taken.
        #expect(Set(containers.entries.map { ($0.path as NSString).lastPathComponent })
            == ["com.brightpad.workflow.1f7e", "com.lumen.brightpad"])
        #expect(mine["library:Application Support"]?.entries.count == 1)
        #expect(mine["library:Preferences"]?.entries.count == 1)

        // "lumen" is a vendor here, but no less a project name: it gets
        // nothing the more specific Brightpad match claimed.
        #expect(items[other.path] == nil)
    }

    @Test func commonOrSharedNamesMatchNothing() {
        #expect(ProjectAttribution.nameKey(DevProject(path: "/w/apple", markers: [])) == nil)
        #expect(ProjectAttribution.nameKey(DevProject(path: "/w/io", markers: [])) == nil)
        #expect(ProjectAttribution.nameKey(DevProject(path: "/w/Mac Hue", markers: [])) == "machue")
    }

    @Test func readsCodexWorkingDirectory() throws {
        let box = try Sandbox()
        let u = box.url.appending(path: "s.jsonl")
        try #"{"payload":{"base":"a \"quoted\" word","cwd":"/Users/me/Work/x\/y"}}"#.write(to: u, atomically: true, encoding: .utf8)
        #expect(ProjectAttribution.codexCwd(u.path) == "/Users/me/Work/x/y")
    }
}

@Suite struct ProjectFootprintTests {
    private func item(_ id: String, _ category: FootprintCategory, _ entries: [(String, Int64, Double)]) -> FootprintItem {
        FootprintItem(
            id: id, category: category, title: id, location: "/p", attribution: .inside,
            entries: entries.map { FootprintEntry(path: $0.0, bytes: $0.1, modified: Date(timeIntervalSince1970: $0.2)) })
    }

    @Test func totalsAgeAndRemoval() {
        let sessions = item("s", .agentSessions, [("/a", 10, 100), ("/b", 30, 300)])
        var fp = ProjectFootprint(
            project: DevProject(path: "/p", markers: []),
            items: [sessions, item("src", .source, [("/p", 50, 500)]), item("g", .git, [("/p/.git", 5, 900)])])
        #expect(fp.bytes == 95 && fp.removableBytes == 40)
        // Git activity isn't project activity.
        #expect(fp.lastActivity == Date(timeIntervalSince1970: 500))
        #expect(sessions.entries(olderThan: Date(timeIntervalSince1970: 200)).map(\.path) == ["/a"])

        fp.remove(paths: ["/a", "/b"])
        #expect(fp.items.map(\.id) == ["src", "g"])
        fp.restore([(sessions, sessions.entries[1])])
        #expect(fp.bytes(.agentSessions) == 10)
        #expect(fp.items.map(\.id) == ["src", "s", "g"])
    }

    @Test func growthIsMeasuredOverADay() throws {
        let box = try Sandbox()
        let project = DevProject(path: "/p", markers: [])
        func sized(_ bytes: Int64) -> ProjectFootprint {
            ProjectFootprint(project: project, items: [item("x", .build, [("/p/x", bytes, 0)])])
        }
        let hour: TimeInterval = 3_600
        let roots = ["/w"]
        ProjectStore.save([sized(100)], roots: roots, date: Date(timeIntervalSince1970: 0), base: box.url)
        var history = ProjectStore.save([sized(150)], roots: roots, date: Date(timeIntervalSince1970: hour), base: box.url)
        // Less than a day of history: no growth to show yet.
        #expect(ProjectStore.growth(history["/p"] ?? []) == nil)
        history = ProjectStore.save([sized(350)], roots: roots, date: Date(timeIntervalSince1970: 25 * hour), base: box.url)
        let g = try #require(ProjectStore.growth(history["/p"] ?? []))
        // The sample from hour 1 was only an hour after the kept one, so it
        // moved on; growth is against hour 0.
        #expect(g.bytes == 250 && g.since == Date(timeIntervalSince1970: 0))
        #expect(ProjectStore.loadLast(roots: roots, base: box.url)?.footprints.first?.bytes == 350)
        // Saved for other folders: not this result.
        #expect(ProjectStore.loadLast(roots: ["/other"], base: box.url) == nil)
        // A scan that couldn't read everything adds to the history only.
        var partial = sized(10)
        partial.incomplete = true
        _ = ProjectStore.save([partial], roots: roots, date: Date(timeIntervalSince1970: 26 * hour), base: box.url)
        #expect(ProjectStore.loadLast(roots: roots, base: box.url)?.footprints.first?.bytes == 350)
        #expect(ProjectStore.growth([]) == nil)
    }

    @Test func relaunchesDontFillTheHistory() {
        var samples: [ProjectStore.Sample] = []
        for minute in 0..<20 {
            samples = ProjectStore.adding(
                ProjectStore.Sample(date: Date(timeIntervalSince1970: Double(minute) * 60), bytes: Int64(minute)),
                to: samples)
        }
        // One fixed sample and the current one, which follows every scan.
        #expect(samples.map(\.bytes) == [0, 19])
        // The current one was only 19 minutes after the kept one, so it moves on.
        samples = ProjectStore.adding(
            ProjectStore.Sample(date: Date(timeIntervalSince1970: 7 * 3_600), bytes: 99), to: samples)
        #expect(samples.map(\.bytes) == [0, 99])
        // Now it's more than six hours after the kept one, so it's kept.
        samples = ProjectStore.adding(
            ProjectStore.Sample(date: Date(timeIntervalSince1970: 7 * 3_600 + 60), bytes: 100), to: samples)
        #expect(samples.map(\.bytes) == [0, 99, 100])
        #expect(!zip(samples.dropLast(), samples.dropLast().dropFirst()).contains { $1.date.timeIntervalSince($0.date) < 21_600 })
    }
}

@Suite struct ProjectRulesTests {
    @Test func rulesOverrideWhatMyMoleFinds() throws {
        let box = try Sandbox()
        try box.file("P/Package.swift", bytes: 100)
        try box.file("P/.local/run/out.bin", bytes: 50_000)
        try box.file("P/build/out.o", bytes: 40_000)
        try box.file("P/archive/old.bin", bytes: 30_000)
        try box.file("P/devstuff/notes.bin", bytes: 20_000)
        try box.file("P/Sources/main.swift", bytes: 10_000)
        let project = DevProject(path: box.path + "/P", markers: ["Package.swift"])

        var rules = ProjectRules()
        rules.keepNames = [".local"]
        rules.keepPaths = [project.path + "/build"]
        rules.cleanPaths = [project.path + "/archive": project.path]
        rules.cleanNames = ["devstuff"]
        let fp = ProjectScanner.measure(ProjectFootprint(project: project, items: []), rules: rules)
        let byID = Dictionary(uniqueKeysWithValues: fp.items.map { ($0.id, $0) })

        let kept = try #require(byID["inside:kept"])
        #expect(kept.category == .kept && !kept.removable)
        #expect(Set(kept.entries.map(\.path)) == [project.path + "/.local", project.path + "/build"])
        let marked = try #require(byID["inside:marked"])
        #expect(marked.removable && !marked.category.rebuildable)
        #expect(Set(marked.entries.map(\.path)) == [project.path + "/archive", project.path + "/devstuff"])
        #expect(byID["inside:.local"] == nil && byID["inside:build"] == nil)
        // Nothing is counted twice.
        #expect(fp.bytes == StorageScanner.scan(path: project.path).root.size)
    }

    @Test func keepingWinsOverCleaning() {
        var rules = ProjectRules()
        rules.cleanNames = ["cache"]
        rules.keepPaths = ["/p/cache"]
        #expect(!rules.cleans("/p/cache") && rules.keeps("/p/cache"))
        #expect(rules.cleans("/p/sub/cache"))
    }

    @Test func outsideRulesKeepAndAdd() throws {
        let box = try Sandbox()
        try box.file("Workspace/Proj/Package.swift", bytes: 100)
        let project = DevProject(path: box.path + "/Workspace/Proj", markers: ["Package.swift"])
        let session = box.url.appending(path: ".codex/sessions/2026/10/29/rollout-a.jsonl")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"payload":{"cwd":"\#(project.path)"}}"#.write(to: session, atomically: true, encoding: .utf8)
        try box.file("Library/Caches/odd-tool-cache/blob", bytes: 8_000)

        var rules = ProjectRules()
        rules.keepPaths = [session.path]
        rules.cleanPaths = [box.path + "/Library/Caches/odd-tool-cache": project.path]
        let items = ProjectAttribution.items(for: [project], home: box.path, rules: rules)[project.path] ?? []
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        #expect(byID["codex:sessions"] == nil)
        #expect(byID["outside:kept"]?.entries.map(\.path) == [session.path])
        #expect(byID["user:marked"]?.attribution == .user)
        #expect(byID["user:marked"]?.entries.first?.bytes == box.allocated("Library/Caches/odd-tool-cache/blob"))
    }

    @Test func whatCanBeMarked() {
        let home = "/Users/me"
        let project = "/Users/me/Work/P"
        #expect(ProjectRules.canClean("/Users/me/Work/P/archive", project: project, home: home))
        #expect(ProjectRules.canClean("/Users/me/Library/Caches/p-cache", project: project, home: home))
        #expect(!ProjectRules.canClean(project, project: project, home: home))
        #expect(!ProjectRules.canClean("/Users/me/Work", project: project, home: home))
        #expect(!ProjectRules.canClean("/Users/me/Work/P/.git", project: project, home: home))
        #expect(!ProjectRules.canClean("/Users/me/Library", project: project, home: home))
        #expect(ProjectRules.canCleanEverywhere(name: "devstuff"))
        #expect(!ProjectRules.canCleanEverywhere(name: ".git") && !ProjectRules.canCleanEverywhere(name: "a/b"))
    }

    @Test func rulesAreSaved() throws {
        let box = try Sandbox()
        var rules = ProjectRules()
        rules.cleanNames = ["devstuff"]
        rules.keepPaths = ["/p/.local"]
        try ProjectStore.saveRules(rules, base: box.url)
        #expect(try ProjectStore.loadRules(base: box.url) == rules)
        #expect(try ProjectStore.loadRules(base: box.url.appending(path: "none")).isEmpty)
    }

    @Test func rulesThatCantBeReadThrow() throws {
        let box = try Sandbox()
        try Data("not json".utf8).write(to: box.url.appending(path: "rules.json"))
        #expect(throws: (any Error).self) { try ProjectStore.loadRules(base: box.url) }

        let locked = box.url.appending(path: "locked")
        var rules = ProjectRules()
        rules.keepPaths = ["/p/.local"]
        try ProjectStore.saveRules(rules, base: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(throws: (any Error).self) { try ProjectStore.loadRules(base: locked) }
    }

    @Test func keptPathInsideChosenFolderStays() throws {
        let box = try Sandbox()
        let nm = box.path + "/app/node_modules"
        try box.file("app/node_modules/left-pad/index.js", bytes: 2_000)
        try box.file("app/node_modules/local-only/patch.js", bytes: 2_000)
        try box.file("app/node_modules/.bin/tool", bytes: 1_000)
        var rules = ProjectRules()
        rules.keepPaths = [nm + "/local-only"]
        #expect(rules.trashPaths(for: nm) == [nm + "/.bin", nm + "/left-pad"])
        #expect(rules.trashPaths(for: nm + "/local-only").isEmpty)
        #expect(rules.trashPaths(for: nm + "/local-only/patch.js").isEmpty)
        #expect(ProjectRules().trashPaths(for: nm) == [nm])
    }

    @Test func keptNameDeepInsideChosenFolderStays() throws {
        let box = try Sandbox()
        let build = box.path + "/app/build"
        try box.file("app/build/out/a.o", bytes: 1_000)
        try box.file("app/build/out/notes/todo.txt", bytes: 1_000)
        try box.file("app/build/cache/b", bytes: 1_000)
        var rules = ProjectRules()
        rules.keepNames = ["notes"]
        #expect(rules.trashPaths(for: build) == [build + "/cache", build + "/out/a.o"])
    }

    @Test func keptItemBehindLinkLeavesFolderAlone() throws {
        let box = try Sandbox()
        try box.file("elsewhere/kept/x", bytes: 1_000)
        try box.file("elsewhere/other", bytes: 1_000)
        try box.folder("app")
        let link = box.path + "/app/linked"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: box.path + "/elsewhere")
        var rules = ProjectRules()
        rules.keepPaths = [link + "/kept"]
        #expect(rules.trashPaths(for: link).isEmpty)
    }

    @Test func unreadableFolderWithKeptNamesIsLeftAlone() throws {
        let box = try Sandbox()
        let build = box.path + "/app/build"
        try box.file("app/build/sealed/x", bytes: 1_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: build + "/sealed")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: build + "/sealed") }
        var rules = ProjectRules()
        rules.keepNames = ["notes"]
        #expect(rules.trashPaths(for: build).isEmpty)
    }

    @Test func mergedRulesKeepWhatEitherKeeps() {
        var a = ProjectRules()
        a.keepPaths = ["/p/a"]
        var b = ProjectRules()
        b.keepPaths = ["/p/b"]
        b.keepNames = ["notes"]
        let m = a.merging(b)
        #expect(m.protects("/p/a/x") && m.protects("/p/b") && m.protects("/q/notes"))
    }
}

/// Git is never run: a recording fake answers for it.
@Suite struct ProjectGuardTests {
    private final class FakeGit: @unchecked Sendable {
        let installed: Bool
        let output: String
        var calls: [[String]] = []
        init(installed: Bool = true, output: String = "") {
            self.installed = installed
            self.output = output
        }

        var runner: CommandRunner {
            CommandRunner(
                run: { exe, args in
                    self.calls.append([exe] + args)
                    return (0, self.output)
                },
                exists: { self.installed && $0 == ProjectGuard.gitLocations[0] })
        }
    }

    @Test func nestedRepositoryOrKeyFilesStay() throws {
        let box = try Sandbox()
        try box.file("app/build/out.o", bytes: 1_000)
        try box.file("app/vendored/lib/.git/HEAD", bytes: 100)
        try box.file("app/deploy/secrets/server.pem", bytes: 100)
        try box.file("app/node_modules/tls-test/fixtures/key.pem", bytes: 100)
        let git = FakeGit()
        let project = box.path + "/app"
        #expect(ProjectGuard.reason(for: project + "/build", project: project, runner: git.runner) == nil)
        #expect(ProjectGuard.reason(for: project + "/vendored", project: project, runner: git.runner) == "Holds a Git repository.")
        #expect(ProjectGuard.reason(for: project + "/deploy", project: project, runner: git.runner) == "Holds key files.")
        // Test keys inside third-party packages aren't the project's.
        #expect(ProjectGuard.reason(for: project + "/node_modules", project: project, runner: git.runner) == nil)
    }

    @Test func filesGitTracksStay() throws {
        let box = try Sandbox()
        try box.file("app/.git/HEAD", bytes: 100)
        try box.file("app/dist/bundle.js", bytes: 1_000)
        let project = box.path + "/app"
        let tracking = FakeGit(output: "dist/bundle.js\0")
        #expect(ProjectGuard.reason(for: project + "/dist", project: project, runner: tracking.runner) == "Holds files Git tracks.")
        #expect(tracking.calls.first == [ProjectGuard.gitLocations[0]] + ProjectGuard.safety + ["-C", project, "ls-files", "-z", "--", "dist"])
        let warningOnly = FakeGit(output: "warning: something\n")
        #expect(ProjectGuard.reason(for: project + "/dist", project: project, runner: warningOnly.runner) == nil)
        let noGit = FakeGit(installed: false)
        #expect(ProjectGuard.reason(for: project + "/dist", project: project, runner: noGit.runner)?.hasPrefix("Git isn't installed") == true)
    }

    @Test func outsideARepositoryGitIsntAsked() throws {
        let box = try Sandbox()
        try box.file("app/dist/bundle.js", bytes: 1_000)
        let git = FakeGit(installed: false)
        #expect(ProjectGuard.reason(for: box.path + "/app/dist", project: box.path + "/app", runner: git.runner) == nil)
        #expect(git.calls.isEmpty)
    }

    @Test func worktreeWithUncommittedWorkStays() throws {
        let box = try Sandbox()
        try box.file("app/.git/worktrees/w1/HEAD", bytes: 10)
        try Data("../..\n".utf8).write(to: URL(fileURLWithPath: box.path + "/app/.git/worktrees/w1/commondir"))
        try box.file("app/.claude/worktrees/w1/a.swift", bytes: 10)
        try Data("gitdir: \(box.path)/app/.git/worktrees/w1\n".utf8).write(to: URL(fileURLWithPath: box.path + "/app/.claude/worktrees/w1/.git"))
        let path = box.path + "/app/.claude/worktrees/w1"
        #expect(ProjectGuard.reason(for: path, project: box.path + "/app", worktree: true, runner: FakeGit(output: " M a.swift\0").runner) == "Has uncommitted work.")
        #expect(ProjectGuard.reason(for: path, project: box.path + "/app", worktree: true, runner: FakeGit().runner) == nil)
    }

    /// A repository's own settings could start a program while Git reads
    /// it; such a repository isn't asked, and what it holds stays.
    @Test func gitSettingsThatRunProgramsAreNeverObeyed() throws {
        let box = try Sandbox()
        try box.file("app/.git/HEAD", bytes: 10)
        try box.file("app/dist/bundle.js", bytes: 10)
        let project = box.path + "/app"
        let config = URL(fileURLWithPath: project + "/.git/config")
        for text in ["[filter \"x\"]\n\tclean = touch /tmp/owned\n", "[include]\n\tpath = elsewhere\n", "  [includeIf \"gitdir:~/\"]\n"] {
            try Data(text.utf8).write(to: config)
            let git = FakeGit()
            #expect(ProjectGuard.reason(for: project + "/dist", project: project, runner: git.runner) == "Its Git settings could run programs, so it wasn't checked.")
            #expect(git.calls.isEmpty)
        }
        // A worktree is judged by its main repository's settings too.
        try box.file("app/.git/worktrees/w1/HEAD", bytes: 10)
        try Data("../..\n".utf8).write(to: URL(fileURLWithPath: project + "/.git/worktrees/w1/commondir"))
        try box.file("app/wt/x", bytes: 10)
        try Data("gitdir: \(project)/.git/worktrees/w1\n".utf8).write(to: URL(fileURLWithPath: project + "/wt/.git"))
        let git = FakeGit()
        #expect(ProjectGuard.reason(for: project + "/wt", project: project, worktree: true, runner: git.runner) != nil)
        #expect(git.calls.isEmpty)
        // Plain settings are fine; every call turns fsmonitor off anyway.
        try Data("[core]\n\tbare = false\n".utf8).write(to: config)
        let plain = FakeGit()
        #expect(ProjectGuard.reason(for: project + "/wt", project: project, worktree: true, runner: plain.runner) == nil)
        #expect(plain.calls.first?.contains("core.fsmonitor=false") == true)
        // A .git file that names nothing isn't guessed at.
        try Data("nonsense".utf8).write(to: URL(fileURLWithPath: project + "/wt/.git"))
        #expect(ProjectGuard.reason(for: project + "/wt", project: project, worktree: true, runner: FakeGit().runner) == "Its Git folder couldn't be read, so it wasn't checked.")
    }

    @Test func unreadableFolderStays() throws {
        let box = try Sandbox()
        try box.file("app/build/sealed/x", bytes: 100)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: box.path + "/app/build/sealed")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.path + "/app/build/sealed") }
        #expect(ProjectGuard.reason(for: box.path + "/app/build", project: box.path + "/app", runner: FakeGit().runner) != nil)
    }
}
