import Foundation

/// Preferences of a test's own, kept in a file in `dir`. A suite named by an
/// absolute path is stored at that path, never in ~/Library/Preferences.
func testDefaults(in dir: URL) -> UserDefaults {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return UserDefaults(suiteName: dir.appending(path: "defaults").path)!
}
