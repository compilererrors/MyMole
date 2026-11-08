import Foundation
import Testing

@testable import MyMole

#if APPSTORE
/// The App Store edition's folder access, with bookmarks and the folder
/// panel replaced: a bookmark here is just the folder's path, and nothing
/// real is opened or saved outside the test's own preferences.
@MainActor
@Suite struct FolderAccessTests {
    @MainActor final class Fake {
        var chosen: URL?
        var revoked = Set<String>()
        var stale = Set<String>()
        var leadsTo: [String: String] = [:]
        var stopped: [String] = []
        var made = 0

        var bookmarks: FolderAccess.Bookmarks {
            FolderAccess.Bookmarks(
                resolve: { data in
                    let path = String(decoding: data, as: UTF8.self)
                    return (URL(fileURLWithPath: self.leadsTo[path] ?? path), self.stale.contains(path))
                },
                startAccessing: { !self.revoked.contains($0.path) },
                stopAccessing: { self.stopped.append($0.path) },
                make: { self.made += 1; return Data($0.path.utf8) },
                choose: { _ in self.chosen })
        }
    }

    let dir = FileManager.default.temporaryDirectory.appending(path: "access-\(UUID().uuidString)")

    @Test func nothingIsOpenUntilChosenAndAChoiceLasts() {
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = Fake()
        let defaults = testDefaults(in: dir)
        let access = FolderAccess(defaults: defaults, bookmarks: fake.bookmarks)
        #expect(access.granted.isEmpty && access.needsHome)
        fake.chosen = URL(fileURLWithPath: FolderAccess.Place.applications.path)
        access.request(.applications)
        #expect(access.has(.applications) && access.lastProblem == nil)
        let granted = access.generation
        access.revoke(.applications)
        #expect(!access.has(.applications) && access.generation > granted && granted > 0)
        access.request(.applications)
        // Next launch: the saved bookmark opens it again.
        #expect(FolderAccess(defaults: defaults, bookmarks: fake.bookmarks).has(.applications))
    }

    @Test func anotherFolderIsRefused() {
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = Fake()
        let access = FolderAccess(defaults: testDefaults(in: dir), bookmarks: fake.bookmarks)
        fake.chosen = URL(fileURLWithPath: "/Applications/Utilities")
        access.request(.applications)
        #expect(!access.has(.applications) && access.lastProblem != nil && fake.made == 0)
    }

    @Test func aBookmarkThatMovedOrWasRevokedIsDropped() {
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = Fake()
        let defaults = testDefaults(in: dir)
        let access = FolderAccess(defaults: defaults, bookmarks: fake.bookmarks)
        fake.chosen = URL(fileURLWithPath: "/Applications")
        access.request(.applications)
        fake.leadsTo["/Applications"] = "/Volumes/Other/Applications"
        #expect(!FolderAccess(defaults: defaults, bookmarks: fake.bookmarks).has(.applications))
        #expect(defaults.data(forKey: "access.bookmark.applications") == nil)

        fake.leadsTo = [:]
        access.request(.applications)
        fake.revoked = ["/Applications"]
        #expect(!FolderAccess(defaults: defaults, bookmarks: fake.bookmarks).has(.applications))
    }

    @Test func aStaleBookmarkIsRenewedAndRevokeClosesIt() {
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = Fake()
        let defaults = testDefaults(in: dir)
        let access = FolderAccess(defaults: defaults, bookmarks: fake.bookmarks)
        fake.chosen = URL(fileURLWithPath: "/Applications")
        access.request(.applications)
        fake.stale = ["/Applications"]
        let made = fake.made
        let again = FolderAccess(defaults: defaults, bookmarks: fake.bookmarks)
        #expect(again.has(.applications) && fake.made == made + 1)
        again.revoke(.applications)
        #expect(!again.has(.applications) && fake.stopped == ["/Applications"])
        #expect(defaults.data(forKey: "access.bookmark.applications") == nil)
    }
}
#endif

@MainActor
@Suite struct TakeBackTests {
    @Test func aChainStopsBetweenStepsOnceAccessChanges() async {
        var generation = 0
        var ran: [Int] = []
        let started = generation
        await AppModel.run([
            { ran.append(1) },
            { ran.append(2); generation += 1 },
            { ran.append(3) },
        ], while: { generation == started })
        #expect(ran == [1, 2])
    }

    @Test func aScanStartedDuringTheWaitIsStoppedBeforeTheFolderCloses() async {
        var scanning = true
        var stops = 0
        var waits = 0
        await AppModel.settle(
            stop: { stops += 1 },
            wait: {
                waits += 1
                // The first wait ends with a scan the user started
                // meanwhile; the second finds it stopped.
                if waits == 2 { scanning = false }
            },
            while: { scanning })
        #expect(stops == 2 && waits == 2 && !scanning)
    }

    @Test func aScanThatReportsItsEndLateIsWaitedFor() async {
        var scanning = true
        let report = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            scanning = false
        }
        await AppModel.settle(stop: {}, wait: {}, while: { scanning })
        #expect(!scanning)
        await report.value
    }

    @Test func aChainWaitsForAScanTheUserStarted() async {
        var userScanning = true
        var ran: [Int] = []
        let chain = Task { @MainActor in
            await AppModel.run([{ ran.append(1) }, { ran.append(2) }], while: { true }, waitingWhile: { userScanning })
        }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(ran.isEmpty)
        userScanning = false
        await chain.value
        #expect(ran == [1, 2])
    }
}

