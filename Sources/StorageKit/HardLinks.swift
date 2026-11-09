import Darwin

/// Files with more than one name. Moving one name leaves the file, and its
/// space, where the other names are.
public enum HardLinks {
    /// How many other names each plain file in `paths` has; files with
    /// none are left out.
    public static func otherNames(of paths: [String], stop: () -> Bool = { false }) -> [String: Int] {
        var out: [String: Int] = [:]
        for p in paths {
            if stop() { break }
            var st = stat()
            guard lstat(p, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink > 1 else { continue }
            out[p] = Int(st.st_nlink) - 1
        }
        return out
    }
}
