import Darwin
import Foundation

/// Bundle declarations, not a claim that macOS has enabled or loaded them.
public struct AppIntegration: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case finder, service, documents, urls, extensionProvider }
    public let id: String
    public let kind: Kind
    public let name: String
    public let detail: String
    public let path: String
}

public enum AppIntegrations {
    public struct Report: Sendable, Equatable {
        public var items: [AppIntegration] = []
        public var unreadable: [String] = []
        public var limited = false
        public init() {}
    }

    public static func read(_ path: String, info: [String: Any], progress: ScanProgress = ScanProgress()) -> Report {
        var report = Report()
        func add(_ kind: AppIntegration.Kind, _ name: String, _ detail: String, at source: String, index: Int) {
            report.items.append(AppIntegration(id: source + "#" + kind.rawValue + "#\(index)", kind: kind,
                                               name: String(name.prefix(512)), detail: String(detail.prefix(2048)), path: source))
        }
        func entries(_ key: String) -> [[String: Any]] {
            guard let value = info[key] else { return [] }
            guard let entries = value as? [[String: Any]] else { report.unreadable.append(path + "/Contents/Info.plist"); return [] }
            if entries.count > 128 { report.limited = true }
            return Array(entries.prefix(128))
        }
        for (index, service) in entries("NSServices").enumerated() where !progress.isCancelled {
            let menu = (service["NSMenuItem"] as? [String: String])?["default"]
            let message = service["NSMessage"] as? String
            // Services strip a preceding menu path. Localized labels can differ.
            let title = menu?.split(separator: "/").last.map(String.init) ?? message ?? "Service"
            add(.service, title, message ?? "NSServices", at: path, index: index)
        }
        for (index, document) in entries("CFBundleDocumentTypes").enumerated() where !progress.isCancelled {
            let types = document["LSItemContentTypes"] as? [String] ?? document["CFBundleTypeExtensions"] as? [String] ?? []
            let name = document["CFBundleTypeName"] as? String ?? types.first ?? "Document handler"
            let role = document["CFBundleTypeRole"] as? String
            add(.documents, name, ([role].compactMap { $0 } + Array(types.prefix(32))).joined(separator: " · "), at: path, index: index)
        }
        for (index, scheme) in entries("CFBundleURLTypes").enumerated() where !progress.isCancelled {
            let schemes = Array((scheme["CFBundleURLSchemes"] as? [String] ?? []).prefix(32))
            add(.urls, scheme["CFBundleURLName"] as? String ?? schemes.first ?? "URL handler", schemes.joined(separator: ", "), at: path, index: index)
        }
        let plugins = path + "/Contents/PlugIns"
        var st = stat()
        if lstat(plugins, &st) != 0 && errno == ENOENT { return report }
        guard st.st_mode & S_IFMT == S_IFDIR, Trasher.noLinksBetween(path, and: plugins), let names = DirectoryListing.names(plugins) else {
            report.unreadable.append(plugins)
            return report
        }
        let extensions = names.filter { $0.lowercased().hasSuffix(".appex") }.sorted()
        if extensions.count > 128 { report.limited = true }
        for name in extensions.prefix(128) where !progress.isCancelled {
            let extensionPath = plugins + "/" + name
            guard lstat(extensionPath, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
                  let metadata = AppIdentity.bundleInfo(atPath: extensionPath),
                  let declaration = metadata["NSExtension"] as? [String: Any],
                  let point = declaration["NSExtensionPointIdentifier"] as? String else {
                report.unreadable.append(extensionPath)
                continue
            }
            let title = metadata["CFBundleDisplayName"] as? String ?? metadata["CFBundleName"] as? String ?? name
            let identifier = metadata["CFBundleIdentifier"] as? String ?? ""
            add(point == "com.apple.FinderSync" ? .finder : .extensionProvider, title,
                [point, identifier].filter { !$0.isEmpty }.joined(separator: " · "), at: extensionPath, index: 0)
        }
        report.unreadable = Array(Set(report.unreadable)).sorted()
        return report
    }
}
