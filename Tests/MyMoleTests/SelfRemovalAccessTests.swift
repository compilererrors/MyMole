import Foundation
import Testing

@testable import MyMole

@MainActor @Suite struct SelfRemovalAccessTests {
    @Test func nonFileAndDecoratedURLsCannotGrantSelfRemovalAccess() {
        let own = "/synthetic/Applications/Cleaner.app"
        for text in ["https://example.invalid/Applications/Cleaner.app", "file:///synthetic/Applications/Cleaner.app?other=1", "file:///synthetic/Applications/Cleaner.app#other"] {
            var starts = 0
            let access = AppBundleAccess(choose: { _ in URL(string: text) }, start: { _ in starts += 1; return true }, stop: { _ in })
            #expect(!access.acquire(path: own) && starts == 0 && access.url == nil)
        }
    }
    @Test func cancellationOrAnotherAppNeverGrantsAccess() {
        let own = "/synthetic/Applications/Cleaner.app"
        var started = 0
        let cancelled = AppBundleAccess(choose: { _ in nil }, start: { _ in started += 1; return true }, stop: { _ in })
        #expect(!cancelled.acquire(path: own))
        let other = AppBundleAccess(choose: { _ in URL(fileURLWithPath: "/synthetic/Applications/Other.app") },
                                      start: { _ in started += 1; return true }, stop: { _ in })
        #expect(!other.acquire(path: own) && started == 0)
    }

    @Test func onlyStartedScopesAreReleasedAndNeverTwice() {
        var opened = 0, closed = 0
        let access = AppBundleAccess(choose: { $0 }, start: { _ in opened += 1; return true }, stop: { _ in closed += 1 })
        #expect(access.acquire(path: "/synthetic/Applications/Cleaner.app"))
        #expect(access.acquire(path: "/synthetic/Applications/Cleaner.app"))
        #expect(opened == 2 && closed == 1)
        access.release()
        access.release()
        #expect(closed == 2)
        let alreadyAccessible = AppBundleAccess(choose: { $0 }, start: { _ in false }, stop: { _ in closed += 1 })
        #expect(alreadyAccessible.acquire(path: "/synthetic/Applications/Cleaner.app"))
        #expect(alreadyAccessible.url?.path == "/synthetic/Applications/Cleaner.app")
        alreadyAccessible.release()
        #expect(closed == 2 && alreadyAccessible.url == nil)
    }

    @Test func choosingAnotherAppAfterAGrantClosesTheOldScopeAndKeepsNoURL() {
        var selections = [URL(fileURLWithPath: "/synthetic/Applications/Editor.app"), URL(fileURLWithPath: "/synthetic/Applications/Other.app")]
        var closed = 0
        let access = AppBundleAccess(choose: { _ in selections.removeFirst() }, start: { _ in true }, stop: { _ in closed += 1 })
        #expect(access.acquire(path: "/synthetic/Applications/Editor.app"))
        #expect(!access.acquire(path: "/synthetic/Applications/Editor.app"))
        #expect(closed == 1 && access.url == nil)
    }
}
