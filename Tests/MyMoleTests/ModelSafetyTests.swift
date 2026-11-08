// Safety checks of the cleanup models: keep lists that can't be read and
// uninstalls that run at the same time.
import Darwin
import Foundation
import Synchronization
import Testing
import StorageKit
import PrivilegedKit

final class ModelSafetyFixture: @unchecked Sendable {
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

@testable import MyMole
@MainActor @Suite(.serialized) struct ModelSafetyTests {
 @Test func unreadableKeepMustNotBeOverwritten() throws {
  let b = try ModelSafetyFixture()
  let url = try b.file("keep.json", data: Data("broken existing protection list".utf8))
  let before = try Data(contentsOf: url)
  let model = DeepCleanModel(home: b.root.path, base: b.root.appending(path: "store"), keepURL: url, logURL: b.root.appending(path: "history.json"), runningApps: { [] }, runningTools: { [] }, projectRules: b.root.appending(path: "projects"), quietFor: 0)
  #expect(model.keepError != nil)
  model.keepAlways(["/synthetic/new-protection"])
  #expect(try Data(contentsOf: url) == before)
 }
 @Test func concurrentUninstallsMustNotBothReachRecycle() async throws {
  let b = try ModelSafetyFixture()
  let a = try b.app("Applications/Editor.app", id: "com.example.Editor")
  let second = try b.app("Applications/Player.app", id: "com.example.Player")
  let started = Mutex(0)
  let release = DispatchSemaphore(value: 0)
  var calls = 0
  let model = AppsModel(home: b.root.path, folders: [b.root.appending(path: "Applications").path], base: b.root.appending(path: "store"), logURL: b.root.appending(path: "history.json"), recycle: { paths in
   calls += 1
   try? await Task.sleep(for: .milliseconds(150))
   return TrashOutcome(moved: paths.map { TrashRecord(original: URL(fileURLWithPath: $0), trashed: b.root.appending(path: "FakeBin/" + UUID().uuidString)) }, failed: [])
  }, isRunning: { _ in false }, otherCopies: { _ in
   started.withLock { $0 += 1 }
   _ = release.wait(timeout: .now() + 5)
   return []
  }, system: .init(base: b.root.appending(path: "System").path, isReady: { false }, remove: { _,_,_ in RemovalReport() }),
   protections: UserProtections(root: b.root.appending(path: "support")))
  let first = Task { await model.uninstall(a, leftovers: []) }
  let next = Task { await model.uninstall(second, leftovers: []) }
  for _ in 0..<200 {
   if started.withLock({ $0 }) == 2 { break }
   try await Task.sleep(for: .milliseconds(5))
  }
  release.signal(); release.signal()
  _ = await first.value; _ = await next.value
  #expect(calls == 1)
 }
}
