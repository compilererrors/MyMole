import Foundation

/// Which edition this build is. The App Store edition runs in the App
/// Sandbox and may not ask for root (App Store Review Guideline 2.4.5), so
/// it has no system tasks and works on the folders the user grants it. The
/// direct edition adds system tasks through an approved helper or a per-task
/// administrator prompt. Chosen at build time:
/// `-Xswiftc -DAPPSTORE`.
enum Edition {
    case direct, appStore

    static let current: Edition = {
        #if APPSTORE
        .appStore
        #else
        .direct
        #endif
    }()

    /// System Clean, Optimize's administrator tasks and system-wide app leftovers.
    var hasSystemTasks: Bool { self == .direct }
    /// Works only in folders the user picked, kept as security-scoped bookmarks.
    var isSandboxed: Bool { self == .appStore }
}
