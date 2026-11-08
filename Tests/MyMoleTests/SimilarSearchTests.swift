import Foundation
import StorageKit
import Testing
import UniformTypeIdentifiers

@testable import MyMole

@MainActor @Suite struct SimilarSearchTests {
    @Test func searchFindsAnyMemberAndChoosingRespectsVisibleGroups() async throws {
        let box = SimilarModelTests.Box()
        let best = try box.picture("Pictures/large.png", size: 900)
        let copy = try box.picture("Downloads/small.jpg", size: 300, type: .jpeg)
        let model = SimilarModel(home: box.home, roots: [box.home + "/Pictures", box.home + "/Downloads"], minimum: 1,
                                 logURL: box.root.appending(path: "history.json"), trash: testBin(box.root), cacheURL: nil)
        model.protections = UserProtections(root: box.root.appending(path: "lists"))
        model.scan()
        await model.scanJob?.value
        let group = try #require(model.groups.first)
        #expect(group.best?.path == best)
        #expect(SimilarView.matching(model.groups, query: "SMALL downloads").map(\.id) == [group.id])
        #expect(SimilarView.matching(model.groups, query: "unmatched-synthetic-photo").isEmpty)
        model.chooseAllButBest(in: [])
        #expect(model.chosen.isEmpty)
        model.chooseAllButBest(in: [group.id])
        #expect(model.chosen == [copy])
        // Hiding this group never chooses or unchooses its pictures.
        model.chooseAllButBest(in: [])
        #expect(model.chosen == [copy])
    }
}
