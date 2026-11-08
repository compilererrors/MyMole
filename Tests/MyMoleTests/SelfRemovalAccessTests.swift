import Foundation
import Testing

@testable import MyMole

@MainActor @Suite struct SelfRemovalAccessTests {
    @Test func cancellationOrAnotherAppNeverGrantsAccess() {
        let own = "/synthetic/Applications/Cleaner.app"
        var started = 0
        let cancelled = SelfRemovalAccess(choose: { _ in nil }, start: { _ in started += 1; return true }, stop: { _ in })
        #expect(!cancelled.acquire(path: own))
        let other = SelfRemovalAccess(choose: { _ in URL(fileURLWithPath: "/synthetic/Applications/Other.app") },
                                      start: { _ in started += 1; return true }, stop: { _ in })
        #expect(!other.acquire(path: own) && started == 0)
    }

    @Test func onlyStartedScopesAreReleasedAndNeverTwice() {
        var opened = 0, closed = 0
        let access = SelfRemovalAccess(choose: { $0 }, start: { _ in opened += 1; return true }, stop: { _ in closed += 1 })
        #expect(access.acquire(path: "/synthetic/Applications/Cleaner.app"))
        #expect(access.acquire(path: "/synthetic/Applications/Cleaner.app"))
        #expect(opened == 2 && closed == 1)
        access.release()
        access.release()
        #expect(closed == 2)
        let alreadyAccessible = SelfRemovalAccess(choose: { $0 }, start: { _ in false }, stop: { _ in closed += 1 })
        #expect(alreadyAccessible.acquire(path: "/synthetic/Applications/Cleaner.app"))
        alreadyAccessible.release()
        #expect(closed == 2)
    }
}
