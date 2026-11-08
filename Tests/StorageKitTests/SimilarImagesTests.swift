import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import StorageKit

/// Pictures drawn by the test, in folders of its own.
@Suite struct SimilarImagesTests {
    /// A picture of `size` pixels: a gradient, or stripes for a different one.
    private func picture(_ url: URL, size: Int, stripes: Bool = false, type: UTType = .png) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = try #require(CGContext(
            data: nil, width: size, height: size * 3 / 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let h = size * 3 / 4
        for x in 0..<size {
            let v = stripes ? (x / max(1, size / 12) % 2 == 0 ? 0.9 : 0.1) : Double(x) / Double(size)
            ctx.setFillColor(red: v, green: 1 - v, blue: 0.5, alpha: 1)
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
        }
        // A dark band across the top, so rows differ too.
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: size / 3, y: h / 2, width: size / 3, height: h / 4))
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test func aResizedReSavedCopyLooksAlikeAndADifferentPictureDoesnt() throws {
        let box = try Sandbox()
        try picture(box.url.appending(path: "Pictures/original.png"), size: 800)
        try picture(box.url.appending(path: "Downloads/smaller.jpg"), size: 300, type: .jpeg)
        try picture(box.url.appending(path: "Pictures/other.png"), size: 800, stripes: true)

        let found = SimilarImages.find(in: [box.path + "/Pictures", box.path + "/Downloads"], minimum: 1, workers: 2)
        #expect(found.unreadable.isEmpty && !found.truncated)
        #expect(found.groups.count == 1)
        let group = try #require(found.groups.first)
        #expect(group.images.map(\.name) == ["original.png", "smaller.jpg"])
        // The best keeps the most pixels; the smaller copy is what's spare.
        #expect(group.best?.width == 800 && group.spare == group.images[1].bytes)

        let original = box.path + "/Pictures/original.png", smaller = box.path + "/Downloads/smaller.jpg"
        #expect(SimilarImages.mayGo(smaller, of: group, going: [smaller], home: box.path))
        // Never the last of a group.
        #expect(!SimilarImages.mayGo(smaller, of: group, going: [smaller, original], home: box.path))
    }

    @Test func fingerprintsOfAPlainPictureAreLeftOut() throws {
        #expect(SimilarImages.hash([UInt8](repeating: 7, count: 72)) == 0)
        let box = try Sandbox()
        try box.file("Pictures/not-a-picture.jpg", bytes: 60_000)
        #expect(SimilarImages.fingerprint(box.path + "/Pictures/not-a-picture.jpg") == nil)
    }

    @Test func aSecondSearchUsesTheCacheAndARewrittenPictureIsReadAgain() throws {
        let box = try Sandbox()
        try picture(box.url.appending(path: "Pictures/a.png"), size: 400)
        try picture(box.url.appending(path: "Pictures/b.jpg"), size: 200, type: .jpeg)
        let cache = SharedFingerprints(FingerprintCache())
        let first = SimilarImages.find(in: [box.path + "/Pictures"], minimum: 1, workers: 1, cache: cache)
        #expect(cache.current.count == 2 && first.groups.count == 1)
        let again = SimilarImages.find(in: [box.path + "/Pictures"], minimum: 1, workers: 1, cache: cache)
        #expect(again.groups.map(\.id) == first.groups.map(\.id) && cache.current.count == 2)
        // Rewritten as a different picture: a new entry, and no longer alike.
        try picture(box.url.appending(path: "Pictures/b.jpg"), size: 200, stripes: true, type: .jpeg)
        let changed = SimilarImages.find(in: [box.path + "/Pictures"], minimum: 1, workers: 1, cache: cache)
        #expect(changed.groups.isEmpty)
    }

    @Test func aChainIsOneGroupAndThePictureAtItsEndIsSaidToBeLinkedOnly() {
        func image(_ name: String, _ px: Int, _ print: UInt64) -> (SimilarImage, UInt64) {
            var i = SimilarImage(path: "/synthetic/" + name, bytes: 1, modified: .distantPast, width: px, height: px, inode: 0, length: 1)
            i.print = print
            return (i, print)
        }
        // A to B: 4 points; B to C: 4 more; A to C: 8, past the threshold.
        let a = image("a.jpg", 900, 0)
        let b = image("b.jpg", 600, 0b1111)
        let c = image("c.jpg", 300, 0b1111_1111)
        let g = try! #require(SimilarImages.group([a, b, c]).first)
        #expect(g.images.map(\.name) == ["a.jpg", "b.jpg", "c.jpg"])
        #expect(g.difference(g.images[1]) == 4 && !g.isLinkedOnly(g.images[1]))
        #expect(g.difference(g.images[2]) == 8 && g.isLinkedOnly(g.images[2]))
    }

    /// Every pair compared: what the indexed grouping must equal.
    private func exhaustive(_ prints: [(SimilarImage, UInt64)]) -> Set<Set<String>> {
        var parent = Array(prints.indices)
        func root(_ i: Int) -> Int { parent[i] == i ? i : root(parent[i]) }
        for i in prints.indices {
            for j in (i + 1)..<prints.count where (prints[i].1 ^ prints[j].1).nonzeroBitCount <= SimilarImages.threshold {
                let (a, b) = (root(i), root(j))
                if a != b { parent[b] = a }
            }
        }
        var by: [Int: Set<String>] = [:]
        for i in prints.indices { by[root(i), default: []].insert(prints[i].0.path) }
        return Set(by.values.filter { $0.count > 1 })
    }

    @Test func indexedGroupingFindsWhatComparingEveryPairFinds() {
        var rng = SystemRandomNumberGenerator()
        var prints: [(SimilarImage, UInt64)] = []
        for c in 0..<60 {
            let base = UInt64.random(in: .min ... .max, using: &rng)
            // Variants of each base that differ in up to seven bits, so some
            // pairs are just inside the threshold and some just outside.
            for v in 0..<4 {
                var h = base
                for _ in 0..<Int.random(in: 0...7, using: &rng) { h ^= UInt64(1) << UInt64.random(in: 0..<64, using: &rng) }
                let image = SimilarImage(
                    path: "/synthetic/\(c)-\(v).jpg", bytes: 1, modified: .distantPast, width: 1, height: 1, inode: 0, length: 1)
                prints.append((image, h))
            }
        }
        let indexed = Set(SimilarImages.group(prints).map { Set($0.images.map(\.path)) })
        #expect(indexed == exhaustive(prints))
    }

    @Test func aStoppedGroupingReturnsNothing() {
        let image = SimilarImage(path: "/synthetic/a.jpg", bytes: 1, modified: .distantPast, width: 1, height: 1, inode: 0, length: 1)
        let other = SimilarImage(path: "/synthetic/b.jpg", bytes: 1, modified: .distantPast, width: 1, height: 1, inode: 0, length: 1)
        let stopped = ScanProgress()
        stopped.cancel()
        #expect(SimilarImages.group([(image, 0xF0F0), (other, 0xF0F1)], progress: stopped).isEmpty)
        #expect(SimilarImages.group([(image, 0xF0F0), (other, 0xF0F1)]).count == 1)
    }
}

