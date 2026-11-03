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
