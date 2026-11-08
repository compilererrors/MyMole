import Foundation

/// What launchd has loaded for the user right now, by label, as
/// `launchctl list` says: a job's file only says what should happen, not
/// what is. Read in the direct edition; the App Sandbox can't ask.
public enum LaunchdStatus {
    public enum State: Sendable, Equatable {
        case running(pid: Int32)
        case loaded
    }

    static let launchctl = "/bin/launchctl"

    /// Every job loaded in the user's session, by label; nil when it
    /// couldn't be asked.
    public static func loaded(runner: CommandRunner = .processes(timeLimit: 10)) -> [String: State]? {
        guard runner.exists(launchctl) else { return nil }
        let r = runner.run(launchctl, ["list"])
        guard r.code == 0 else { return nil }
        return parse(r.output)
    }

    /// "PID\tStatus\tLabel" lines; a PID of "-" is loaded but not running.
    static func parse(_ output: String) -> [String: State] {
        var out: [String: State] = [:]
        for line in output.split(whereSeparator: \.isNewline).dropFirst() {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let label = String(parts[2])
            out[label] = Int32(parts[0]).map { .running(pid: $0) } ?? .loaded
        }
        return out
    }
}
