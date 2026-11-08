import Foundation

/// What package tools installed, read from where they keep it and never by
/// running them: Homebrew's Cellar and Caskroom, and the installer's
/// receipts. Only looked at; removing goes through the tool itself.
public struct InstalledPackage: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, CaseIterable {
        case formula, cask, receipt

        public var title: String {
            switch self {
            case .formula: "Homebrew formula"
            case .cask: "Homebrew cask"
            case .receipt: "Installer package"
            }
        }
    }

    public let source: Source
    public let name: String
    public let versions: [String]
    /// What it takes on disk; nil for a receipt, whose files are spread out.
    public let bytes: Int64?
    public let path: String
    public let installed: Date?
    public var id: String { source.rawValue + ":" + name }
}

public struct PackageListing: Sendable {
    public var packages: [InstalledPackage]
    /// Places that are there but couldn't be read.
    public var unreadable: [String]
    /// No Homebrew was found where it installs.
    public var noHomebrew: Bool
}

public enum Packages {
    /// Where Homebrew lives on Apple silicon and on Intel Macs.
    public static let brewPrefixes = ["/opt/homebrew", "/usr/local"]
    public static let receipts = "/private/var/db/receipts"

    public static func list(prefixes: [String] = brewPrefixes, receipts: String = receipts, progress: ScanProgress = ScanProgress()) -> PackageListing {
        var out: [InstalledPackage] = []
        var unreadable: [String] = []
        var anyBrew = false
        for prefix in prefixes where !progress.isCancelled {
            for (folder, source) in [(prefix + "/Cellar", InstalledPackage.Source.formula), (prefix + "/Caskroom", .cask)] {
                guard let names = DirectoryListing.names(folder) else {
                    unreadable.append(folder)
                    continue
                }
                var st = stat()
                if lstat(folder, &st) == 0 { anyBrew = true }
                for name in names where !name.hasPrefix(".") && !progress.isCancelled {
                    let path = folder + "/" + name
                    let versions = (DirectoryListing.names(path) ?? []).filter { !$0.hasPrefix(".") }.sorted()
                    out.append(InstalledPackage(
                        source: source, name: name, versions: versions, bytes: AppLeftovers.measure(path), path: path,
                        installed: modified(path)))
                }
            }
        }
        if let names = DirectoryListing.names(receipts) {
            for name in names where name.hasSuffix(".plist") && !progress.isCancelled {
                let path = receipts + "/" + name
                let info = NSDictionary(contentsOfFile: path)
                let id = info?["PackageIdentifier"] as? String ?? String(name.dropLast(6))
                // macOS's own installs are the system's.
                guard !id.hasPrefix("com.apple.") else { continue }
                out.append(InstalledPackage(
                    source: .receipt, name: id, versions: (info?["PackageVersion"] as? String).map { [$0] } ?? [], bytes: nil,
                    path: path, installed: info?["InstallDate"] as? Date))
            }
        } else {
            unreadable.append(receipts)
        }
        out.sort { ($0.bytes ?? -1) != ($1.bytes ?? -1) ? ($0.bytes ?? -1) > ($1.bytes ?? -1) : $0.name < $1.name }
        return PackageListing(packages: out, unreadable: unreadable, noHomebrew: !anyBrew)
    }

    private static func modified(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }
}
