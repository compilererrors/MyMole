import Darwin
import Foundation

public enum Home {
    /// The user's home folder. Outside the App Sandbox it's
    /// `NSHomeDirectory()`, which follows `HOME`, so a run with a synthetic
    /// home stays in it. In the App Sandbox `NSHomeDirectory()` is the app's
    /// container, while caches, projects and downloads live in the real one,
    /// which the user grants access to; that one comes from the user record.
    public static let path: String = {
        let env = ProcessInfo.processInfo.environment
        #if SMOKE
        // The UI smoke test's own build gives the sandboxed edition a
        // synthetic home; shipping builds have no such switch.
        if let smoke = env["MYMOLE_SMOKE_HOME"], smoke.hasPrefix("/") { return smoke }
        #endif
        guard env["APP_SANDBOX_CONTAINER_ID"] != nil else { return NSHomeDirectory() }
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let s = String(cString: dir)
            if !s.isEmpty { return s }
        }
        return NSHomeDirectory()
    }()
}
