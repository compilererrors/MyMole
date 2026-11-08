import Foundation

/// A warning for something picked by hand, such as a folder marked in the
/// disk map: what it is, and how careful to be.
public struct PathRisk: Sendable, Hashable {
    public enum Level: Int, Sendable, Comparable {
        /// Usually fine, but may cost a re-download, a rebuild or a setting.
        case review
        /// Can't be recreated, or is your own data.
        case caution

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public let level: Level
    public let reason: String

    /// The folder or file itself, or anything inside it.
    static func within(_ p: String, _ parts: [String]) -> Bool {
        parts.contains { p.contains($0 + "/") || p.hasSuffix($0) }
    }

    static let rules: [(match: @Sendable (String) -> Bool, risk: PathRisk)] = [
        ({ within($0, ["/.aws", "/.kube", "/.azure", "/.docker/config.json", "/.netrc", "/.npmrc", "/.config/gh", "/.config/gcloud"]) },
         PathRisk(level: .caution, reason: "Sign-in keys or tokens. Tools that use them sign you out.")),
        ({ within($0, [
            "/Library/Safari", "/Application Support/Google/Chrome", "/Application Support/Firefox/Profiles",
            "/Application Support/BraveSoftware", "/Application Support/Microsoft Edge", "/Application Support/Arc",
        ]) },
         PathRisk(level: .caution, reason: "A browser profile: history, bookmarks, saved passwords and sign-ins.")),
        ({ $0.contains("/.Trash/") || $0.hasSuffix("/.Trash") },
         PathRisk(level: .caution, reason: "Already in the Trash.")),
        ({ $0.contains("/MobileSync/Backup") },
         PathRisk(level: .caution, reason: "iPhone/iPad backup. Can't be recreated.")),
        ({ $0.contains("/Mobile Documents/") },
         PathRisk(level: .caution, reason: "iCloud Drive files. Removing them here removes them on your other devices too.")),
        // Dropbox, Google Drive, OneDrive, Box and other File Provider services.
        ({ $0.contains("/Library/CloudStorage/") },
         PathRisk(level: .caution, reason: "Synced with a cloud service. Removing it here removes it in the cloud and on your other devices too.")),
        ({ within($0, [".photoslibrary"]) },
         PathRisk(level: .caution, reason: "A Photos library: every photo, video and edit in it.")),
        ({ ["/Downloads/", "/Documents/", "/Desktop/", "/Pictures/", "/Movies/", "/Music/"].contains(where: $0.contains) },
         PathRisk(level: .caution, reason: "Your own files.")),
        ({ $0.contains("/Library/Mail/") || $0.contains("/Library/Messages/") },
         PathRisk(level: .caution, reason: "Mail or Messages data.")),
        ({ $0.hasSuffix("/Docker.raw") || $0.contains("/com.docker.docker/Data/vms/") },
         PathRisk(level: .caution, reason: "Docker's virtual disk. Holds every image, container and volume.")),
        ({ p in [".vmwarevm", ".pvm", ".utm", "/VirtualBox VMs/", "/Parallels/", ".vdi", ".vmdk", ".qcow2"].contains(where: p.contains) },
         PathRisk(level: .caution, reason: "A virtual machine and everything installed in it.")),
        ({ $0.contains("/Xcode/Archives") },
         PathRisk(level: .caution, reason: "Xcode archives. Needed to symbolicate crash reports of shipped builds.")),
        ({ $0.contains("/Group Containers/") },
         PathRisk(level: .review, reason: "Data shared between apps. May include settings.")),
        ({ $0.contains("/CoreSimulator/Devices") },
         PathRisk(level: .review, reason: "Simulator apps and their data.")),
    ]

    /// The first rule that matches, if any.
    public static func of(_ path: String) -> PathRisk? {
        rules.first(where: { $0.match(path) })?.risk
    }

    /// The gravest risk of anything inside `folder` as scanned, so marking a
    /// parent warns about what it holds. Looks at up to `limit` folders, and
    /// ends at the next folder once `stop` says so, with what it found by
    /// then. It reads the disk, so run it off the main thread for big folders.
    public static func inside(_ folder: Folder, limit: Int = 50_000, stop: () -> Bool = { false }) -> PathRisk? {
        var found: PathRisk?
        var stack = [folder]
        var seen = 0
        while let f = stack.popLast(), seen < limit, found?.level != .caution, !stop() {
            seen += 1
            // Every entry, small files included: the tree keeps only big
            // files by name, and a credential file is small.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: f.path)) ?? f.listedFiles.map(\.name)
            for p in (f === folder ? [] : [f.path]) + names.map({ f.path + "/" + $0 }) {
                if let r = of(p), found.map({ r.level > $0.level }) ?? true { found = r }
            }
            stack += f.subfolders
        }
        return found.map { PathRisk(level: $0.level, reason: "Inside: " + $0.reason) }
    }
}
