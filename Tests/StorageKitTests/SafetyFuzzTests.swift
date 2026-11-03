import Darwin
import Foundation
import Testing

@testable import StorageKit

/// Randomized checks of the rules every destructive flow relies on. Each
/// run is seeded, so a failure names the seed that reproduces it. Trees are
/// synthetic and live in the test's own folder; nothing is moved.
@Suite struct SafetyFuzzTests {
    /// SplitMix64: small, fast and the same on every machine.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let names = ["a", "b", "cache", "build", "keep", "notes", "node_modules", ".bin", "x.js", "y.o"]

    /// A random tree under `root`: folders, files and links that point back
    /// into the tree or out of it.
    func tree(at root: String, outside: String, rng: inout Seeded) throws -> [String] {
        var dirs = [root]
        var all: [String] = []
        for _ in 0..<Int.random(in: 6...30, using: &rng) {
            let parent = dirs.randomElement(using: &rng)!
            let p = parent + "/" + Self.names.randomElement(using: &rng)! + "\(Int.random(in: 0...2, using: &rng))"
            var st = stat()
            guard lstat(p, &st) != 0 else { continue }
            switch Int.random(in: 0..<10, using: &rng) {
            case 0..<4:
                try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
                dirs.append(p)
            case 4..<9:
                FileManager.default.createFile(atPath: p, contents: Data("x".utf8))
            default:
                let target = Bool.random(using: &rng) ? outside : dirs.randomElement(using: &rng)!
                try FileManager.default.createSymbolicLink(atPath: p, withDestinationPath: target)
            }
            all.append(p)
        }
        return all
    }

    func isLink(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0 && st.st_mode & S_IFMT == S_IFLNK
    }

    /// Every path below `p`, links not followed.
    func everything(under p: String) -> [String] {
        guard !isLink(p), let names = try? FileManager.default.contentsOfDirectory(atPath: p) else { return [] }
        return names.flatMap { [p + "/" + $0] + everything(under: p + "/" + $0) }
    }

    @Test(arguments: 0..<150)
    func projectKeepRulesAreNeverCrossed(seed: Int) throws {
        var rng = Seeded(state: UInt64(seed))
        let box = try Sandbox()
        let outside = box.path + "/outside"
        try box.file("outside/precious", bytes: 10)
        let root = box.path + "/project/target"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let made = try tree(at: root, outside: outside, rng: &rng)

        var rules = ProjectRules()
        rules.keepPaths = Set(made.filter { _ in Int.random(in: 0..<6, using: &rng) == 0 })
        if Bool.random(using: &rng) { rules.keepNames = ["notes0", "keep1"] }
        let planned = rules.trashPaths(for: root)

        for p in planned {
            // Nothing kept, inside something kept, or holding something kept.
            #expect(!rules.keepPaths.contains { k in p == k || p.hasPrefix(k + "/") || k.hasPrefix(p + "/") }, "seed \(seed): \(p)")
            #expect(!rules.keepNames.contains((p as NSString).lastPathComponent), "seed \(seed): \(p)")
            #expect(!everything(under: p).contains { rules.keepNames.contains(($0 as NSString).lastPathComponent) }, "seed \(seed): \(p)")
            // Never outside the chosen folder, never through a link.
            #expect(p == root || p.hasPrefix(root + "/"), "seed \(seed): \(p)")
            #expect(Trasher.noLinksBetween(box.path, and: p), "seed \(seed): \(p)")
        }
        // No planned path inside another: each goes once.
        #expect(Set(Trasher.outermost(planned)) == Set(planned), "seed \(seed)")
        #expect(FileManager.default.fileExists(atPath: outside + "/precious"))
    }

    @Test(arguments: 0..<150)
    func deepCleanKeepListIsNeverCrossed(seed: Int) throws {
        var rng = Seeded(state: UInt64(seed) &+ 10_000)
        let box = try Sandbox()
        let home = box.path
        let caches = home + "/Library/Caches"
        try FileManager.default.createDirectory(atPath: caches, withIntermediateDirectories: true)
        let made = try tree(at: caches, outside: home + "/Documents", rng: &rng)
        let keep = CleanKeepList(paths: Set(made.filter { _ in Int.random(in: 0..<5, using: &rng) == 0 }))

        for c in CleanScanner.scan(home: home, workers: 2) {
            for p in CleanScanner.trashPaths(for: c, keep: keep) {
                #expect(!keep.protects(p), "seed \(seed): \(p)")
                #expect(p.hasPrefix(caches + "/"), "seed \(seed): \(p)")
            }
            // What's offered is a real file or folder right inside a rule's place.
            #expect(!isLink(c.path), "seed \(seed): \(c.path)")
            #expect(CleanScanner.isStillCandidate(c.path, home: home), "seed \(seed): \(c.path)")
        }
    }

