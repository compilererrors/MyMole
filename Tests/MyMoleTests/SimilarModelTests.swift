import CoreGraphics
import Foundation
import ImageIO
import StorageKit
import Testing
import UniformTypeIdentifiers

@testable import MyMole

/// Similar Photos on pictures the test draws in folders of its own.
@MainActor
@Suite struct SimilarModelTests {
    final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "similar-\(UUID().uuidString)")
        var home: String { root.appending(path: "home").path }
        deinit { try? FileManager.default.removeItem(at: root) }

        func picture(_ rel: String, size: Int, type: UTType = .png) throws -> String {
            let url = URL(fileURLWithPath: home + "/" + rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let h = size * 3 / 4
            let ctx = try #require(CGContext(
                data: nil, width: size, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            for x in 0..<size {
                let v = Double(x) / Double(size)
                ctx.setFillColor(red: v, green: 1 - v, blue: 0.4, alpha: 1)
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
            }
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: size / 3, y: h / 2, width: size / 3, height: h / 4))
            let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
            #expect(CGImageDestinationFinalize(dest))
            return url.path
        }
    }

    @Test func allButTheBestGoAndUndoPutsThemBack() async throws {
        let box = Box()
        let big = try box.picture("Pictures/big.png", size: 900)
        let small = try box.picture("Downloads/small.jpg", size: 300, type: .jpeg)
        let model = SimilarModel(
            home: box.home, roots: [box.home + "/Pictures", box.home + "/Downloads"], minimum: 1,
            logURL: box.root.appending(path: "history.json"), trash: testBin(box.root), cacheURL: box.root.appending(path: "prints.json"))
        model.jobs = TrashJobs()
        model.protections = UserProtections(root: box.root.appending(path: "lists"))
        model.scan()
        await model.scanJob?.value
        #expect(model.groups.count == 1 && model.chosen.isEmpty)

        // One always stays, by a tick or in one go.
        model.toggle(small)
        model.toggle(big)
        #expect(model.chosen == [small] && model.notice != nil)
        model.chosen = []
        model.chooseAllButBest()
        #expect(model.chosen == [small])

        model.trashChosen()
        await model.trashJob?.value
        #expect(!FileManager.default.fileExists(atPath: small) && FileManager.default.fileExists(atPath: big))
        #expect(model.groups.isEmpty && model.canUndo)

        model.undoTrash()
        await model.trashJob?.value
        await model.scanJob?.value
        #expect(FileManager.default.fileExists(atPath: small) && model.groups.count == 1)
    }
}
