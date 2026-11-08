import AppKit

/// Captured before confirmation; a recycled PID must never target another app.
struct StatusAppTarget: Equatable {
    let pid: pid_t
    let launched: Date
    let bundle: URL
    let name: String

    func matches(_ other: Self?) -> Bool {
        guard let other else { return false }
        return pid == other.pid && launched == other.launched && bundle == other.bundle
    }

    @MainActor static func capture(_ pid: pid_t) -> Self? {
        guard !Edition.current.isSandboxed, pid != ProcessInfo.processInfo.processIdentifier,
            let app = NSRunningApplication(processIdentifier: pid)
        else { return nil }
        return identity(app)
    }

    @MainActor private static func identity(_ app: NSRunningApplication) -> Self? {
        guard !app.isTerminated, app.activationPolicy == .regular,
            let launched = app.launchDate, let bundle = app.bundleURL
        else { return nil }
        return Self(
            pid: app.processIdentifier, launched: launched, bundle: bundle,
            name: app.localizedName ?? bundle.deletingPathExtension().lastPathComponent)
    }

    @MainActor func quit() -> Bool {
        guard !Edition.current.isSandboxed, pid != ProcessInfo.processInfo.processIdentifier,
            let app = NSRunningApplication(processIdentifier: pid), matches(Self.identity(app))
        else { return false }
        return app.terminate()
    }
}

@MainActor enum StatusActions {
    static func openActivityMonitor() { open("com.apple.ActivityMonitor") }
    static func openSystemSettings() { open("com.apple.systempreferences") }

    private static func open(_ id: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
