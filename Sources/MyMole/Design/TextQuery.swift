import Foundation

/// Prepare once per filter change, rather than splitting the query for every row.
struct TextQuery: Sendable {
    private let words: [Substring]
    var isEmpty: Bool { words.isEmpty }

    init(_ text: String) { words = text.lowercased().split(separator: " ") }

    func matches(_ texts: String...) -> Bool { matches(texts: texts) }

    func matches(texts: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        let lowered = texts.map { $0.lowercased() }
        return words.allSatisfy { word in lowered.contains { $0.contains(word) } }
    }
}
