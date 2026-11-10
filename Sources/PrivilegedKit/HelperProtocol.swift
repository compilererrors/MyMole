import Darwin
import Foundation
import StorageKit

// MyMole's privileged tool: a program inside the app that macOS runs as root
// for one request at a time, after the user enters an administrator's
// password. Nothing is installed or left running. The request travels as
// JSON (base64 on the command line), so no object graph from the app is
// decoded as root, and the tool checks every path against its own rules.
// Only the direct edition carries the tool; the App Store edition has none.

/// What the app may ask the tool to do.
public enum PrivilegedRequest: Codable, Sendable, Equatable {
    /// `MaintenanceTask` raw values; only root tasks are run.
    case maintenance(tasks: [String], dryRun: Bool)
    /// System caches and logs; any path `keep` protects (itself, inside a
    /// kept item or holding one) is refused at the moment it would go.
    case removeSystem(paths: [String], keep: [String])
    /// What an uninstalled app left system-wide, checked against
    /// `SystemLeftovers` for `appID` and `ids` again.
    case removeLeftovers(paths: [String], appID: String, ids: [String])
    /// Exactly one verified app, moved between Applications and the active
    /// user's private Trash. No permanent deletion or arbitrary destination.
    case applicationTrash(ApplicationTrash.Request, restoring: Bool)
}

/// A request and the version of the tool it was written for.
public struct PrivilegedEnvelope: Codable, Sendable, Equatable {
    public let version: String
    public let request: PrivilegedRequest

    public init(version: String = PrivilegedTool.version, request: PrivilegedRequest) {
        self.version = version
        self.request = request
    }
}

/// What the tool answers: the result of the request, or why it refused.
public enum PrivilegedReply: Codable, Sendable, Equatable {
    case reports([TaskReport])
    case removal(RemovalReport)
    case refused(String)
    case applicationTrash(ApplicationTrash.Receipt)
    case applicationTrashRefusal(ApplicationTrash.Failure)
}

public enum PrivilegedTool {
    /// The tool and the app ship in one bundle; a mismatch means a tool from
    /// another build was asked, which is refused.
    public static let version = "8"
    public static let name = "MyMoleHelper"

    /// The command-line argument for `envelope`.
    public static func argument(for envelope: PrivilegedEnvelope) -> String {
        (try? JSONEncoder().encode(envelope))?.base64EncodedString() ?? ""
    }

    /// Held by the copy of the tool at work. macOS starts one copy per
    /// request, so two windows or two instances of the app could otherwise
    /// remove or stage at the same time.
    public static let lockPath = "/var/run/mymole-helper.lock"

    /// Runs one request given as the tool's argument and returns the reply.
    /// Nothing runs unless the request reads, matches this version, the
    /// tool really is root and no other copy of it is at work.
    public static func handle(
        argument: String, isRoot: Bool = geteuid() == 0, runner: CommandRunner = .live, lockPath: String = lockPath
    ) -> PrivilegedReply {
        guard let data = Data(base64Encoded: argument),
            let envelope = try? JSONDecoder().decode(PrivilegedEnvelope.self, from: data)
        else { return .refused("The request couldn't be read.") }
        guard envelope.version == version else {
            return .refused("The request was written for version \(envelope.version); this tool is version \(version).")
        }
        guard isRoot else { return .refused("The tool must run as root.") }
        guard let lock = ToolLock(path: lockPath) else {
            return .refused("Another MyMole system task is still running, so nothing was changed.")
        }
        defer { lock.release() }
        switch envelope.request {
        case .maintenance(let tasks, let dryRun):
            let engine = MaintenanceEngine(role: .root, home: "/var/root", runner: runner)
            let wanted = tasks.compactMap(MaintenanceTask.init(rawValue:)).filter(\.needsRoot)
            return .reports(wanted.map { dryRun ? engine.check($0) : engine.run($0) })
        case .removeSystem(let paths, let keep):
            return .removal(SystemCleanRules.remove(paths, keep: CleanKeepList(paths: Set(keep))))
        case .removeLeftovers(let paths, let appID, let ids):
            return .removal(SystemLeftovers.remove(paths, appID: appID, ids: ids, runner: runner))
        case .applicationTrash(let request, let restoring):
            do { return .applicationTrash(try ApplicationTrash.move(request, restoring: restoring)) }
            catch let failure as ApplicationTrash.Failure { return .applicationTrashRefusal(failure) }
            catch { return .refused(error.localizedDescription) }
        }
    }

    /// The reply as the tool prints it: one line of JSON.
    public static func output(_ reply: PrivilegedReply) -> String {
        (try? JSONEncoder().encode(reply)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// The reply from what the tool printed.
    public static func reply(from output: String) -> PrivilegedReply? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return try? JSONDecoder().decode(PrivilegedReply.self, from: Data(line.utf8))
    }
}

/// An exclusive lock on a file only the tool's own user may own, held for
/// one request. Released when the tool ends, however it ends.
struct ToolLock {
    private let fd: Int32

    /// Nil when another copy holds it, or the file isn't a plain file of
    /// this user's that only they can write.
    init?(path: String) {
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == geteuid(), st.st_nlink == 1,
            st.st_mode & 0o022 == 0, flock(fd, LOCK_EX | LOCK_NB) == 0
        else {
            close(fd)
            return nil
        }
        self.fd = fd
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
