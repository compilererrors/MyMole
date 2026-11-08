import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Synchronization

/// A photo or picture among others that look the same: a burst, a resized
/// or re-saved copy, an edit exported again.
public struct SimilarImage: Sendable, Hashable, Identifiable {
    public let path: String
    public let bytes: Int64
    public let modified: Date
    public let width: Int
    public let height: Int
    let inode: UInt64
    let length: Int64
    var device: Int32 = 0
    /// Its 64-bit fingerprint.
    public var print: UInt64 = 0

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var folder: String { (path as NSString).deletingLastPathComponent }
    public var pixels: Int { width * height }
}

/// Pictures that look alike, the best one first: the most pixels, then the
/// biggest file, then the newest.
public struct SimilarGroup: Sendable, Hashable, Identifiable {
    public var images: [SimilarImage]

    public var id: String { images.map(\.path).sorted().first ?? "" }
    /// What goes when all but the best one do.
    public var spare: Int64 { images.dropFirst().reduce(0) { $0 + $1.bytes } }
    public var best: SimilarImage? { images.first }

    /// How many of the 64 points of `image`'s fingerprint differ from the
    /// best one's: 0 is the same picture, up to the threshold looks alike.
    public func difference(_ image: SimilarImage) -> Int {
        guard let best else { return 0 }
        return (best.print ^ image.print).nonzeroBitCount
    }

    /// In the group only through another picture: not alike the best one
    /// directly, but alike one that is.
    public func isLinkedOnly(_ image: SimilarImage) -> Bool { difference(image) > SimilarImages.threshold }
}

/// Finds pictures that look the same, without any network or model: each
/// is shrunk to a 9 × 8 grey thumbnail, and its brightness steps make a
/// 64-bit fingerprint (a difference hash). Pictures whose fingerprints
/// differ in a few bits at most look alike to the eye. Files are only read.
public enum SimilarImages {
    static let endings: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"]
    /// Smaller files are icons and thumbnails, not photos.
    public static let standardMinimum: Int64 = 50_000
    /// Bits two fingerprints may differ in and still look alike.
    public static let threshold = 5
    /// Pictures looked at in one search, so it ends in reasonable time.
    public static let limit = 20_000

    public static func standardRoots(home: String) -> [String] {
        ["Pictures", "Desktop", "Documents", "Downloads"].map { home + "/" + $0 }
    }

    /// `cache`: fingerprints of pictures read before, used for the same
    /// files unchanged and filled in with the rest; saved by the caller.
    public static func find(
        in roots: [String], minimum: Int64 = standardMinimum, progress: ScanProgress = ScanProgress(), workers: Int = 4,
        cache: SharedFingerprints? = nil,
        onStep: (@Sendable (DuplicateStep) -> Void)? = nil
    ) -> DuplicateListing.Similar {
        var unreadable: [String] = []
        var seen = Set<DuplicateFinder.FileID>()
        var files: [DuplicateFinder.Found] = []
        for root in Trasher.outermost(roots.filter(Trasher.isPlainPath)) where !progress.isCancelled {
            DuplicateFinder.walk(root, minimum: minimum, progress: progress, seen: &seen, unreadable: &unreadable) { f in
                if files.count < limit, endings.contains((f.path as NSString).pathExtension.lowercased()) { files.append(f) }
            }
        }
        let listed = files
        let total = listed.count
        let done = Atomic<Int>(0)
        let next = Atomic<Int>(0)
        let prints = Mutex<[(SimilarImage, UInt64)]>([])
        DispatchQueue.concurrentPerform(iterations: max(1, min(workers, 8))) { _ in
            while !progress.isCancelled {
                let i = next.add(1, ordering: .relaxed).oldValue
                guard i < listed.count else { return }
                let f = listed[i]
                let key = FingerprintCache.key(device: f.device, inode: f.inode, length: f.length, modified: f.modified)
                let known = cache?.cache.withLock { $0.look(key) }
                // Worked out again only when the file isn't the one the cache knows.
                let worked = known ?? fingerprint(f.path)
                if known == nil, let (print, w, h) = worked { cache?.cache.withLock { $0.store(key, print: print, width: w, height: h) } }
                if let (print, w, h) = worked {
                    let image = SimilarImage(
                        path: f.path, bytes: f.bytes, modified: f.modified, width: w, height: h, inode: f.inode, length: f.length,
                        device: f.device, print: print)
                    prints.withLock { $0.append((image, print)) }
                }
                let n = done.add(1, ordering: .relaxed).newValue
                if n % 50 == 0 || n == total { onStep?(DuplicateStep(phase: .comparing, done: n, total: total)) }
            }
        }
        let groups = group(prints.withLock { $0 }, progress: progress)
        return DuplicateListing.Similar(groups: groups, unreadable: unreadable.sorted(), truncated: listed.count >= limit)
    }

