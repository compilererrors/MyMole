#if DEBUG
import CryptoKit
import Darwin
import Foundation
import StorageKit
import Testing

/// Destructive E2E cases cannot be constructed by a plain `swift test` run.
/// The dedicated runner must first prove its outside canary is unwritable.
final class EndToEndFixture: @unchecked Sendable {
    enum Refusal: Error { case runnerMissing, canaryMissing, canaryWritable, sandboxNotVerified }
    let root: URL
    let scope: SyntheticRun
    let protections: UserProtections
    let jobs = TrashJobs()
    private let inode: UInt64
    var home: String { scope.home }
    var log: URL { root.appending(path: "history.json") }
    var backend: TrashBackend { .synthetic(scope) }

    init() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MYMOLE_E2E"] == "1", env["MYMOLE_GUARDED_TEST"] == "1",
              let parent = env["MYMOLE_E2E_ROOT"], let token = env["MYMOLE_E2E_TOKEN"],
              let canary = env["MYMOLE_E2E_CANARY"], canary.hasPrefix("/private/tmp/mymole-e2e-canary-") else { throw Refusal.runnerMissing }
        guard try String(contentsOfFile: canary, encoding: .utf8) == token else { throw Refusal.canaryMissing }
        _ = try SyntheticRun(root: parent, token: token)
        ProcessInfo.processInfo.processName = "mymole-e2e-" + token.replacingOccurrences(of: "-", with: "")
        let fd = open(canary, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 { close(fd); throw Refusal.canaryWritable }
        guard errno == EPERM || errno == EACCES else { throw Refusal.sandboxNotVerified }
        root = URL(fileURLWithPath: parent).appending(path: "cases/mymole-ui-smoke-" + UUID().uuidString)
        for directory in [root, root.appending(path: "home"), root.appending(path: "trash")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let own = UUID().uuidString
        let marker = root.appending(path: SyntheticRun.marker)
        try JSONSerialization.data(withJSONObject: ["purpose": "mymole-synthetic-run", "token": own]).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        scope = try SyntheticRun(root: root.path, token: own)
        protections = UserProtections(root: root.appending(path: "protections"))
        var st = stat()
        guard lstat(root.path, &st) == 0 else { throw SyntheticRun.Refusal.invalidScope }
        inode = st.st_ino
    }

    deinit {
        var st = stat()
        if lstat(root.path, &st) == 0, st.st_ino == inode, st.st_uid == geteuid(), st.st_mode & S_IFMT == S_IFDIR {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @discardableResult func file(_ relative: String, data: Data = Data(repeating: 37, count: 8192)) throws -> String {
        guard !relative.hasPrefix("/"), relative.split(separator: "/").allSatisfy({ $0 != ".." && $0 != "." }) else { throw SyntheticRun.Refusal.invalidScope }
        let url = URL(fileURLWithPath: home).appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url.path
    }

    func plist(_ relative: String, _ contents: [String: Any]) throws -> String {
        try file(relative, data: PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0))
    }

    func app() throws -> String {
        _ = try file("Applications/Synthetic Editor.app/Contents/MacOS/SyntheticEditor")
        _ = try plist("Applications/Synthetic Editor.app/Contents/Info.plist", [
            "CFBundleIdentifier": "com.example.SyntheticEditor", "CFBundleName": "Synthetic Editor",
            "CFBundleExecutable": "SyntheticEditor", "CFBundleVersion": "1", "CFBundlePackageType": "APPL"
        ])
        return home + "/Applications/Synthetic Editor.app"
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    func contents() throws -> [String: String] {
        var output: [String: String] = [:]
        let base = URL(fileURLWithPath: home)
        let enumerator = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator {
            var st = stat()
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
            output[String(url.path.dropFirst(home.count + 1))] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        return output
    }

    @MainActor func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "SyntheticE2ETimeout", code: 1)
    }
}
#endif
