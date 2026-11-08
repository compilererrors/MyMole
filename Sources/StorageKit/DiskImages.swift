import Foundation

/// A mounted disk image an app is opened from, such as a download not yet
/// copied to Applications: the app can't be moved off the image, so the
/// image file itself is what goes once it's ejected.
public struct MountedImage: Sendable, Hashable {
    /// The disk image file.
    public let image: String
    /// Where its volume is mounted ("/Volumes/Editor").
    public let mountPoint: String

    public init(image: String, mountPoint: String) {
        self.image = image
        self.mountPoint = mountPoint
    }

    public var name: String { (image as NSString).lastPathComponent }
}

public enum DiskImages {
    static let hdiutil = "/usr/bin/hdiutil"

    /// The mounted image `path` is on, or nil when it's on none, or the
    /// images couldn't be listed.
    public static func image(holding path: String, runner: CommandRunner = .processes(timeLimit: 10)) -> MountedImage? {
        guard path.hasPrefix("/Volumes/"), runner.exists(hdiutil) else { return nil }
        let r = runner.run(hdiutil, ["info", "-plist"])
        guard r.code == 0 else { return nil }
        return parse(r.output).first { path == $0.mountPoint || path.hasPrefix($0.mountPoint + "/") }
    }

    /// Each image `hdiutil info -plist` lists, with the mount points of its
    /// volumes: one entry a volume.
    static func parse(_ plist: String) -> [MountedImage] {
        guard let data = plist.data(using: .utf8),
            let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let images = root["images"] as? [[String: Any]]
        else { return [] }
        return images.flatMap { image -> [MountedImage] in
            guard let file = image["image-path"] as? String, file.hasPrefix("/") else { return [] }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            return entities.compactMap { $0["mount-point"] as? String }.filter { $0.hasPrefix("/Volumes/") }
                .map { MountedImage(image: file, mountPoint: $0) }
        }
    }

    /// Checked again right before the image goes to the Trash: still a
    /// plain file of a disk image's kind, outside the protected places.
    public static func mayGo(_ image: String, home: String = Home.path) -> Bool {
        guard Trasher.isPlainPath(image), !Trasher.isProtected(image, home: home) else { return false }
        if image.hasPrefix(home + "/"), !Trasher.noLinksBetween(home, and: image) { return false }
        var st = stat()
        guard lstat(image, &st) == 0, st.st_mode & S_IFMT == S_IFREG || st.st_mode & S_IFMT == S_IFDIR else { return false }
        return endings.contains((image as NSString).pathExtension.lowercased())
    }

    static let endings: Set<String> = ["dmg", "sparseimage", "sparsebundle", "cdr", "iso", "img", "toast", "udif", "smi"]
}
