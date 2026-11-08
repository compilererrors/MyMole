import Foundation
import Testing

@testable import StorageKit

/// Ground truth is a separate resource: findings, default choices, and paths
/// that must stay. No real apps are launched and no files are removed.
@Suite struct UninstallCorpusTests {
    private struct Corpus: Decodable {
        let version: Int
        let cases: [Case]
    }
    private struct Case: Decodable {
        let id: String
        let deep: Bool
        let apps: [App]
        let files: [String]
        let links: [String: String]
        let expected: [Expected]
        let mustKeep: [String]
        let blocked: Bool
    }
    private struct App: Decodable {
        let key: String
        let name: String
        let bundleID: String
        let helpers: [String]
        let nestedHelpers: [String]?
        let groups: [String]?
    }
    private struct Expected: Decodable {
        let path: String
        let evidence: String
        let chosen: Bool
    }
    private struct Metrics: Encodable {
        var version = 1
        var cases = 0
        var truePositives = 0
        var falsePositives = 0
        var falseNegatives = 0
        var blockedUnknownOwners = 0
        var unsafeDefaultChoices = 0
        var protectedPathHits = 0
    }

    @Test func findingsAndDefaultChoicesMatchIndependentGroundTruth() throws {
        let resource = try #require(Bundle.module.url(forResource: "UninstallCorpus", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: resource))
        try #require(corpus.version == 1 && !corpus.cases.isEmpty)
        #expect(Set(corpus.cases.map(\.id)).count == corpus.cases.count)
        var metrics = Metrics()
        for entry in corpus.cases { try check(entry, metrics: &metrics) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        print("uninstall-corpus " + String(decoding: try encoder.encode(metrics), as: UTF8.self))
    }

    private func check(_ entry: Case, metrics: inout Metrics) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "uninstall-corpus-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func url(_ relative: String) throws -> URL {
            try #require(!relative.hasPrefix("/") && !relative.split(separator: "/").contains("..") && !relative.contains("\0"))
            return root.appending(path: relative)
        }
        func put(_ relative: String, _ data: Data) throws {
            let file = try url(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        var apps: [AppBundle] = []
        var groupClaims: [String: [String]] = [:]
        for app in entry.apps {
            let relative = "Applications/" + app.key + ".app"
            try put(
                relative + "/Contents/Info.plist",
                PropertyListSerialization.data(
                    fromPropertyList: ["CFBundleIdentifier": app.bundleID, "CFBundleName": app.name], format: .xml, options: 0))
            for (index, id) in app.helpers.enumerated() {
                try put(
                    relative + "/Contents/XPCServices/Helper\(index).xpc/Contents/Info.plist",
                    PropertyListSerialization.data(
                        fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0))
            }
            for (index, id) in (app.nestedHelpers ?? []).enumerated() {
                try put(
                    relative + "/Contents/XPCServices/Helper0.xpc/Contents/XPCServices/Nested\(index).xpc/Contents/Info.plist",
                    PropertyListSerialization.data(
                        fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0))
            }
            let path = try url(relative).path
            if let groups = app.groups { groupClaims[path] = groups }
            apps.append(AppBundle(path: path, name: app.name, bundleID: app.bundleID, version: nil, bytes: 1, fromAppStore: false))
        }
        for file in entry.files { try put(file, Data("synthetic corpus data".utf8)) }
        for (link, destination) in entry.links {
            try FileManager.default.createSymbolicLink(at: url(link), withDestinationURL: url(destination))
        }
        let target = try #require(apps.first { $0.path.hasSuffix("/target.app") })
        let claims = groupClaims
        let readers = AppIdentity.Readers(groups: { claims[$0] })
        metrics.cases += 1
        let identity = AppIdentity.owned(for: target, installed: apps, readers: readers)
        if entry.blocked {
            #expect(identity == nil, "\(entry.id): unknown ownership must block attribution")
            metrics.blockedUnknownOwners += identity == nil ? 1 : 0
            return
        }
        let owned = try #require(identity, "\(entry.id): fixture ownership must be known")
        let found = AppLeftovers.find(for: target, home: root.path, installed: apps, identity: owned, deep: entry.deep)
        let byPath = Dictionary(found.map { (String($0.path.dropFirst(root.path.count + 1)), $0) }, uniquingKeysWith: { first, _ in first })
        let actual = Set(byPath.keys)
        let expected = Set(entry.expected.map(\.path))
        metrics.truePositives += actual.intersection(expected).count
        metrics.falsePositives += actual.subtracting(expected).count
        metrics.falseNegatives += expected.subtracting(actual).count
        #expect(actual == expected, "\(entry.id): unexpected or missing leftover paths")
        for expectation in entry.expected {
            guard let item = byPath[expectation.path] else { continue }
            #expect(item.evidence.rawValue == expectation.evidence, "\(entry.id): attribution evidence")
            #expect(item.chosenByDefault == expectation.chosen, "\(entry.id): default removal choice")
            if item.chosenByDefault && !expectation.chosen { metrics.unsafeDefaultChoices += 1 }
            #expect(
                AppLeftovers.isStillLeftover(item.path, of: target, home: root.path, installed: apps, identity: owned, deep: entry.deep))
        }
        for kept in entry.mustKeep {
            let hits = actual.filter { kept == $0 || kept.hasPrefix($0 + "/") }
            metrics.protectedPathHits += hits.count
            #expect(hits.isEmpty, "\(entry.id): a protected witness is covered by a removal candidate")
        }
    }
}
