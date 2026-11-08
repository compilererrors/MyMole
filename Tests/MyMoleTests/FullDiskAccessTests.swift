import Foundation
import Testing

@testable import MyMole

@Suite struct FullDiskAccessStateTests {
    @Test func grantedRefusedAndUnknownAreToldApart() {
        let none = CocoaError(.fileReadNoSuchFile)
        let refused = CocoaError(.fileReadNoPermission)
        #expect(FullDiskAccess.state(home: "/synthetic") { _ in } == .granted)
        #expect(FullDiskAccess.state(home: "/synthetic") { _ in throw refused } == .denied)
        #expect(FullDiskAccess.state(home: "/synthetic") { _ in throw none } == .unknown)
        // The first conclusive probe decides.
        var calls = 0
        let state = FullDiskAccess.state(home: "/synthetic") { _ in
            calls += 1
            if calls == 1 { throw none }
            throw refused
        }
        #expect(state == .denied && calls == 2)
    }
}