    /// The fingerprint and pixel size of a picture; nil when it can't be
    /// read as one, or is so plain (a single colour) that every such picture
    /// would look alike.
    static func fingerprint(_ path: String) -> (UInt64, Int, Int)? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        var grey = [UInt8](repeating: 0, count: 9 * 8)
        let drawn = grey.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        guard drawn else { return nil }
        let print = hash(grey)
        guard (4...60).contains(print.nonzeroBitCount) else { return nil }
        return (print, width, height)
    }

    /// One bit per neighbouring pair in each row: brighter to the right or not.
    static func hash(_ grey: [UInt8]) -> UInt64 {
        var h: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                h <<= 1
                if grey[y * 9 + x] < grey[y * 9 + x + 1] { h |= 1 }
            }
        }
        return h
    }

    /// The fingerprint cut into `threshold + 1` pieces: two that differ
    /// in `threshold` bits at most are equal in at least one piece, so only
    /// pictures sharing a piece need comparing, and none that look alike is
    /// missed.
    static let pieces: [(shift: UInt64, mask: UInt64)] = {
        let n = threshold + 1
        var out: [(UInt64, UInt64)] = []
        var start = 0
        for i in 0..<n {
            let width = 64 / n + (i < 64 % n ? 1 : 0)
            out.append((UInt64(start), width == 64 ? .max : (UInt64(1) << UInt64(width)) - 1))
            start += width
        }
        return out
    }()

    /// Pictures linked by a chain of look-alikes, groups of two or more, the
    /// most to win back first. Empty when stopped.
    static func group(_ prints: [(SimilarImage, UInt64)], progress: ScanProgress = ScanProgress()) -> [SimilarGroup] {
        var parent = Array(prints.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for piece in pieces {
            guard !progress.isCancelled else { return [] }
            var buckets: [UInt64: [Int]] = [:]
            for i in prints.indices { buckets[(prints[i].1 >> piece.shift) & piece.mask, default: []].append(i) }
            for bucket in buckets.values where bucket.count > 1 {
                for (n, i) in bucket.enumerated() {
                    if n % 256 == 0, progress.isCancelled { return [] }
                    for j in bucket[(n + 1)...] where (prints[i].1 ^ prints[j].1).nonzeroBitCount <= threshold {
                        let (a, b) = (root(i), root(j))
                        if a != b { parent[b] = a }
                    }
                }
            }
        }
        var byRoot: [Int: [SimilarImage]] = [:]
        for i in prints.indices { byRoot[root(i), default: []].append(prints[i].0) }
        return byRoot.values.filter { $0.count > 1 }.map { images in
            SimilarGroup(images: images.sorted {
                $0.pixels != $1.pixels ? $0.pixels > $1.pixels
                    : $0.bytes != $1.bytes ? $0.bytes > $1.bytes
                    : $0.modified != $1.modified ? $0.modified > $1.modified : $0.path < $1.path
            })
        }
        .sorted { $0.spare != $1.spare ? $0.spare > $1.spare : $0.id < $1.id }
    }

    /// Checked again right before a picture goes to the Trash: unchanged
    /// since it was looked at, no link on its way, and another picture of
    /// the group that isn't going still there unchanged.
    public static func mayGo(_ path: String, of group: SimilarGroup, going: Set<String>, home: String = Home.path) -> Bool {
        guard Trasher.isPlainPath(path), !Trasher.isProtected(path, home: home), Trasher.noLinksBetween(home, and: path),
            let image = group.images.first(where: { $0.path == path }), isUnchanged(image)
        else { return false }
        return group.images.contains { !going.contains($0.path) && isUnchanged($0) }
    }

    static func isUnchanged(_ image: SimilarImage) -> Bool {
        var st = stat()
        return lstat(image.path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG && Int64(st.st_size) == image.length
            && UInt64(st.st_ino) == image.inode && (image.device == 0 || st.st_dev == image.device)
            && DuplicateFinder.changed(st) == image.modified
    }
}

extension DuplicateListing {
    /// What a search for similar pictures found.
    public struct Similar: Sendable {
        public var groups: [SimilarGroup]
        public var unreadable: [String]
        /// More pictures were there than one search looks at.
        public var truncated: Bool
    }
}
