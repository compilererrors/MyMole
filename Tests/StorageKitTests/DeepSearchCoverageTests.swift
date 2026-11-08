import Foundation
import Testing

@testable import StorageKit

@Suite struct DeepSearchCoverageTests {
    private func app(_ name: String = "Canvas 4", id: String = "org.example.Canvas", path: String = "/synthetic/Canvas.app") -> AppBundle {
        AppBundle(path: path, name: name, bundleID: id, version: nil, bytes: 1, fromAppStore: false)
    }

    @Test func hiddenLibraryCachesAndXDGStateAreReviewable() throws {
        let box = try Sandbox()
        let app = app()
        let paths = ["Library/Caches/.org.example.Canvas", ".local/state/canvas", ".local/share/org.example.Canvas", ".org.example.Canvas"]
        for path in paths { try box.file(path + "/state", bytes: 20) }
        let found = AppLeftovers.find(for: app, home: box.path, installed: [app], deep: true)
        #expect(Set(found.map { String($0.path.dropFirst(box.path.count + 1)) }) == Set(paths))
        #expect(found.allSatisfy { $0.evidence == .loose && !$0.chosenByDefault })
        for item in found {
            #expect(AppLeftovers.isStillLeftover(item.path, of: app, home: box.path, installed: [app], deep: true))
        }
    }

    @Test func shortNamesRequireAnExactID() throws {
        let box = try Sandbox()
        let app = app("Tiny", id: "org.example.Tiny")
        for path in [".tiny", ".config/tiny", ".config/org.example.Tiny", "Library/Caches/.org.example.Tiny"] {
            try box.file(path + "/state", bytes: 20)
        }
        let found = DeepLeftovers.find(for: app, home: box.path, installed: [app])
        #expect(Set(found.map { String($0.path.dropFirst(box.path.count + 1)) }) == [".config/org.example.Tiny", "Library/Caches/.org.example.Tiny"])
    }

    @Test func aNameSharedByAnotherAppCannotClaimHiddenData() throws {
        let box = try Sandbox()
        let app = app()
        let other = self.app("CANVAS", id: "org.other.Canvas", path: "/synthetic/Other.app")
        for path in [".canvas", ".config/canvas", "Library/Caches/CanvasHelper", ".config/org.example.Canvas"] {
            try box.file(path + "/state", bytes: 20)
        }
        let found = DeepLeftovers.find(for: app, home: box.path, installed: [app, other])
        #expect(found.map(\.path) == [box.path + "/.config/org.example.Canvas"])
        #expect(!DeepLeftovers.isStill(box.path + "/.canvas", of: app, home: box.path, installed: [app, other]))
        #expect(!DeepLeftovers.isStill(box.path + "/Library/Caches/CanvasHelper", of: app, home: box.path, installed: [app, other]))
        let copy = self.app(path: "/synthetic/Copy.app")
        #expect(DeepLeftovers.find(for: app, home: box.path, installed: [app, copy]).isEmpty)
    }

    @Test func linkedSearchRootsAndLinkedEntriesAreNeverFollowed() throws {
        let box = try Sandbox()
        let app = app()
        try box.file("outside/canvas/state", bytes: 20)
        try FileManager.default.createSymbolicLink(atPath: box.path + "/.config", withDestinationPath: box.path + "/outside")
        try FileManager.default.createSymbolicLink(atPath: box.path + "/.canvas", withDestinationPath: box.path + "/outside/canvas")
        #expect(DeepLeftovers.find(for: app, home: box.path, installed: [app]).isEmpty)
        #expect(!DeepLeftovers.isStill(box.path + "/.config/canvas", of: app, home: box.path, installed: [app]))
        #expect(!DeepLeftovers.isStill(box.path + "/.canvas", of: app, home: box.path, installed: [app]))
    }

    @Test func anAppNamedAfterASharedRootCannotClaimThatRoot() throws {
        let box = try Sandbox()
        try box.file(".cache/unrelated/state", bytes: 20)
        let app = app("Cache", id: "org.example.Cache")
        #expect(DeepLeftovers.find(for: app, home: box.path, installed: [app]).isEmpty)
        #expect(!DeepLeftovers.isStill(box.path + "/.cache", of: app, home: box.path, installed: [app]))
    }

    @Test func hiddenEntriesClaimedByAnotherIDAndAppleEntriesStay() throws {
        let box = try Sandbox()
        let app = app()
        let other = self.app("Studio", id: "org.example.Canvas.Pro", path: "/synthetic/Studio.app")
        for name in [".org.example.Canvas.Pro", ".com.apple.canvas"] {
            try box.file("Library/Caches/" + name + "/state", bytes: 20)
        }
        #expect(DeepLeftovers.find(for: app, home: box.path, installed: [app, other]).isEmpty)
    }
}
