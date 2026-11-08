import Foundation
import Testing

@testable import StorageKit

@Suite struct PackagesTests {
    @Test func homebrewAndReceiptsAreReadWithoutRunningAnything() throws {
        let box = try Sandbox()
        try box.file("brew/Cellar/wget/1.24/bin/wget", bytes: 5_000)
        try box.file("brew/Cellar/wget/1.25/bin/wget", bytes: 5_000)
        try box.file("brew/Caskroom/editor/2.0/Editor.app.zip", bytes: 9_000)
        try box.folder("receipts")
        let receipt: NSDictionary = ["PackageIdentifier": "com.vendor.driver", "PackageVersion": "3.1", "InstallDate": Date(timeIntervalSince1970: 1_000)]
        try receipt.write(to: box.url.appending(path: "receipts/com.vendor.driver.plist"))
        let apple: NSDictionary = ["PackageIdentifier": "com.apple.pkg.Thing"]
        try apple.write(to: box.url.appending(path: "receipts/com.apple.pkg.Thing.plist"))

        let found = Packages.list(prefixes: [box.path + "/brew", box.path + "/missing"], receipts: box.path + "/receipts")
        #expect(!found.noHomebrew && found.unreadable.isEmpty)
        let by = Dictionary(uniqueKeysWithValues: found.packages.map { ($0.id, $0) })
        #expect(by["formula:wget"]?.versions == ["1.24", "1.25"] && (by["formula:wget"]?.bytes ?? 0) > 0)
        #expect(by["cask:editor"] != nil)
        #expect(by["receipt:com.vendor.driver"]?.versions == ["3.1"])
        // macOS's own aren't listed.
        #expect(by["receipt:com.apple.pkg.Thing"] == nil)
    }

    @Test func noHomebrewIsSaid() throws {
        let box = try Sandbox()
        try box.folder("receipts")
        let found = Packages.list(prefixes: [box.path + "/none"], receipts: box.path + "/receipts")
        #expect(found.noHomebrew && found.packages.isEmpty)
    }
}
