import Foundation
import Testing

@testable import StorageKit

/// The deeper search, in a Library and home folder of the test's own.
@Suite struct DeepLeftoversTests {
    let app = AppBundle(
        path: "/synthetic/Applications/Bartender 6.app", name: "Bartender 6", bundleID: "com.surteesstudios.Bartender", version: nil,
        bytes: 1, fromAppStore: false)

    @Test func aLooserMatchAndHiddenFoldersAreFoundAndNeverChosen() throws {
        let box = try Sandbox()
        for rel in [
            "Library/Application Support/BartenderHelper/state", "Library/Caches/Vendor Tools/bartender-cache/c",
            "Library/Preferences/bartender.settings.plist", ".bartender/config", ".config/bartender/settings.json",
            ".cache/Bartender/blob", "Library/Application Support/com.apple.bartender/x",
            "Library/Application Support/Bartender Pro Thing/x",
        ] {
            try box.file(rel, bytes: 200)
        }
        let other = AppBundle(path: "/synthetic/Applications/Bartender Pro Thing.app", name: "Bartender Pro Thing", bundleID: "com.other.thing", version: nil, bytes: 1, fromAppStore: false)
        let found = AppLeftovers.find(for: app, home: box.path, installed: [app, other], deep: true)
        let rel = Set(found.map { String($0.path.dropFirst(box.path.count + 1)) })
        #expect(rel.isSuperset(of: [
            "Library/Application Support/BartenderHelper", "Library/Caches/Vendor Tools/bartender-cache",
            "Library/Preferences/bartender.settings.plist", ".bartender", ".config/bartender", ".cache/Bartender",
        ]))
        // Never Apple's, and never what another installed app's name is in.
        #expect(!rel.contains("Library/Application Support/com.apple.bartender"))
        #expect(!rel.contains("Library/Application Support/Bartender Pro Thing"))
        #expect(found.allSatisfy { $0.evidence == .loose && !$0.chosenByDefault })
        #expect(found.first { $0.path.hasSuffix(".cache/Bartender") }?.kind == .rebuildable)
        for l in found { #expect(AppLeftovers.isStillLeftover(l.path, of: app, home: box.path, installed: [app, other], deep: true), "\(l.path)") }
        // The usual check never lets them through.
        #expect(!AppLeftovers.isStillLeftover(box.path + "/.bartender", of: app, home: box.path, installed: [app, other]))
        // Off, none of it.
        #expect(AppLeftovers.find(for: app, home: box.path, installed: [app, other]).isEmpty)
    }

    @Test func aShortNameIsNotLookedFor() throws {
        let box = try Sandbox()
        try box.file(".notes/x", bytes: 10)
        let short = AppBundle(path: "/synthetic/Applications/Note.app", name: "Note", bundleID: "com.vendor.Note", version: nil, bytes: 1, fromAppStore: false)
        #expect(DeepLeftovers.find(for: short, home: box.path, installed: [short]).isEmpty)
        #expect(DeepLeftovers.key("Bartender 6") == "bartender" && DeepLeftovers.key("1Password 8") == "1password")
    }
}
