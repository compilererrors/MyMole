import Darwin
import Foundation

/// An advisory lock beside a settings file, so two windows or two copies
/// of MyMole read, change and write it one at a time and neither loses the
/// other's change. A removal holds it for as long as it runs, so the list it
/// was checked against can't change under it.
public final class FileLock: @unchecked Sendable {
    /// Why a lock couldn't be taken.
    public enum Failure: LocalizedError {
        case busy
        case unavailable(String)

        public var errorDescription: String? {
            switch self {
            case .busy: "A removal that uses it is running. Try again once it's done."
            case .unavailable(let why): why
            }
        }
    }

    private let fd: Int32
    private var held = true

    /// Takes the lock for `url`, waiting at most `wait` seconds for whoever
    /// holds it, so a long removal elsewhere never stalls the caller.
    public init(_ url: URL, wait: TimeInterval = 0.5) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable(String(cString: strerror(errno))) }
        let deadline = Date().addingTimeInterval(wait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let e = errno
            guard e == EWOULDBLOCK || e == EINTR else {
                close(fd)
                throw Failure.unavailable(String(cString: strerror(e)))
            }
            guard Date() < deadline else {
                close(fd)
                throw Failure.busy
            }
            usleep(20_000)
        }
        self.fd = fd
    }

    public func release() {
        guard held else { return }
        held = false
        flock(fd, LOCK_UN)
        close(fd)
    }

    deinit { release() }

    /// Runs `body` while holding the lock for `url`. Throws when the lock
    /// can't be taken; `body` then doesn't run.
    public static func around<T>(_ url: URL, wait: TimeInterval = 0.5, _ body: () throws -> T) throws -> T {
        let lock = try FileLock(url, wait: wait)
        defer { lock.release() }
        return try body()
    }
}

/// Saved results are written one at a time, in the order they're handed
/// over. A model hands over only its newest finished job, so the newest
/// result is always the one that lands last.
public enum StoreWrites {
    private static let queue = DispatchQueue(label: "mymole.store-writes", qos: .utility)

    public static func submit(_ write: @escaping @Sendable () -> Void) { queue.async(execute: write) }

    /// Waits for the writes handed over so far.
    public static func flush() { queue.sync {} }
}
