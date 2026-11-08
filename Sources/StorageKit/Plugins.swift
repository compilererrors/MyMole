import Darwin
import Foundation

/// A plug-in an app or its installer put in a Library: it loads into Finder,
/// Spotlight, System Settings, the browser, audio apps or the keyboard, and
/// often stays when its app is gone.
public enum PluginKind: String, Sendable, CaseIterable {
    case quickLook, spotlight, preferencePane, screenSaver, internetPlugin, audioUnit, vst, vst3, inputMethod, service,
        colorPicker

    public var title: String {
        switch self {
        case .quickLook: "Quick Look plug-in"
        case .spotlight: "Spotlight importer"
        case .preferencePane: "Settings pane"
        case .screenSaver: "Screen saver"
        case .internetPlugin: "Internet plug-in"
        case .audioUnit: "Audio Unit"
        case .vst: "VST plug-in"
        case .vst3: "VST3 plug-in"
        case .inputMethod: "Input method"
        case .service: "Service"
        case .colorPicker: "Color picker"
        }
    }

    /// What it does, in a few words.
    public var detail: String {
        switch self {
        case .quickLook: "Previews files in Finder and Quick Look"
        case .spotlight: "Lets Spotlight read a kind of file"
        case .preferencePane: "Adds a pane to System Settings"
        case .screenSaver: "A screen saver"
        case .internetPlugin: "Loads into older browsers"
        case .audioUnit, .vst, .vst3: "Loads into music and audio apps"
        case .inputMethod: "A way to type, in the keyboard menu"
        case .service: "Adds a command to the Services menu"
        case .colorPicker: "Adds a picker to the Colors window"
        }
    }

    /// The folder under a Library, and the endings an item there has.
    var place: (folder: String, endings: Set<String>) {
        switch self {
        case .quickLook: ("QuickLook", ["qlgenerator"])
        case .spotlight: ("Spotlight", ["mdimporter"])
        case .preferencePane: ("PreferencePanes", ["prefpane"])
        case .screenSaver: ("Screen Savers", ["saver", "qtz"])
        case .internetPlugin: ("Internet Plug-Ins", ["plugin", "webplugin"])
        case .audioUnit: ("Audio/Plug-Ins/Components", ["component"])
        case .vst: ("Audio/Plug-Ins/VST", ["vst"])
        case .vst3: ("Audio/Plug-Ins/VST3", ["vst3"])
        case .inputMethod: ("Input Methods", ["app", "bundle", "inputplugin"])
        case .service: ("Services", ["workflow", "service"])
        case .colorPicker: ("ColorPickers", ["colorpicker"])
        }
    }
}

/// The plug-ins in the user's Library and the one for every user. The
/// user's own can go to the Trash; the others need an administrator and
/// are only shown. macOS's own, in /System, aren't listed.
public enum Plugins {
    /// Every plug-in found, as rows of the Startup Items pane, and the
    /// folders that are there but couldn't be read. `root` stands in for "/" in tests.
    public static func list(home: String = Home.path, root: String = "", progress: ScanProgress = ScanProgress()) -> StartupListing {
        var items: [StartupItem] = []
        var unreadable: [String] = []
        for (library, scope) in [(home + "/Library", StartupItem.Scope.user), (root + "/Library", .everyUser)] where !progress.isCancelled {
            for kind in PluginKind.allCases where !progress.isCancelled {
                let folder = library + "/" + kind.place.folder
                var st = stat()
                guard lstat(folder, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
                guard let names = DirectoryListing.names(folder) else {
                    unreadable.append(folder)
                    continue
                }
                for name in names where !progress.isCancelled && kind.place.endings.contains((name as NSString).pathExtension.lowercased()) {
                    if let item = read(folder + "/" + name, kind: kind, scope: scope, progress: progress) { items.append(item) }
                }
            }
        }
        items.sort {
            $0.scope != $1.scope ? $0.scope == .user : $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
        return StartupListing(items: items, unreadable: unreadable)
    }

    /// A plug-in's Info.plist bigger than this isn't read; a real one is a few kilobytes.
    static let maxInfoBytes = 1 << 20

    static func read(_ path: String, kind: PluginKind, scope: StartupItem.Scope, progress: ScanProgress = ScanProgress()) -> StartupItem? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        guard type == S_IFDIR || type == S_IFREG else { return nil }
        // Measured with the listing's own stop, so a stop ends it mid-bundle.
        let bytes = type == S_IFDIR ? StorageScanner.scan(path: path, progress: progress, workers: 1).root.size : Int64(st.st_blocks) * 512
        guard !progress.isCancelled else { return nil }
        let plist = path + "/Contents/Info.plist"
        var pst = stat()
        let readable = lstat(plist, &pst) == 0 && pst.st_mode & S_IFMT == S_IFREG && pst.st_size <= maxInfoBytes
        let info = readable ? NSDictionary(contentsOfFile: plist) : nil
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var item = StartupItem(
            path: path, label: info?["CFBundleName"] as? String ?? name, program: info?["CFBundleIdentifier"] as? String,
            scope: scope, runsAtLoad: false, keepsAlive: false, scheduled: false, disabled: false, programMissing: false,
            app: nil, modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)), bytes: bytes)
        item.plugin = kind
        return item
    }

    /// Checked again right before a plug-in goes to the Trash: directly in
    /// one of the user's own plug-in folders, with the ending its kind has,
    /// and no link on the way. The folders for every user are never touched.
    public static func isStillRemovable(_ path: String, home: String = Home.path) -> Bool {
        let folder = (path as NSString).deletingLastPathComponent
        let ending = (path as NSString).pathExtension.lowercased()
        guard Trasher.isPlainPath(path),
            PluginKind.allCases.contains(where: { home + "/Library/" + $0.place.folder == folder && $0.place.endings.contains(ending) }),
            !Trasher.isProtected(path, home: home), Trasher.noLinksBetween(home, and: path)
        else { return false }
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return st.st_mode & S_IFMT == S_IFDIR || st.st_mode & S_IFMT == S_IFREG
    }
}
