import Darwin
import Foundation

/// Which programs have a file open right now, such as a virtual machine its
/// disk or an editor its project. Moving such a file to the Trash leaves the
/// program writing to it there. A folder's contents aren't looked through,
/// and in the App Sandbox other programs can't be seen, so an empty answer
/// isn't a promise.
public enum OpenFiles {
    /// The names of the programs that have `path` open, MyMole itself left
    /// out; nil when it couldn't be asked.
    public static func users(of path: String, excluding own: pid_t = getpid()) -> [String]? {
        let wanted = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, 0, nil, 0)
        guard wanted >= 0 else { return nil }
        // The buffer first holds every process, then only those with the
        // file open: processes started between the two calls would push
        // the last ones out, so there's room for twice as many.
        var pids = [pid_t](repeating: 0, count: 2 * Int(wanted) / MemoryLayout<pid_t>.size + 256)
        let got = pids.withUnsafeMutableBytes { raw in
            proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, 0, raw.baseAddress, Int32(raw.count))
        }
        guard got >= 0 else { return nil }
        var names: [String] = []
        for pid in pids.prefix(Int(got) / MemoryLayout<pid_t>.size) where pid > 0 && pid != own {
            var buffer = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !names.contains(name) { names.append(name) }
        }
        return names.sorted()
    }
}
