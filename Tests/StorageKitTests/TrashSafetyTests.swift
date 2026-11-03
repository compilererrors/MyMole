// Safety checks of the Trash gate: keep lists that can't be read and
// folders reached through a link.
import Darwin
import Foundation
import Testing
@testable import StorageKit

final class TrashSafetyFixture {
 let root: URL
 init() throws {
  root = FileManager.default.temporaryDirectory.appending(path: "mymole-trash-safety-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
 }
 deinit { try? FileManager.default.removeItem(at: root) }
 func file(_ path: String) throws -> URL {
  let url = root.appending(path: path)
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(repeating: 65, count: 8192).write(to: url)
  return url
 }
}

@Suite struct TrashSafetyTests {
 @Test func unreadableKeepParentMustStopCleanup() throws {
  let box = try TrashSafetyFixture()
  let url = box.root.appending(path: "protected/keep.json")
  try CleanKeepList(paths: ["/synthetic/kept"]).save(to: url)
  let parent = url.deletingLastPathComponent().path
  #expect(chmod(parent, 0) == 0)
  defer { chmod(parent, 0o700) }
  #expect(throws: (any Error).self) { try CleanKeepList.load(from: url) }
 }
 @Test func redirectedAncestorMustNotBeAcceptedAsCache() throws {
  let box = try TrashSafetyFixture()
  let file = try box.file("Home/.npm/_cacache/original")
  let home = box.root.appending(path: "Home").path
  let path = (file.path as NSString).deletingLastPathComponent
  let candidate = try #require(CleanScanner.scan(home: home, workers: 1).first { $0.path == path })
  let other = try box.file("OtherData/_cacache/important")
  try FileManager.default.moveItem(atPath: home + "/.npm", toPath: home + "/old-npm")
  try FileManager.default.createSymbolicLink(atPath: home + "/.npm", withDestinationPath: box.root.appending(path: "OtherData").path)
  #expect(!CleanScanner.isStillCandidate(path, home: home))
  let plan = CleanScanner.trashPaths(for: candidate, keep: CleanKeepList())
  #expect(!plan.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath() == other })
 }
 @Test func knownOtherAppMustKeepItsHTTPStorage() throws {
  let box = try TrashSafetyFixture()
  let file = try box.file("Library/HTTPStorages/com.example.Editor.Pro/state")
  let editor = AppBundle(path: "/synthetic/Editor.app", name: "Editor", bundleID: "com.example.Editor", version: nil, bytes: 1, fromAppStore: false)
  let pro = AppBundle(path: "/synthetic/Pro.app", name: "Pro", bundleID: "com.example.Editor.Pro", version: nil, bytes: 1, fromAppStore: false)
  let found = AppLeftovers.find(for: editor, home: box.root.path, installed: [editor, pro])
  #expect(!found.contains { $0.path == file.deletingLastPathComponent().path })
 }
 @Test func keptDescendantMustProtectProjectArtifact() throws {
  let box = try TrashSafetyFixture()
  let kept = try box.file("Project/node_modules/local-only/state")
  let project = DevProject(path: box.root.appending(path: "Project").path, markers: ["package.json"])
  var rules = ProjectRules()
  rules.keepPaths.insert(kept.deletingLastPathComponent().path)
  let tree = StorageScanner.scan(path: project.path, workers: 1).root
  let items = ProjectArtifacts.items(of: tree, project: project, rules: rules)
  #expect(!items.filter(\.removable).flatMap(\.entries).contains { kept.path.hasPrefix($0.path + "/") })
 }
 @Test func frozenHistoryPointsMustBeSixHoursApart() {
  let t = Date(timeIntervalSince1970: 1_700_000_000)
  var samples: [ProjectStore.Sample] = []
  for seconds in [0.0, 600.0, 21_600.0] {
   samples = ProjectStore.adding(.init(date: t.addingTimeInterval(seconds), bytes: 1), to: samples)
  }
  let frozen = Array(samples.dropLast())
  #expect(!zip(frozen, frozen.dropFirst()).contains { $1.date.timeIntervalSince($0.date) < 21_600 })
 }

}
