// Safety checks of what runs as root: staging, partial removals and the
// ownership of system-wide helpers.
import Darwin
import Foundation
import Synchronization
import Testing
import StorageKit

final class PrivilegedSafetyFixture: @unchecked Sendable {
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

@testable import PrivilegedKit
@Suite struct PrivilegedSafetyTests {
 @Test func cleanupMustNotDeleteUnselectedStagingContent() throws {
  let b = try PrivilegedSafetyFixture()
  let pending = try b.file("Caches/.mymole-removing/previous-selection")
  _ = chmod(pending.deletingLastPathComponent().path, 0o700)
  let chosen = try b.file("Caches/selected")
  let roots = [SystemCleanRules.Root(path: b.root.appending(path: "Caches").path, reason: "Synthetic")]
  _ = SystemCleanRules.remove([chosen.path], roots: roots)
  #expect(FileManager.default.fileExists(atPath: pending.path))
 }
 @Test func failedRemovalMustNotSilentlyRelocateRemainder() throws {
  let b = try PrivilegedSafetyFixture()
  let rel = "Caches/chosen/" + Array(repeating: "a", count: 258).joined(separator: "/") + "/remaining"
  _ = try b.file(rel)
  let original = b.root.appending(path: "Caches/chosen").path
  let roots = [SystemCleanRules.Root(path: b.root.appending(path: "Caches").path, reason: "Synthetic")]
  let report = SystemCleanRules.remove([original], roots: roots)
  #expect(report.failed[original] != nil)
  #expect(FileManager.default.fileExists(atPath: original))
 }
 @Test func installedLongerAppMustKeepSystemHelper() throws {
  let b = try PrivilegedSafetyFixture()
  _ = try b.app("Applications/Pro.app", id: "com.example.Editor.Pro")
  let helper = try b.file("Library/PrivilegedHelperTools/com.example.Editor.Pro")
  let runner = CommandRunner(run: { _,_ in (0, "") }, exists: { _ in true })
  let report = SystemLeftovers.remove([helper.path], appID: "com.example.Editor", ids: ["com.example.Editor"], base: b.root.path, runner: runner)
  #expect(report.removed.isEmpty)
  #expect(FileManager.default.fileExists(atPath: helper.path))
 }
}