    @Test(arguments: 0..<300)
    func recheckRefusesTwistedPaths(seed: Int) throws {
        var rng = Seeded(state: UInt64(seed) &+ 20_000)
        let box = try Sandbox()
        let home = box.path
        try box.file("Library/Caches/com.vendor.App/c", bytes: 10)
        try box.file("Documents/mine", bytes: 10)
        try FileManager.default.createSymbolicLink(atPath: home + "/Library/Caches/away", withDestinationPath: home + "/Documents")
        let parts = ["Library", "Caches", "com.vendor.App", "..", ".", "", "Documents", "away", "mine", "c"]
        let p = home + "/" + (0..<Int.random(in: 1...6, using: &rng)).map { _ in parts.randomElement(using: &rng)! }.joined(separator: "/")

        if CleanScanner.isStillCandidate(p, home: home) {
            #expect((p as NSString).standardizingPath == p, "seed \(seed): \(p)")
            #expect(!isLink(p) && Trasher.noLinksBetween(home, and: p), "seed \(seed): \(p)")
            #expect(!p.contains("/Documents"), "seed \(seed): \(p)")
        }
        let app = AppBundle(path: "/synthetic/App.app", name: "App", bundleID: "com.vendor.App", version: nil, bytes: 0, fromAppStore: false)
        if AppLeftovers.isStillLeftover(p, of: app, home: home, installed: [app]) {
            #expect(p == home + "/Library/Caches/com.vendor.App", "seed \(seed): \(p)")
        }
    }

    @Test(arguments: 0..<300)
    func protectedPlacesStayProtectedHoweverWritten(seed: Int) {
        var rng = Seeded(state: UInt64(seed) &+ 30_000)
        let home = "/Users/synthetic"
        let sealed = [home + "/Library/Keychains", home + "/.ssh", home + "/.gnupg", home + "/Library/Application Support/com.apple.TCC"]
        let base = sealed.randomElement(using: &rng)!
        // The same place written with redundant parts, or something inside it.
        var p = base
        for _ in 0..<Int.random(in: 0...3, using: &rng) {
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: p += "/."
            case 1: p += "/sub/.."
            default: p += "/" + ["login.keychain-db", "id_test", "TCC.db", "deep/er"].randomElement(using: &rng)!
            }
        }
        #expect(Trasher.isProtected(p, home: home), "seed \(seed): \(p)")
        // And every folder holding it.
        var parent = (base as NSString).deletingLastPathComponent
        while parent.count > 1 {
            #expect(Trasher.isProtected(parent, home: home), "seed \(seed): \(parent)")
            parent = (parent as NSString).deletingLastPathComponent
        }
    }

    @Test(arguments: 0..<200)
    func leftoversNeverReachAnotherInstalledApp(seed: Int) {
        var rng = Seeded(state: UInt64(seed) &+ 40_000)
        let ids = ["com.vendor.App", "com.vendor.App.Pro", "com.vendor.AppX", "com.vendor.App.Pro.Max", "com.other.App"]
        let suffixes = ["", ".plist", ".savedState", ".helper", ".0A1B.plist", ".binarycookies"]
        let installed = ids.shuffled(using: &rng).prefix(Int.random(in: 1...ids.count, using: &rng)).map {
            AppBundle(path: "/synthetic/\($0).app", name: $0, bundleID: $0, version: nil, bytes: 0, fromAppStore: false)
        }
        let app = installed[0]
        let entry = ids.randomElement(using: &rng)! + suffixes.randomElement(using: &rng)!
        for place in AppLeftovers.places where AppLeftovers.belongs(entry, rules: place.matches, to: app, installed: installed) {
            // No other installed app's bundle ID claims it more closely.
            for other in installed where other.path != app.path {
                let otherID = other.bundleID!
                let claims = otherID.count > app.bundleID!.count
                    && AppLeftovers.matches(entry, id: otherID, name: nil, rules: place.matches)
                #expect(!claims, "seed \(seed): \(entry) in \(place.folder) for \(app.bundleID!) vs \(otherID)")
            }
            #expect(AppLeftovers.matches(entry, id: app.bundleID!, name: nil, rules: place.matches)
                || entry == app.name, "seed \(seed): \(entry)")
        }
    }

    @Test(arguments: 0..<200)
    func outermostCoversEverythingOnce(seed: Int) {
        var rng = Seeded(state: UInt64(seed) &+ 50_000)
        let paths = (0..<Int.random(in: 1...12, using: &rng)).map { _ in
            "/r/" + (0..<Int.random(in: 1...4, using: &rng)).map { _ in ["a", "b", "c"].randomElement(using: &rng)! }.joined(separator: "/")
        }
        let top = Trasher.outermost(paths)
        for p in paths { #expect(top.contains { p == $0 || p.hasPrefix($0 + "/") }, "seed \(seed): \(p)") }
        for a in top { #expect(!top.contains { $0 != a && a.hasPrefix($0 + "/") }, "seed \(seed): \(a)") }
    }
}
