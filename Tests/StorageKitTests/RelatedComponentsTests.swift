import Foundation
import Testing

@testable import StorageKit

@Suite struct RelatedComponentsTests {
    @Test func modernAndLegacyUpdatersAreReportedSeparatelyFromBrowserData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("related-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        let system = root.appendingPathComponent("system").path
        func put(_ path: String) throws {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data("synthetic".utf8).write(to: URL(fileURLWithPath: path))
        }
        let userUpdater = home + "/Library/Application Support/Google/GoogleUpdater"
        let legacy = home + "/Library/Google/GoogleSoftwareUpdate"
        let systemUpdater = system + "/Library/Application Support/Google/GoogleUpdater"
        for path in [userUpdater, legacy, systemUpdater] { try put(path + "/example") }
        let job = home + "/Library/LaunchAgents/com.google.GoogleUpdater.wake.plist"
        try put(job)
        try put(home + "/Library/LaunchAgents/com.google.keystoneOther.plist")
        let app = AppBundle(
            path: home + "/Applications/Example.app", name: "Google Chrome", bundleID: "com.google.Chrome", version: nil, bytes: 1,
            fromAppStore: false)
        let report = RelatedComponents.find(for: app, home: home, systemBase: system)
        #expect(Set(report.components.map(\.path)) == Set([userUpdater, legacy, systemUpdater, job]))
        #expect(report.unreadable.isEmpty)
        #expect(RelatedComponents.isChrome(app))
        #expect(!AppLeftovers.isAppsVendorEntry("GoogleUpdater", vendor: "Google", of: app, installed: [app]))
    }

    @Test func linkedLocationsAreNotTraversedAndNonGoogleAppsHaveNoVendorReport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("related-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        let system = root.appendingPathComponent("system").path
        let vendor = home + "/Library/Application Support/Google"
        try FileManager.default.createDirectory(atPath: vendor, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: system + "/Library", withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: vendor + "/GoogleUpdater", withDestinationPath: destination.path)
        let app = AppBundle(
            path: home + "/Applications/Example.app", name: "Example", bundleID: "com.google.Chrome", version: nil, bytes: 1,
            fromAppStore: false)
        let report = RelatedComponents.find(for: app, home: home, systemBase: system)
        #expect(report.components.isEmpty)
        #expect(report.unreadable == [vendor + "/GoogleUpdater"])
        let other = AppBundle(path: app.path, name: "Example", bundleID: "com.example.Browser", version: nil, bytes: 1, fromAppStore: false)
        #expect(RelatedComponents.find(for: other, home: home, systemBase: system).components.isEmpty)
    }
}
