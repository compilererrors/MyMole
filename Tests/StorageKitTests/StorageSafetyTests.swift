// Safety checks of the cleanup flows: shared helpers, project gates,
// worktrees, replaced installers, Undo, time limits and credential warnings.
import Darwin
import Foundation
import Synchronization
import Testing

final class StorageSafetyFixture: @unchecked Sendable {
 let root = FileManager.default.temporaryDirectory.appending(path: "mymole-safety-" + UUID().uuidString)
 init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
 deinit { try? FileManager.default.removeItem(at: root) }
 func file(_ rel: String, data: Data = Data(repeating: 65, count: 4096)) throws -> URL {
  let u = root.appending(path: rel)
  try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
  try data.write(to: u)
  return u
 }
 func folder(_ rel: String) throws -> String {
  let u = root.appending(path: rel)
  try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
  return u.path
 }
 func app(_ rel: String, id: String) throws -> AppBundle {
  let d = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier":id], format: .xml, options: 0)
  _ = try file(rel + "/Contents/Info.plist", data: d)
  return AppBundle(path: root.appending(path: rel).path, name: "Synthetic", bundleID: id, version: nil, bytes: 4096, fromAppStore: false)
 }
}

@testable import StorageKit
@Suite struct StorageSafetyTests {
 @Test func sharedEmbeddedHelperMustStay() throws {
  let b = try StorageSafetyFixture()
  let a = try b.app("Applications/Editor.app", id: "com.example.Editor")
  let other = try b.app("Applications/Pro.app", id: "com.example.Pro")
  _ = try b.app("Applications/Editor.app/Contents/Library/LoginItems/Updater.app", id: "com.example.SharedUpdater")
  _ = try b.app("Applications/Pro.app/Contents/Library/LoginItems/Updater.app", id: "com.example.SharedUpdater")
  let cache = try b.file("Library/Caches/com.example.SharedUpdater/data").deletingLastPathComponent().path
  let own = AppIdentity.owned(AppIdentity.of(a), of: a, installed: [a,other])
  let found = AppLeftovers.find(for: a, home: b.root.path, installed: [a,other], identity: own)
  #expect(!found.contains { $0.path == cache })
 }
 @Test func normalProjectEntryMustPassItsActualGate() throws {
  let b = try StorageSafetyFixture()
  let top = try b.folder("Project/build")
  let gate = TrashGate(still: { p in
   (p == top || p.hasPrefix(top + "/")) && Trasher.noLinksBetween(top, and: p)
  })
  #expect(Trasher.clear([top], through: gate).allowed == [top])
 }
 @Test func cleanWorktreeWithKeyMustStay() throws {
  let b = try StorageSafetyFixture()
  _ = try b.file("Worktree/.git/config", data: Data())
  _ = try b.file("Worktree/local.pem")
  let git = CommandRunner(run: { _,_ in (0, "") }, exists: { _ in true })
  #expect(ProjectGuard.reason(for: b.root.appending(path: "Worktree").path, project: b.root.path, worktree: true, runner: git) != nil)
 }
 @Test func replacedInstallerFileMustNotBecomeAcceptedDirectory() throws {
  let b = try StorageSafetyFixture()
  let path = try b.file("Downloads/Setup.dmg").path
  let locations = [InstallerLocation(path: b.root.appending(path: "Downloads").path, depth: 2)]
  let file = try #require(InstallerFinder.find(in: locations).first)
  try FileManager.default.removeItem(atPath: path)
  _ = try b.file("Downloads/Setup.dmg/important.txt")
  #expect(!InstallerFinder.isStillInstaller(file, in: locations))
 }
 @Test func undoMustRefuseRedirectedParent() throws {
  let b = try StorageSafetyFixture()
  let originalParent = try b.folder("Home/Target")
  let outside = try b.folder("OtherData")
  let trashed = try b.file("Bin/item")
  try FileManager.default.removeItem(atPath: originalParent)
  try FileManager.default.createSymbolicLink(atPath: originalParent, withDestinationPath: outside)
  let record = TrashRecord(original: URL(fileURLWithPath: originalParent + "/item"), trashed: trashed)
  #expect(Trasher.restore([record]).count == 1)
  #expect(!FileManager.default.fileExists(atPath: outside + "/item"))
 }
 @Test func timedOutProgramMustNotLeaveItsChildRunning() throws {
  let b = try StorageSafetyFixture()
  let pidFile = b.root.appending(path: "child.pid")
  let command = "/bin/sh -c 'trap \"\" TERM; echo $$ > \"$1\"; exec /bin/sleep 20' synthetic-child '" + pidFile.path + "' & wait"
  let result = CommandRunner.processes(timeLimit: 0.1).run("/bin/sh", ["-c", command])
  let child = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
  defer { kill(child, SIGKILL) }
  #expect(result.code == CommandRunner.timedOut)
  #expect(kill(child, 0) != 0)
 }

 @Test func smallCredentialInsideChosenFolderMustWarn() throws {
  let b = try StorageSafetyFixture()
  _ = try b.file("ToolState/.npmrc")
  let folder = StorageScanner.scan(path: b.root.appending(path: "ToolState").path, workers: 1).root
  #expect(PathRisk.inside(folder) != nil)
 }

}
