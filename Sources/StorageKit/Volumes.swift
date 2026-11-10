import Foundation

/// Disks mounted now, and the identity a scan's history is kept under, so
/// a disk renamed, swapped or plugged in under another's name never takes
/// on the other's history.
public enum Volumes {
    public struct Volume: Sendable, Hashable, Identifiable {
        public let path: String
        public let name: String
        public let available: Int64?
        public let isRemovable: Bool
        public var id: String { path }
    }

    /// The disks mounted now, the startup disk first, hidden ones left out.
    public static func mounted() -> [Volume] {
        #if SMOKE
        guard let scope = try? SyntheticRun.current() else { return [] }
        return [Volume(path: scope.home, name: "Synthetic Disk", available: 60 << 30, isRemovable: false)]
        #else
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> (Volume, Bool)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let vol = Volume(
                path: url.path, name: v.volumeName ?? url.lastPathComponent,
                available: v.volumeAvailableCapacityForImportantUsage ?? v.volumeAvailableCapacity.map(Int64.init),
                isRemovable: v.volumeIsRemovable == true || v.volumeIsEjectable == true)
            return (vol, v.volumeIsRootFileSystem == true)
        }
        .sorted { $0.1 != $1.1 ? $0.1 : $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
        .map(\.0)
        #endif
    }

    /// The key a scan of `path` keeps its history under: the path on the
    /// startup disk, the path and the disk's own identity elsewhere. A disk
    /// that doesn't say who it is gets a key no other disk shares.
    public static func historyKey(for path: String, identity: (String) -> (isStartup: Bool, uuid: String?)? = Volumes.identity(of:)) -> String {
        guard let id = identity(path), !id.isStartup else { return path }
        return path + "#" + (id.uuid ?? "unknown-" + UUID().uuidString)
    }

    public static func identity(of path: String) -> (isStartup: Bool, uuid: String?)? {
        #if SMOKE
        return (try? SyntheticRun.current()) == nil ? nil : (true, nil)
        #else
        guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsRootFileSystemKey, .volumeUUIDStringKey]) else { return nil }
        return (v.volumeIsRootFileSystem == true, v.volumeUUIDString)
        #endif
    }
}
