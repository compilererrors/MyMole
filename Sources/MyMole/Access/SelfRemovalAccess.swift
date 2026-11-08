import AppKit
import UniformTypeIdentifiers

/// A one-time grant for exactly this bundle, without bookmarking a whole folder.
@MainActor final class SelfRemovalAccess {
    private let choose: @MainActor (URL) -> URL?
    private let start: @MainActor (URL) -> Bool
    private let stop: @MainActor (URL) -> Void
    private var held: URL?

    init(choose: @escaping @MainActor (URL) -> URL? = SelfRemovalAccess.panel,
         start: @escaping @MainActor (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stop: @escaping @MainActor (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.choose = choose
        self.start = start
        self.stop = stop
    }

    func acquire(path: String) -> Bool {
        release()
        let target = URL(fileURLWithPath: path).standardizedFileURL
        guard let selected = choose(target), selected.standardizedFileURL == target else { return false }
        // Open-panel selection grants access for this session even when no
        // additional security-scoped access needs to be started.
        if start(selected) { held = selected }
        return true
    }

    func release() {
        if let held { stop(held) }
        held = nil
    }

    static func panel(_ target: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose This Copy of MyMole")
        panel.message = String(localized: "Choose the MyMole app you are using to allow moving it to the Trash.")
        panel.prompt = String(localized: "Allow Uninstall")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = target.deletingLastPathComponent()
        panel.nameFieldStringValue = target.lastPathComponent
        return panel.runModal() == .OK ? panel.url : nil
    }
}
