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
        guard let run = try? SyntheticRun.environment(env) else { fatalError("Refusing to launch without a verified synthetic home.") }
        ProcessInfo.processInfo.processName = "mymole-e2e-" + (env["MYMOLE_SMOKE_TOKEN"] ?? "").replacingOccurrences(of: "-", with: "")
        return run.home
        #else
        guard env["APP_SANDBOX_CONTAINER_ID"] != nil else { return NSHomeDirectory() }
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let s = String(cString: dir)
            if !s.isEmpty { return s }
        }
        return NSHomeDirectory()
        #endif
    }()
}
