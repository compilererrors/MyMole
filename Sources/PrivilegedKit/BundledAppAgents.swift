import Darwin
import Foundation
import StorageKit

/// Stops only active per-user agents whose plist, executable and launchd PID
/// all belong to the exact app being uninstalled. Never signals arbitrary PIDs,
/// disables jobs, stops daemons, or executes a program named by the request.
enum BundledAppAgents {
    struct Process: Equatable {
        let pid: Int32
        let uid: uid_t
        let started: Int64
        let microseconds: Int32
        let relativePath: String
    }
    struct Agent: Equatable {
        let label: String
        let relativeProgram: String
        let plist: String
        let identity: Trasher.Identity
    }
    struct Plan: Equatable {
        let agent: Agent
        let process: Process
    }
    static let launchctl = "/bin/launchctl"

    static func stop(_ request: ApplicationTrash.Request, owner: uid_t,
                     runner: CommandRunner = .processes(timeLimit: 10, outputLimit: 1 << 20),
                     readProcesses: (String) -> [Process]? = processes,
                     pause: () -> Void = { usleep(50_000) }) throws {
        let work = try plan(request, owner: owner, runner: runner, readProcesses: readProcesses)
        for item in work {
            // A reused PID, replaced app or changed job never authorizes bootout.
            guard Trasher.identity(of: request.path) == request.identity,
                  try agents(in: request.path, bundleID: request.bundleID, owner: owner).contains(item.agent),
                  let current = readProcesses(request.path), current.contains(item.process),
                  loaded(uid: request.uid, runner: runner)?[item.agent.label] == .running(pid: item.process.pid) else {
                throw ApplicationTrash.Failure(.backgroundUnverified, "A background agent changed. The app stayed in place. Reopen the app if an earlier agent was stopped.")
            }
            let result = runner.run(launchctl, ["bootout", "gui/\(request.uid)/" + item.agent.label])
            guard result.code == 0 || result.code == 3 || result.code == 113 else {
                throw ApplicationTrash.Failure(.backgroundStopFailed, "The app's background agent couldn't be stopped (launchctl \(result.code)). The app stayed in place. Reopen the app if an earlier agent was stopped.")
            }
        }
        // bootout may answer before termination finishes. This bounded wait is
        // off the main thread; no force quit or global process-name matching.
        for _ in 0..<60 {
            guard let current = readProcesses(request.path) else {
                throw ApplicationTrash.Failure(.processUnknown, "Background processes couldn't be checked after stopping the agents. The app stayed in place.")
            }
            if current.isEmpty { return }
            pause()
        }
        throw ApplicationTrash.Failure(.backgroundStillRunning, "A background process is still running after its agent was stopped. The app stayed in place.")
    }

    /// Planning is read-only and never stops a job.
    static func plan(_ request: ApplicationTrash.Request, owner: uid_t, runner: CommandRunner,
                     readProcesses: (String) -> [Process]?) throws -> [Plan] {
        guard Trasher.identity(of: request.path) == request.identity else {
            throw ApplicationTrash.Failure(.appChanged, "The app changed. Nothing was moved.")
        }
        guard let current = readProcesses(request.path) else {
            throw ApplicationTrash.Failure(.processUnknown, "Running processes couldn't be checked. Nothing was moved.")
        }
        guard !current.isEmpty else { return [] }
        let candidates = try agents(in: request.path, bundleID: request.bundleID, owner: owner)
        guard current.count <= 16, current.allSatisfy({ process in
            process.uid == request.uid && candidates.contains { $0.relativeProgram == process.relativePath }
        }) else {
            throw ApplicationTrash.Failure(.backgroundUnverified, "The app has a running process that isn't a verified bundled agent. Quit the app and its background processes before uninstalling.")
        }
        guard let loaded = loaded(uid: request.uid, runner: runner) else {
            throw ApplicationTrash.Failure(.processUnknown, "The app's loaded background agents couldn't be checked. Nothing was moved.")
        }
        var work: [Plan] = []
        for process in current {
            let matches = candidates.filter { $0.relativeProgram == process.relativePath && loaded[$0.label] == .running(pid: process.pid) }
            guard matches.count == 1, let agent = matches.first,
                  !work.contains(where: { $0.agent.label == agent.label }) else {
                throw ApplicationTrash.Failure(.backgroundUnverified, "A running background process couldn't be tied to this app's loaded agent. Nothing was moved.")
            }
            work.append(Plan(agent: agent, process: process))
        }
        return work
    }

    static func listArguments(uid: uid_t, caller: uid_t) -> [String] {
        caller == uid ? ["list"] : ["asuser", String(uid), launchctl, "list"]
    }

