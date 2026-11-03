import Darwin
import Foundation

// What a project folder may hold that must never go to the Trash with it:
// another Git repository, key files a project deploys with, files the
// project's own Git tracks, or an agent worktree's uncommitted work. Checked
// right before a move; anything that can't be checked stays.

public enum ProjectGuard {
    /// Key files, by name and extension.
    static let keyNames: Set<String> = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
    static let keyExtensions: Set<String> = ["pem", "key", "p12", "pfx", "p8", "jks", "keystore"]

    /// Third-party code: test keys shipped inside packages aren't the project's.
    static let thirdParty: Set<String> = ["node_modules", "Pods", ".venv", "venv", "site-packages", "vendor"]

    /// Where Git may be installed. `/usr/bin/git` is left out: without the
    /// developer tools it asks the user to install them.
    static let gitLocations = [
        "/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        "/opt/homebrew/bin/git", "/usr/local/bin/git",
    ]

    /// Why `path` must stay, or nil when it may go. `worktree` is for agent
    /// worktrees, which are Git checkouts of their own: their own `.git` is
    /// expected, but key files and other repositories inside still keep them,
    /// even when Git ignores those files and reports the tree clean.
    public static func reason(
        for path: String, project: String, worktree: Bool = false, runner: CommandRunner = .processes(timeLimit: 30)
    ) -> String? {
        if let r = scan(path, ownGit: worktree) { return r }
        if worktree { return uncommitted(path, runner: runner) }
        return tracked(path, project: project, runner: runner)
    }

    /// A nested repository or key file inside, without following links.
    /// `ownGit` lets the `.git` right inside `path` be, as a worktree's own.
    static func scan(_ path: String, ownGit: Bool = false) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return "It's gone or can't be read." }
        if (path as NSString).lastPathComponent == ".git" { return "It's a Git repository." }
        guard st.st_mode & S_IFMT == S_IFDIR else { return isKey((path as NSString).lastPathComponent) ? "It's a key file." : nil }
        var stack: [(String, Bool)] = [(path, thirdParty.contains((path as NSString).lastPathComponent))]
        while let (dir, inThirdParty) = stack.popLast() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                return "A folder inside can't be read, so it couldn't be checked."
            }
            for name in names {
                let p = dir + "/" + name
                if name == ".git" {
                    if ownGit && dir == path { continue }
                    return "Holds a Git repository."
                }
                guard lstat(p, &st) == 0 else { continue }
                if st.st_mode & S_IFMT == S_IFDIR {
                    stack.append((p, inThirdParty || thirdParty.contains(name)))
                } else if !inThirdParty, isKey(name) {
                    return "Holds key files."
                }
            }
        }
        return nil
    }

    /// Key files, and local secret files such as `.env`, which Git usually
    /// ignores and so never shows as uncommitted.
    static func isKey(_ name: String) -> Bool {
        keyNames.contains(name) || keyExtensions.contains((name as NSString).pathExtension.lowercased())
            || ((name == ".env" || name.hasPrefix(".env.")) && !envTemplates.contains(name))
    }

    /// Committed examples of a `.env` file, without secrets.
    static let envTemplates: Set<String> = [".env.example", ".env.sample", ".env.template", ".env.dist"]

    static func git(_ runner: CommandRunner) -> String? { gitLocations.first(where: runner.exists) }

    /// Put before every command: a repository's settings can't start an
    /// fsmonitor program while Git reads the index.
    static let safety = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]

    /// The setting files Git reads for the repository at `dir`, a checkout
    /// or a worktree whose `.git` is a file naming its folder. Nil when the
    /// `.git` can't be made sense of.
    static func configFiles(of dir: String) -> [String]? {
        let dotGit = dir + "/.git"
        var st = stat()
        guard lstat(dotGit, &st) == 0 else { return nil }
        var gitDir = dotGit
        if st.st_mode & S_IFMT == S_IFREG {
            guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8), text.hasPrefix("gitdir: ") else { return nil }
            let named = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = named.hasPrefix("/") ? named : dir + "/" + named
        } else if st.st_mode & S_IFMT != S_IFDIR {
            return nil
        }
        var files = [gitDir + "/config", gitDir + "/config.worktree"]
        if let common = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8) {
            let c = common.trimmingCharacters(in: .whitespacesAndNewlines)
            let commonDir = c.hasPrefix("/") ? c : gitDir + "/" + c
            files += [commonDir + "/config", commonDir + "/config.worktree"]
        }
        return files
    }

    /// Whether any of `files` makes Git run a program while it reads the
    /// working tree: a content filter, or an include that could bring one
    /// in. A file that's there but can't be read counts as one.
    static func runsPrograms(_ files: [String]) -> Bool {
        files.contains { file in
            guard FileManager.default.fileExists(atPath: file) else { return false }
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return true }
            return text.lowercased().split(whereSeparator: \.isNewline).contains { line in
                let l = line.trimmingCharacters(in: .whitespaces)
                return l.hasPrefix("[filter") || l.hasPrefix("[include")
            }
        }
    }

    /// Why Git won't be asked about `dir`, if it won't.
    static func untrusted(_ dir: String) -> String? {
        guard let files = configFiles(of: dir) else { return "Its Git folder couldn't be read, so it wasn't checked." }
        return runsPrograms(files) ? "Its Git settings could run programs, so it wasn't checked." : nil
    }

    /// Files under `path` that the enclosing repository tracks.
    static func tracked(_ path: String, project: String, runner: CommandRunner) -> String? {
        guard let repo = enclosingRepository(of: path, within: project) else { return nil }
        guard let git = git(runner) else { return "Git isn't installed, so tracked files couldn't be checked." }
        if let why = untrusted(repo) { return why }
        let rel = String(path.dropFirst(repo.count + 1))
        let r = runner.run(git, safety + ["-C", repo, "ls-files", "-z", "--", rel])
        guard r.code == 0 else { return "Git couldn't check it for tracked files." }
        // Each tracked file ends in a NUL; warnings on the same output don't.
        return r.output.contains("\0") ? "Holds files Git tracks." : nil
    }

    /// The nearest folder above `path`, up to `project`, with a `.git` in it.
    static func enclosingRepository(of path: String, within project: String) -> String? {
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > 1 {
            if FileManager.default.fileExists(atPath: dir + "/.git") { return dir }
            if dir == project { return nil }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func uncommitted(_ path: String, runner: CommandRunner) -> String? {
        guard let git = git(runner) else { return "Git isn't installed, so uncommitted work couldn't be checked." }
        if let why = untrusted(path) { return why }
        let r = runner.run(git, safety + ["--no-optional-locks", "-C", path, "status", "--porcelain", "-z", "--untracked-files=normal"])
        guard r.code == 0 else { return "Git couldn't check it for uncommitted work." }
        return r.output.contains("\0") ? "Has uncommitted work." : nil
    }
}
