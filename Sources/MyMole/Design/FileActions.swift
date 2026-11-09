import AppKit
import StorageKit
import SwiftUI

/// What the app can do with files on disk outside its own model: show,
/// open, copy. Shared by every context menu so they read the same.
enum FileActions {
    enum CopyStyle: String, CaseIterable, Identifiable {
        case path, absolutePath, name, shellPath, fileURL
        var id: Self { self }

        func title(count: Int) -> String {
            switch self {
            case .path: count == 1 ? String(localized: "Copy Path") : String(localized: "Copy \(count) Paths")
            case .absolutePath: count == 1 ? String(localized: "Copy Absolute Path") : String(localized: "Copy \(count) Absolute Paths")
            case .name: count == 1 ? String(localized: "Name") : String(localized: "Names")
            case .shellPath: String(localized: "Shell-Quoted Path")
            case .fileURL: String(localized: "File URL")
            }
        }
    }

    /// Row IDs can also be group hashes or event identifiers. Only actual
    /// absolute paths enter file actions; preserve their spelling and order.
    static func paths(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { $0.hasPrefix("/") && !$0.contains("\0") && seen.insert($0).inserted }
    }

    static func reveal(_ paths: [String]) {
        let paths = Self.paths(paths)
        guard !paths.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copy(_ paths: [String], as style: CopyStyle = .path) {
        let value = copyText(paths, as: style, home: Home.path)
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// Formatting does no filesystem access, canonicalization or shell execution.
    static func copyText(_ values: [String], as style: CopyStyle, home: String) -> String {
        paths(values).map { path in
            switch style {
            case .path:
                path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
            case .absolutePath: path
            case .name: (path as NSString).lastPathComponent
            case .shellPath: "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            case .fileURL: URL(fileURLWithPath: path).absoluteString
            }
        }.joined(separator: "\n")
    }

    static let additionalCopyStyles: [CopyStyle] = [.name, .shellPath, .fileURL]

    @MainActor static func inspectionMenu(_ values: [String]) -> [TableMenuEntry] {
        let paths = paths(values)
        guard !paths.isEmpty else { return [] }
        return [.quickLook, .divider] + menu(paths, canOpen: false)
    }

    /// The same items as `FileMenuItems`, for AppKit-backed tables.
    @MainActor static func menu(_ values: [String], canOpen: Bool = true) -> [TableMenuEntry] {
        let paths = paths(values)
        guard !paths.isEmpty else { return [] }
        var out: [TableMenuEntry] = [.action(String(localized: "Show in Finder")) { reveal(paths) }]
        if canOpen, paths.count == 1, let p = paths.first { out.append(.action(String(localized: "Open with Default App")) { open(p) }) }
        out.append(.divider)
        for style in [CopyStyle.path, .absolutePath] {
            out.append(.action(style.title(count: paths.count)) { copy(paths, as: style) })
        }
        out.append(.submenu(String(localized: "Copy As"), additionalCopyStyles.map { style in
            .action(style.title(count: paths.count)) { copy(paths, as: style) }
        }))
        return out
    }
}

/// The same file actions in SwiftUI, including menus on standalone paths.
struct FileMenuItems: View {
    let paths: [String]
    var canOpen = true

    var body: some View {
        let paths = FileActions.paths(paths)
        if !paths.isEmpty {
            Button("Show in Finder") { FileActions.reveal(paths) }
            if canOpen, paths.count == 1, let p = paths.first {
                Button("Open with Default App") { FileActions.open(p) }
            }
            Divider()
            ForEach([FileActions.CopyStyle.path, .absolutePath]) { style in
                Button(style.title(count: paths.count)) { FileActions.copy(paths, as: style) }
            }
            Menu("Copy As") {
                ForEach(FileActions.additionalCopyStyles) { style in
                    Button(style.title(count: paths.count)) { FileActions.copy(paths, as: style) }
                }
            }
        }
    }
}
