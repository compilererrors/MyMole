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
    /// Exit code when the output was larger than the runner reads: it was
    /// stopped, and what it printed isn't used.
    public static let outputTooLarge: Int32 = -4
    /// Exit code when the program ended but something it started kept its
    /// output open: the output may be cut short, so it isn't used.
    public static let outputUnfinished: Int32 = -5
    /// What one program may print: far more than any reply MyMole reads.
    public static let standardOutputLimit = 32 << 20

    /// Every maintenance program finishes well within this; one that
    /// doesn't is stuck, and waiting on it would hold the helper forever.
    public static let live = processes(timeLimit: 15 * 60)

    /// Runs real programs, each in a process group of its own. One that runs
    /// past `timeLimit` seconds is stopped with everything it started: the
    /// group is asked to quit, then killed, and only reported stopped once
    /// no member is left.
    public static func processes(
        timeLimit: TimeInterval, grace: TimeInterval = 3, outputLimit: Int = standardOutputLimit, drain: TimeInterval = 5
    ) -> CommandRunner {
        #if SMOKE
        return CommandRunner(run: { _, _ in (-1, "External programs are disabled in synthetic test builds.") }, exists: { _ in false })
        #else
        CommandRunner(
            run: { exe, args in
                ProcessGroup.run(exe, args, timeLimit: timeLimit, grace: grace, outputLimit: outputLimit, drain: drain)
            },
            exists: { FileManager.default.isExecutableFile(atPath: $0) })
        #endif
    }
}

enum ProcessGroup {
    static func run(
        _ exe: String, _ args: [String], timeLimit: TimeInterval, grace: TimeInterval,
        outputLimit: Int = CommandRunner.standardOutputLimit, drain: TimeInterval = 5
    ) -> (code: Int32, output: String) {
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

        // Read while it runs, so a full pipe can't stall the program, up to
        // `outputLimit`: past it the group is stopped and nothing is used.
        let output = Mutex((data: Data(), overflow: false))
        let read = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: read) {
            defer { close(readFD) }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = Darwin.read(readFD, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return }
                let over = output.withLock { o -> Bool in
                    guard o.data.count + n <= outputLimit else {
                        o.overflow = true
                        return true
                    }
                    o.data.append(contentsOf: buffer[..<n])
                    return false
                }
                if over {
                    killpg(pid, SIGKILL)
                    return
                }
            }
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
        // A child left holding the pipe mustn't hold the reply too: it's
        // stopped with its group, and the cut-short output isn't used.
        if read.wait(timeout: .now() + drain) == .timedOut {
            killpg(pid, SIGKILL)
            _ = read.wait(timeout: .now() + 1)
            // Closing the pipe can precede the child's actual termination.
            guard groupGone(pid, within: grace) else {
                return (CommandRunner.stopUnverified, "Its output stayed open; part of it may still be running.")
            }
            return (CommandRunner.outputUnfinished, "Something it started kept its output open, so the output wasn't used.")
        }
        if output.withLock({ $0.overflow }) {
            return (CommandRunner.outputTooLarge, "It printed more than \(outputLimit >> 20) MB, so it was stopped and its output wasn't used.")
        }
        let s = status.withLock { $0 } ?? 0
        let code: Int32 = (s & 0x7f) == 0 ? (s >> 8) & 0xff : -(s & 0x7f)
        return (code, String(decoding: output.withLock { $0.data }, as: UTF8.self))
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
