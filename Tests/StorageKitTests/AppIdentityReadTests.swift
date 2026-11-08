import Darwin
import Foundation
import Security
import Testing

@testable import StorageKit

private final class IdentityCodeFixture: NSObject {}

@Suite struct AppIdentityReadTests {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "identity-" + UUID().uuidString)
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }
        func put(_ relative: String, data: Data) throws {
            let file = root.appending(path: relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        func app(_ relative: String, id: String) throws -> AppBundle {
            try put(
                relative + "/Contents/Info.plist",
                data: PropertyListSerialization.data(
                    fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0))
            return AppBundle(
                path: root.appending(path: relative).path, name: "Example", bundleID: id, version: nil, bytes: 1, fromAppStore: false)
        }
    }

    @Test func absentOptionalFoldersAreEmptyAndAnUnreadableFolderIsUnknown() throws {
        let fixture = try Fixture()
        let app = try fixture.app("Example.app", id: "com.example.Editor")
        #expect(AppIdentity.carried(atPath: app.path) == [])
        #expect(AppIdentity.carried(atPath: fixture.root.appending(path: "Missing.app").path) == nil)
        let helpers = app.path + "/Contents/Helpers"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        #expect(chmod(helpers, 0) == 0)
        defer { _ = chmod(helpers, 0o755) }
        #expect(AppIdentity.carried(atPath: app.path) == nil)
    }

    @Test func hiddenHelpersAndBrokenBundleMetadataAreNotSkipped() throws {
        let fixture = try Fixture()
        let app = try fixture.app("Example.app", id: "com.example.Editor")
        let helper = "Example.app/Contents/Helpers/.Background.app"
        _ = try fixture.app(helper, id: "com.example.SharedHelper")
        #expect(AppIdentity.carried(atPath: app.path) == ["com.example.SharedHelper"])
        try fixture.put(helper + "/Contents/Info.plist", data: Data("broken".utf8))
        #expect(AppIdentity.carried(atPath: app.path) == nil)
    }

    @Test func nestedHelpersAndTheirGroupClaimsAreIncluded() throws {
        let fixture = try Fixture()
        let app = try fixture.app("Example.app", id: "com.example.Editor")
        let wrapper = "Example.app/Contents/Helpers/Wrapper.app"
        _ = try fixture.app(wrapper, id: "com.example.Wrapper")
        _ = try fixture.app(wrapper + "/Contents/XPCServices/Inner.xpc", id: "com.example.Inner")
        #expect(AppIdentity.carried(atPath: app.path) == ["com.example.Wrapper", "com.example.Inner"])
        let group = "ABCDE12345.com.example.shared"
        #expect(AppIdentity.groupClaims(app.path, reader: { $0.hasSuffix("Inner.xpc") ? [group] : [] }) == [group])
        #expect(AppIdentity.groupClaims(app.path, reader: { $0.hasSuffix("Inner.xpc") ? nil : [] }) == nil)
    }

    @Test func aTreeBeyondTheSupportedDepthIsUnknown() throws {
        let fixture = try Fixture()
        let app = try fixture.app("Example.app", id: "com.example.Editor")
        var relative = "Example.app"
        for index in 0..<9 {
            relative += "/Contents/Helpers/Nested.app"
            _ = try fixture.app(relative, id: "com.example.Nested\(index)")
        }
        #expect(AppIdentity.carried(atPath: app.path) == nil)
    }

    @Test func ownershipInventoryIncludesHiddenAppsAndRejectsBrokenMetadata() throws {
        let fixture = try Fixture()
        let hidden = try fixture.app("Applications/.Hidden.APP", id: "org.other.Hidden")
        let folder = fixture.root.appending(path: "Applications").path
        #expect(AppFinder.installedNow(in: [folder])?.map(\.bundleID) == [hidden.bundleID])
        try fixture.put("Applications/Broken.app/Contents/Info.plist", data: Data("broken".utf8))
        #expect(AppFinder.installedNow(in: [folder]) == nil)
        try fixture.put("Applications/Broken.app/Contents/Info.plist", data: Data(repeating: 32, count: 1_048_577))
        #expect(AppIdentity.bundleInfo(atPath: fixture.root.appending(path: "Applications/Broken.app").path) == nil)
    }

    @Test func linksAndNonRegularMetadataDoNotBecomeOwnerInformation() throws {
        let fixture = try Fixture()
        let app = try fixture.app("Example.app", id: "com.example.Editor")
        _ = try fixture.app("Outside.app", id: "com.example.SharedHelper")
        let helpers = app.path + "/Contents/Helpers"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: helpers + "/Helper.app", withDestinationPath: fixture.root.appending(path: "Outside.app").path)
        #expect(AppIdentity.carried(atPath: app.path) == nil)
        try FileManager.default.removeItem(atPath: helpers + "/Helper.app")
        let info = helpers + "/Helper.app/Contents/Info.plist"
        try FileManager.default.createDirectory(atPath: (info as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        #expect(mkfifo(info, 0o600) == 0)
        #expect(AppIdentity.carried(atPath: app.path) == nil)
    }

    @Test func malformedAndOversizedJobPlistsAreUnknown() throws {
        let fixture = try Fixture()
        let app = try fixture.app("Example.app", id: "com.example.Editor")
        let plist = "Example.app/Contents/Library/LaunchAgents/.job.plist"
        try fixture.put(
            plist, data: PropertyListSerialization.data(fromPropertyList: ["Label": "com.example.SharedAgent"], format: .xml, options: 0))
        #expect(AppIdentity.carried(atPath: app.path) == ["com.example.SharedAgent"])
        try fixture.put(plist, data: Data(repeating: 32, count: 1_048_577))
        #expect(AppIdentity.carried(atPath: app.path) == nil)
    }

    @Test func emptyEntitlementsAndUnreadableOrMalformedEntitlementsAreDifferent() throws {
        let key = kSecCodeInfoEntitlementsDict as String
        #expect(AppIdentity.signedGroups([:]) == [])
        #expect(AppIdentity.signedGroups([key: [:]]) == [])
        #expect(AppIdentity.signedGroups([key: "broken"]) == nil)
        #expect(AppIdentity.signedGroups([key: ["com.apple.security.application-groups": [1, 2]]]) == nil)
        #expect(AppIdentity.signedGroups([key: ["com.apple.security.application-groups": ["invalid\0group"]]]) == nil)
        let fixture = try Fixture()
        #expect(AppIdentity.entitlementGroups(fixture.root.appending(path: "Missing.app").path) == nil)
    }

    @Test func theBuiltSyntheticTestBundleHasKnownSigningMetadata() throws {
        let bundle = Bundle(for: IdentityCodeFixture.self)
        try #require(bundle.bundleURL.pathExtension == "xctest")
        let executable = try #require(bundle.executablePath)
        // XCTest's wrapper isn't an app bundle. Inspect our Mach-O outside
        // that ambiguous wrapper; no external executable is used or run.
        let fixture = try Fixture()
        let code = fixture.root.appending(path: "synthetic-code")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: executable), to: code)
        #expect(AppIdentity.entitlementGroups(code.path) == [])
    }

    @Test func unknownCompetingHelpersNeverBecomeExclusiveOwnership() {
        let app = AppBundle(
            path: "/synthetic/Editor.app", name: "Editor", bundleID: "com.example.Editor", version: nil, bytes: 1, fromAppStore: false)
        let other = AppBundle(
            path: "/synthetic/Other.app", name: "Other", bundleID: "org.other.Tool", version: nil, bytes: 1, fromAppStore: false)
        let identity = AppIdentity(helperIDs: ["com.example.SharedHelper"])
        let unknown = AppIdentity.Readers(carried: { _ in nil }, groups: { _ in [] })
        #expect(AppIdentity.owned(identity, of: app, installed: [app, other], readers: unknown) == nil)
        let shared = AppIdentity.Readers(carried: { _ in ["com.example.SharedHelper"] }, groups: { _ in [] })
        #expect(AppIdentity.owned(identity, of: app, installed: [app, other], readers: shared)?.helperIDs == [])
    }

    @Test func groupsSharedAcrossVendorsStayAndUnknownGroupOwnersBlockAttribution() {
        let app = AppBundle(
            path: "/synthetic/Editor.app", name: "Editor", bundleID: "com.example.Editor", version: nil, bytes: 1, fromAppStore: false)
        let other = AppBundle(
            path: "/synthetic/Other.app", name: "Other", bundleID: "org.other.Tool", version: nil, bytes: 1, fromAppStore: false)
        let group = "ABCDE12345.com.example.shared"
        let identity = AppIdentity(groups: [group])
        let shared = AppIdentity.Readers(carried: { _ in [] }, groups: { _ in [group] })
        #expect(AppIdentity.owned(identity, of: app, installed: [app, other], readers: shared)?.groups == [])
        let unknown = AppIdentity.Readers(carried: { _ in [] }, groups: { _ in nil })
        #expect(AppIdentity.owned(identity, of: app, installed: [app, other], readers: unknown) == nil)
    }

    @Test func appleGroupsAreNotAttributedToAThirdPartyApp() {
        let app = AppBundle(
            path: "/synthetic/Editor.app", name: "Editor", bundleID: "com.example.Editor", version: nil, bytes: 1, fromAppStore: false)
        let readers = AppIdentity.Readers(
            carried: { _ in [] }, groups: { _ in ["group.com.apple.example", "ABCDE12345.com.apple.example", "group.com.example.shared"] })
        #expect(AppIdentity.of(app, readers: readers)?.groups == ["group.com.example.shared"])
    }
}
