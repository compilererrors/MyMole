import AppKit

/// What a permanent removal couldn't do, item by item, so a remainder the
/// tool left part-way can be found. The first few are named; Copy gives all.
func problemText(_ problems: [(path: String, reason: String)]) -> String {
    let shown = problems.prefix(3).map { "\(($0.path as NSString).lastPathComponent): \($0.reason)" }
    let more = problems.count > 3 ? " And \(problems.count - 3) more." : ""
    return "\(problems.count) item\(problems.count == 1 ? "" : "s") weren't deleted. " + shown.joined(separator: " ") + more
}

func copyProblems(_ problems: [(path: String, reason: String)]) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(problems.map { "\($0.path): \($0.reason)" }.joined(separator: "\n"), forType: .string)
}
