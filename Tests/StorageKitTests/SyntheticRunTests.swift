#if DEBUG
import Darwin
import Foundation
import Testing
@testable import StorageKit

@Suite struct SyntheticRunTests {
    final class Box {
        let root: URL
        let token = UUID().uuidString
        private let inode: UInt64
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "mymole-ui-smoke-" + UUID().uuidString)
            for directory in [root, root.appending(path: "home"), root.appending(path: "trash")] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            var st = stat()
            guard lstat(root.path, &st) == 0 else { throw SyntheticRun.Refusal.invalidScope }
            inode = st.st_ino
            try marker(token)
        }
        deinit {
            var st = stat()
            if lstat(root.path, &st) == 0, st.st_ino == inode, st.st_uid == geteuid(), st.st_mode & S_IFMT == S_IFDIR {
                try? FileManager.default.removeItem(at: root)
            }
        }
        func marker(_ value: String) throws {
            let url = root.appending(path: SyntheticRun.marker)
            try JSONSerialization.data(withJSONObject: ["purpose": "mymole-synthetic-run", "token": value]).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        func file(_ relative: String, bytes: Data = Data("synthetic payload".utf8)) throws -> String {
            let url = root.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            return url.path
        }
        func scope() throws -> SyntheticRun { try SyntheticRun(root: root.path, token: token) }
    }

    @Test func movesRealSyntheticBytesAndRestoresThem() throws {
        let box = try Box()
        let file = try box.file("home/nested/payload.bin")
        let before = try Data(contentsOf: URL(fileURLWithPath: file))
        let result = Trasher.moveToTrash([file], through: .init(still: { _ in true }, protections: TrashGate.keepsNothing), backend: .synthetic(try box.scope()))
        #expect(result.moved.count == 1 && result.failed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(try Data(contentsOf: #require(result.moved.first?.trashed)) == before)
        let restored = Trasher.restore(result.moved)
        #expect(restored.isEmpty)
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == before)
    }

    @Test func missingOrWrongOwnershipNeverCreatesAUsableScope() throws {
        let box = try Box()
        #expect(throws: SyntheticRun.Refusal.self) { try SyntheticRun.environment([:]) }
        #expect(throws: SyntheticRun.Refusal.self) { try SyntheticRun(root: box.root.path, token: UUID().uuidString) }
        try box.marker("wrong-token")
        #expect(throws: SyntheticRun.Refusal.self) { try box.scope() }
    }

    @Test func everyEnvironmentPathMustBelongToTheSameOwnedRun() throws {
        let box = try Box(), outside = try Box()
        let scope = try box.scope()
        let valid = ["MYMOLE_SMOKE_ROOT": scope.root, "MYMOLE_SMOKE_TOKEN": box.token,
                     "HOME": scope.home, "CFFIXED_USER_HOME": scope.home, "MYMOLE_SMOKE_HOME": scope.home,
                     "MYMOLE_SMOKE_TRASH": scope.trash, "TMPDIR": scope.root + "/tmp/"]
        #expect(try SyntheticRun.environment(valid).home == scope.home)
        for key in ["HOME", "CFFIXED_USER_HOME", "MYMOLE_SMOKE_HOME", "MYMOLE_SMOKE_TRASH", "TMPDIR"] {
            var changed = valid
            changed[key] = outside.root.path
            #expect(throws: SyntheticRun.Refusal.self) { try SyntheticRun.environment(changed) }
        }
    }

    @Test func systemTemporaryPathAliasesKeepTheSameOwnershipChecks() throws {
        let box = try Box()
        let file = try box.file("home/payload.bin")
        let alias = file.hasPrefix("/private/") ? String(file.dropFirst("/private".count)) : "/private" + file
        let outcome = TrashBackend.synthetic(try box.scope()).moveOne(alias)
        let moved = try #require(outcome.trashed)
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(Trasher.restore([TrashRecord(original: URL(fileURLWithPath: file), trashed: moved)]).isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func anIssuedBackendRechecksOwnershipBeforeEveryMove() throws {
        let box = try Box()
        let file = try box.file("home/payload.bin")
        let backend = TrashBackend.synthetic(try box.scope())
        try box.marker(UUID().uuidString)
        #expect(backend.moveOne(file).trashed == nil)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.root.appending(path: "trash").path).isEmpty)
    }

    @Test func escapesAndLinksAreRejectedWithoutTouchingEitherFixture() throws {
        let box = try Box(), outside = try Box()
        let foreign = try outside.file("home/sentinel.bin")
        let local = try box.file("home/local.bin")
        let backend = TrashBackend.synthetic(try box.scope())
        let link = box.root.appending(path: "home/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.root.appending(path: "home"))
        let leaf = box.root.appending(path: "home/leaf")
        try FileManager.default.createSymbolicLink(atPath: leaf.path, withDestinationPath: foreign)
        for path in [foreign, link.path + "/sentinel.bin", leaf.path, box.root.appending(path: "home").path,
                     box.root.path + "/home/../home/local.bin", box.root.path + "/home//local.bin"] {
            #expect(backend.moveOne(path).trashed == nil)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: foreign)) == Data("synthetic payload".utf8))
        #expect(FileManager.default.fileExists(atPath: local))
    }

    @Test func aReplacedTrashDirectoryCannotRedirectTheDestination() throws {
        let box = try Box(), outside = try Box()
        let file = try box.file("home/payload.bin")
        let backend = TrashBackend.synthetic(try box.scope())
        let trash = box.root.appending(path: "trash")
        try FileManager.default.moveItem(at: trash, to: box.root.appending(path: "original-trash"))
        try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: outside.root.appending(path: "trash"))
        #expect(backend.moveOne(file).trashed == nil)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.root.appending(path: "trash").path).isEmpty)
    }

    @Test func aReplacedHomeDirectoryCannotBecomeAnAuthorizedSource() throws {
        let box = try Box(), outside = try Box()
        let foreign = try outside.file("home/sentinel.bin")
        let backend = TrashBackend.synthetic(try box.scope())
        let home = box.root.appending(path: "home")
        try FileManager.default.moveItem(at: home, to: box.root.appending(path: "original-home"))
        try FileManager.default.createSymbolicLink(at: home, withDestinationURL: outside.root.appending(path: "home"))
        #expect(backend.moveOne(home.appending(path: "sentinel.bin").path).trashed == nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: foreign)) == Data("synthetic payload".utf8))
    }
}
#endif
