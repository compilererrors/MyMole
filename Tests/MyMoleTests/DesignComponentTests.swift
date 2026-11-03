import Foundation
import Testing

@testable import MyMole

@Suite struct BreakableTests {
    @Test func breaksOnlyAfterNameSeparators() {
        let zw = "\u{200B}"
        #expect(Breakable.text("tree-sitter_cpp.v2") == "tree-\(zw)sitter_\(zw)cpp.\(zw)v2")
        // A leading dot stays with its name, in a name or a path.
        #expect(Breakable.text(".rustup") == ".rustup")
        #expect(Breakable.text("~/.cache/x") == "~/\(zw).cache/\(zw)x")
        // Plain words are left whole.
        #expect(Breakable.text("Documents") == "Documents")
        // Removing the markers gives back the exact original text.
        let name = "Storebench-0.1.0-universal.dmg"
        #expect(Breakable.text(name).replacingOccurrences(of: zw, with: "") == name)
    }

    @Test func pathsShowHomeAsTilde() {
        let home = NSHomeDirectory()
        let zw = "\u{200B}"
        #expect(Breakable.path(home) == "~")
        #expect(Breakable.path(home + "/Library/Caches").replacingOccurrences(of: zw, with: "") == "~/Library/Caches")
        #expect(Breakable.path("/opt/homebrew").replacingOccurrences(of: zw, with: "") == "/opt/homebrew")
    }
}
