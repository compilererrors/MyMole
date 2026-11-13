import Darwin
import Foundation
import Testing

/// Fixtures remain inside the runner's leased root. Only the runner removes
/// them, through the descriptor-based cleanup guard after all children exit.
func uiFixtureDirectory() throws -> URL {
    let env = ProcessInfo.processInfo.environment
    try #require(env["MYMOLE_GUARDED_TEST"] == "1")
    let temporary = URL(fileURLWithPath: try #require(env["TMPDIR"])).resolvingSymlinksInPath()
    let envelope = temporary.deletingLastPathComponent()
    try #require(temporary.lastPathComponent == "tmp" && envelope.lastPathComponent.hasPrefix("mymole-guarded-test-"))
    var info = stat()
    try #require(lstat(envelope.appending(path: ".mymole-test-lease").path, &info) == 0)
    try #require(info.st_uid == geteuid() && info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o077 == 0)
    let directory = temporary.appending(path: "mymole-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
}
