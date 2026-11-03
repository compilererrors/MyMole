import Darwin
import Foundation
import Synchronization

/// Runs a program and returns its exit code and output. Injected so tests
/// never run real system programs.
public struct CommandRunner: Sendable {
    public var run: @Sendable (_ executable: String, _ arguments: [String]) -> (code: Int32, output: String)
    public var exists: @Sendable (_ executable: String) -> Bool

    public init(
        run: @escaping @Sendable (String, [String]) -> (code: Int32, output: String),
        exists: @escaping @Sendable (String) -> Bool
    ) {
        self.run = run
        self.exists = exists
    }

    /// Exit code of a program stopped for running past its time limit.
    public static let timedOut: Int32 = -2
    /// Exit code when a program ran past its limit and part of it may still
    /// be running: something it started left its process group.
    public static let stopUnverified: Int32 = -3

    /// Every maintenance program finishes well within this; one that
    /// doesn't is stuck, and waiting on it would hold the helper forever.
    public static let live = processes(timeLimit: 15 * 60)

    /// Runs real programs, each in a process group of its own. One that runs
    /// past `timeLimit` seconds is stopped with everything it started: the
    /// group is asked to quit, then killed, and only reported stopped once
    /// no member is left.
    public static func processes(timeLimit: TimeInterval, grace: TimeInterval = 3) -> CommandRunner {
        CommandRunner(
            run: { exe, args in ProcessGroup.run(exe, args, timeLimit: timeLimit, grace: grace) },
            exists: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}

enum ProcessGroup {
    static func run(_ exe: String, _ args: [String], timeLimit: TimeInterval, grace: TimeInterval) -> (code: Int32, output: String) {
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { return (-1, String(cString: strerror(errno))) }
        let (readFD, writeFD) = (pipeFDs[0], pipeFDs[1])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // A group of its own, so the program and whatever it starts can be
        // stopped together; nothing else of ours leaks into it.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
        let environment: [String] = ["LC_ALL=C", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var spawnedPID: pid_t = 0
        let spawned = posix_spawn(&spawnedPID, exe, &actions, &attr, argv, envp)
        let pid = spawnedPID
        close(writeFD)
        guard spawned == 0 else {
            close(readFD)
            return (-1, String(cString: strerror(spawned)))
        }

        // Read while it runs, so a full pipe can't stall the program.
        let output = Mutex(Data())
        let read = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: read) {
            let d = FileHandle(fileDescriptor: readFD, closeOnDealloc: true).readDataToEndOfFile()
            output.withLock { $0 = d }
        }
        let status = Mutex<Int32?>(nil)
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            var s: Int32 = 0
            while waitpid(pid, &s, 0) < 0 && errno == EINTR {}
            status.withLock { $0 = s }
            exited.signal()
        }

        guard exited.wait(timeout: .now() + timeLimit) == .success else {
            killpg(pid, SIGTERM)
            _ = exited.wait(timeout: .now() + grace)
            // Whatever is left in the group, the program itself included,
            // didn't quit when asked.
            if !groupGone(pid, within: grace) { killpg(pid, SIGKILL) }
            exited.wait()
            let gone = groupGone(pid, within: grace)
            _ = read.wait(timeout: .now() + 1)
            return gone
                ? (CommandRunner.timedOut, "Stopped after running for more than \(Int(timeLimit)) seconds.")
                : (CommandRunner.stopUnverified, "Ran for more than \(Int(timeLimit)) seconds; part of it may still be running.")
        }
        // A child left holding the pipe mustn't hold the reply too.
        _ = read.wait(timeout: .now() + 5)
        let s = status.withLock { $0 } ?? 0
        let code: Int32 = (s & 0x7f) == 0 ? (s >> 8) & 0xff : -(s & 0x7f)
        return (code, String(decoding: output.withLock { $0 }, as: UTF8.self))
    }

    /// Whether no process is left in group `pgid`, waiting up to `within`.
    static func groupGone(_ pgid: pid_t, within: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(within)
        repeat {
            if killpg(pgid, 0) != 0 && errno == ESRCH { return true }
            usleep(20_000)
        } while Date() < deadline
        return false
    }
}
