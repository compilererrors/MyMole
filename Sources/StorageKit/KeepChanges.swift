import Foundation

/// Said whenever a keep list or the project rules are saved, so every open
/// list marks what's kept at once, without scanning again. The moves' own
/// gates read the lists again regardless.
public enum KeepChanges {
    public static let name = Notification.Name("MyMoleKeepChanged")

    /// `place`: the file or folder that changed, for those who keep their own.
    static func post(_ place: URL) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["place": place.path])
    }
}
