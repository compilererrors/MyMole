import Foundation
import StorageKit

/// "The Trash" for a test: a folder of its own box, so the user's Trash is
/// never touched.
func testBin(_ box: URL) -> TrashBackend {
    let dir = box.appending(path: "Bin").path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return .folder(dir)
}
