import Foundation

public enum ByteSize {
    /// "1,2 GB", in the user's locale, as Finder shows file sizes.
    public static func format(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
