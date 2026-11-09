import AppKit
import UniformTypeIdentifiers

/// A session grant for exactly one bundle. Retain the original Powerbox URL
/// through the move; rebuilding it from a path loses its attached capability.
@MainActor final class AppBundleAccess {
    private let choose: @MainActor (URL) -> URL?
    private let start: @MainActor (URL) -> Bool
    private let stop: @MainActor (URL) -> Void
    private var held: URL?
    private(set) var url: URL?

    init(choose: @escaping @MainActor (URL) -> URL? = AppBundleAccess.panel,
         start: @escaping @MainActor (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stop: @escaping @MainActor (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.choose = choose
        self.start = start
        self.stop = stop
    }

    func acquire(path: String) -> Bool {
        release()
        let target = URL(fileURLWithPath: path).standardizedFileURL
        guard let selected = choose(target), selected.isFileURL,
              selected.standardizedFileURL.path == target.path,
              selected.query == nil, selected.fragment == nil else { return false }
        // Open-panel selection grants access for this session even when no
        // additional security-scoped access needs to be started.
        if start(selected) { held = selected }
        url = selected
        return true
    }

    func release() {
        if let held { stop(held) }
        held = nil
        url = nil
    }

    static func panel(_ target: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Allow App Removal")
        panel.message = String(localized: "Choose \(target.lastPathComponent) to allow moving this app to the Trash. This file access is separate from App Management and Full Disk Access.")
        panel.prompt = String(localized: "Allow Uninstall")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = target.deletingLastPathComponent()
        panel.nameFieldStringValue = target.lastPathComponent
        return panel.runModal() == .OK ? panel.url : nil
    }
}
