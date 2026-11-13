#if !APPSTORE
import Foundation
import Security
import StorageKit
import Testing

@testable import PrivilegedKit

@Suite struct HelperServiceIdentityTests {
    @Test func requirementsUseExactIdentifiersAndRejectUnsignedOrDebugPeers() throws {
        let identity = try #require(HelperServiceIdentity(appID: "com.example.Cleaner", teamID: "AB12CD34EF"))
        #expect(identity.serviceID == "com.example.Cleaner.helper")
        #expect(identity.plistName == "com.example.Cleaner.helper.plist")
        for helper in [true, false] {
            let text = identity.requirement(helper: helper)
            #expect(text.contains("anchor apple generic"))
            #expect(text.contains("certificate leaf[subject.OU] = \"AB12CD34EF\""))
            #expect(text.contains("!entitlement[\"com.apple.security.get-task-allow\"] exists"))
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
            #expect(requirement != nil)
        }
    }

    @Test func identityValuesCannotInjectARequirement() {
        for id in ["", "com.example.\" or true", "com.example/Other", "com.example\nOther"] {
            #expect(HelperServiceIdentity(appID: id, teamID: "AB12CD34EF") == nil)
        }
        for team in ["", "AB12CD34EF\"", "ab12cd34ef", "SHORT"] {
            #expect(HelperServiceIdentity(appID: "com.example.Cleaner", teamID: team) == nil)
        }
    }

    @Test func onlyTheActiveNonSystemUserIsAccepted() {
        #expect(HelperServiceIdentity.acceptsUser(501, consoleUID: 501))
        #expect(!HelperServiceIdentity.acceptsUser(0, consoleUID: 0))
        #expect(!HelperServiceIdentity.acceptsUser(500, consoleUID: 500))
        #expect(!HelperServiceIdentity.acceptsUser(501, consoleUID: 502))
        #expect(!HelperServiceIdentity.acceptsUser(501, consoleUID: nil))
    }

    @Test func appMovesAreBoundToTheAuthenticatedUser() {
        let identity = Trasher.Identity(type: 0, device: 0, inode: 0)
        let request = ApplicationTrash.Request(path: "/Applications/Synthetic.app", bundleID: "com.example.Synthetic",
            identity: identity, parentIdentity: identity, uid: 501, trashName: "Synthetic.app")
        for restoring in [true, false] {
            let argument = PrivilegedTool.argument(for: .init(request: .applicationTrash(request, restoring: restoring)))
            #expect(HelperServiceIdentity.acceptsRequest(argument, uid: 501))
            #expect(!HelperServiceIdentity.acceptsRequest(argument, uid: 502))
        }
    }

    @Test func malformedOversizedAndOldRequestsAreRefusedBeforeExecution() {
        #expect(!HelperServiceIdentity.acceptsRequest("garbage", uid: 501))
        #expect(!HelperServiceIdentity.acceptsRequest(String(repeating: "A", count: 1_048_577), uid: 501))
        let old = PrivilegedTool.argument(for: .init(version: "0", request: .removeSystem(paths: [], keep: [])))
        #expect(!HelperServiceIdentity.acceptsRequest(old, uid: 501))
        let current = PrivilegedTool.argument(for: .init(request: .removeSystem(paths: [], keep: [])))
        #expect(HelperServiceIdentity.acceptsRequest(current, uid: 501))
    }
}
#endif