@Suite struct FingerprintCacheTests {
    @Test func anEntryCountsOnlyForTheSameFileUnchanged() throws {
        var c = FingerprintCache()
        let key = FingerprintCache.key(device: 1, inode: 2, length: 3, modified: Date(timeIntervalSince1970: 4))
        c.store(key, print: 0xABC, width: 10, height: 20)
        #expect(c.look(key)?.0 == 0xABC)
        #expect(c.look(FingerprintCache.key(device: 1, inode: 2, length: 3, modified: Date(timeIntervalSince1970: 5))) == nil)
        #expect(c.look(FingerprintCache.key(device: 9, inode: 2, length: 3, modified: Date(timeIntervalSince1970: 4))) == nil)

        let box = try Sandbox()
        let url = box.url.appending(path: "prints.json")
        c.save(to: url)
        var read = FingerprintCache.load(from: url)
        #expect(read.look(key)?.1 == 10)
        // A damaged file is an empty cache.
        try Data("garbage".utf8).write(to: url)
        #expect(FingerprintCache.load(from: url).count == 0)
    }

    @Test func aSecondSearchUsesTheCacheAndSeesARewrittenPicture() throws {
        let box = try Sandbox()
        let cache = SharedFingerprints(FingerprintCache())
        try box.file("Pictures/noise.bin", bytes: 10)
        _ = SimilarImages.find(in: [box.path + "/Pictures"], minimum: 1, workers: 1, cache: cache)
        #expect(cache.current.count == 0)
    }
}