    private static func loaded(uid: uid_t, runner: CommandRunner) -> [String: LaunchdStatus.State]? {
        let query = CommandRunner(run: { _, _ in runner.run(launchctl, listArguments(uid: uid, caller: geteuid())) },
                                  exists: { _ in runner.exists(launchctl) })
        return LaunchdStatus.loaded(runner: query)
    }

    static func agents(in path: String, bundleID: String, owner: uid_t) throws -> [Agent] {
        let root = try ApplicationTrash.directory(path)
        defer { close(root) }
        guard let contents = safeDirectory(root, relative: "Contents", owner: owner) else { return [] }
        defer { close(contents) }
        let metadata = try ApplicationTrash.read(contents, "Info.plist", owner: owner)
        guard let info = try PropertyListSerialization.propertyList(from: metadata, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID,
              let main = info["CFBundleExecutable"] as? String else { return [] }
        let mainProgram = ("Contents/MacOS/" + main).lowercased()
        let folder = "Contents/Library/LaunchAgents"
        guard let jobs = safeDirectory(root, relative: folder, owner: owner) else { return [] }
        defer { close(jobs) }
        guard let dir = fdopendir(dup(jobs)) else { throw ApplicationTrash.Failure(.backgroundUnverified, "The app's bundled agents couldn't be read.") }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
            guard names.count <= 128 else { throw ApplicationTrash.Failure(.backgroundUnverified, "The app has too many bundled agent entries to verify safely.") }
        }
        var result: [Agent] = []
        for name in names.sorted() where name.hasSuffix(".plist") {
            let data = try ApplicationTrash.read(jobs, name, owner: owner)
            guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = info["Label"] as? String, AppLeftovers.isWellFormed(label),
                  !label.lowercased().hasPrefix("com.apple."),
                  label == bundleID || label.hasPrefix(bundleID + "."),
                  let program = info["BundleProgram"] as? String,
                  program.hasPrefix("Contents/"), Trasher.isPlainPath("/" + program),
                  program.lowercased() != mainProgram,
                  info["Program"] == nil, info["UserName"] == nil, info["GroupName"] == nil,
                  let binaryParent = safeDirectory(root, relative: (program as NSString).deletingLastPathComponent, owner: owner)
            else { continue }
            defer { close(binaryParent) }
            var st = stat(), definition = stat()
            guard fstatat(binaryParent, (program as NSString).lastPathComponent, &st, AT_SYMLINK_NOFOLLOW) == 0,
                  st.st_mode & S_IFMT == S_IFREG, st.st_mode & 0o111 != 0, st.st_mode & 0o022 == 0, st.st_uid == owner,
                  fstatat(jobs, name, &definition, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            result.append(Agent(label: label, relativeProgram: program, plist: folder + "/" + name,
                identity: .init(type: definition.st_mode & S_IFMT, device: definition.st_dev, inode: definition.st_ino)))
        }
        return result
    }

    private static func safeDirectory(_ parent: Int32, relative: String, owner: uid_t) -> Int32? {
        guard Trasher.isPlainPath("/" + relative) else { return nil }
        var fd = dup(parent)
        guard fd >= 0 else { return nil }
        for name in relative.split(separator: "/") {
            let next = ApplicationTrash.openDirectory(fd, String(name)); close(fd)
            guard let next else { return nil }
            fd = next
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_uid == owner, st.st_mode & 0o022 == 0 else { close(fd); return nil }
        }
        return fd
    }

    static func processes(in app: String) -> [Process]? {
        let expected = Trasher.identity(of: app)
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size <= 64 * 1_048_576 else { return nil }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 128)
        size = processes.count * stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return nil }
        var found: [Process] = []
        for process in processes.prefix(size / stride) where process.kp_eproc.e_ucred.cr_uid >= 501 {
            if process.kp_proc.p_stat == SZOMB { continue }
            var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let count = proc_pidpath(process.kp_proc.p_pid, &buffer, UInt32(buffer.count))
            if count <= 0 {
                if errno == ESRCH || errno == ENOENT { continue }
                return nil
            }
            let path = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
            var bundle: String?
            if path.hasPrefix(app + "/") { bundle = app }
            else if let expected {
                var prefix = ""
                for component in path.split(separator: "/") {
                    prefix += "/" + component
                    if component.lowercased().hasSuffix(".app"), Trasher.identity(of: prefix) == expected { bundle = prefix; break }
                }
            }
            if let bundle {
                found.append(Process(pid: process.kp_proc.p_pid, uid: process.kp_eproc.e_ucred.cr_uid,
                    started: Int64(process.kp_proc.p_starttime.tv_sec), microseconds: Int32(process.kp_proc.p_starttime.tv_usec),
                    relativePath: String(path.dropFirst(bundle.count + 1))))
            }
        }
        return found
    }
}
