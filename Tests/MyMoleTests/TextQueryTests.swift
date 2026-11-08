import Testing

@testable import MyMole

@Suite struct TextQueryTests {
    @Test func wordsCanMatchDifferentFieldsWithoutDependingOnOrderOrCase() {
        let query = TextQuery("  CACHE   canvas  ")
        #expect(query.matches("Canvas", "/synthetic/Library/Caches"))
        #expect(!query.matches("Canvas", "/synthetic/Documents"))
        #expect(TextQuery("  ").matches("Anything"))
        #expect(TextQuery("räv").matches("RÄVEN"))
        #expect(!TextQuery("canvas").matches())
    }
}
