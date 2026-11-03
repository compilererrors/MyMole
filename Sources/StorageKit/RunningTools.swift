import Darwin
import Foundation

/// The programs this user's processes are running, by name, so a tool's
/// cache is left alone while the tool uses it. Command-line tools aren't
/// apps, so the app list doesn't show them; their arguments do.
public enum RunningTools {
    /// Names of every program and script the user's processes run: each
    /// argument's file name without its extension, and the dot-separated
    /// parts of it ("GradleDaemon" in a Java class name). Nil when the
    /// process list can't be read.
    public static func names() -> Set<String>? {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return nil }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return nil }
        var out = Set<String>()
        for p in procs.prefix(size / stride) {
            var comm = p.kp_proc.p_comm
            out.insert(withUnsafeBytes(of: &comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) })
            for a in arguments(p.kp_proc.p_pid) { out.formUnion(parts(a)) }
        }
        out.remove("")
        return out
    }

    /// Whether any process on the Mac, whoever runs it, has this program
    /// name (at most 16 characters are compared). Nil when the process list
    /// can't be read.
    public static func anyNamed(_ name: String) -> Bool? {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return nil }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return nil }
        let wanted = String(decoding: name.utf8.prefix(Int(MAXCOMLEN)), as: UTF8.self)
        return procs.prefix(size / stride).contains { p in
            var comm = p.kp_proc.p_comm
            return withUnsafeBytes(of: &comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) } == wanted
        }
    }

    static func parts(_ argument: String) -> [String] {
        let file = (argument as NSString).lastPathComponent
        let bare = (file as NSString).deletingPathExtension
        return [file, bare] + file.split(separator: ".").map(String.init)
    }

    /// A process's arguments, or none when they can't be read.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        // The executable's path, padding, then argc arguments, each ending in a NUL.
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }
        var args: [String] = []
        while i < size, args.count < Int(argc) {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
