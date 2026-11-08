import AppKit
import SwiftUI

/// One thing the app can be told to do, defined once for the menu bar and
/// the command palette: its name, its key, and why it can't run now. Nothing
/// here removes anything: cleanup starts from its pane's own button and
/// confirmation, behind the same keep, access and job checks.
struct AppCommand: Identifiable {
    enum ID: String, CaseIterable {
        case back, forward, refresh, find, undo, chooseFolder, enclosingFolder, settings, palette
    }

    let id: ID
    let title: String
    let symbol: String
    let key: KeyEquivalent?
    var modifiers: EventModifiers = .command
    /// Why it can't run now; nil when it can.
    let blocker: String?
    let perform: @MainActor () -> Void

    /// "⌘R", for the palette.
    var shortcutText: String? {
        guard let key else { return nil }
        let mods = (modifiers.contains(.option) ? "⌥" : "") + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
        let name: String =
            switch key {
            case .upArrow: "↑"
            case .downArrow: "↓"
            case .leftArrow: "←"
            case .rightArrow: "→"
            default: String(key.character).uppercased()
            }
        return mods + name
    }
}

@MainActor
extension AppModel {
    func command(_ id: AppCommand.ID) -> AppCommand {
        let command = availableCommand(id)
        guard leaving else { return command }
        return AppCommand(id: command.id, title: command.title, symbol: command.symbol, key: command.key,
                          modifiers: command.modifiers, blocker: String(localized: "MyMole is preparing to uninstall and quit."), perform: {})
    }

    private func availableCommand(_ id: AppCommand.ID) -> AppCommand {
        switch id {
        case .back:
            return AppCommand(
                id: id, title: String(localized: "Back"), symbol: "chevron.left", key: .leftArrow, modifiers: [.command, .option],
                blocker: history.canGoBack ? nil : String(localized: "No pane to go back to.")
            ) { [self] in goBack() }
        case .forward:
            return AppCommand(
                id: id, title: String(localized: "Forward"), symbol: "chevron.right", key: .rightArrow, modifiers: [.command, .option],
                blocker: history.canGoForward ? nil : String(localized: "No pane to go forward to.")
            ) { [self] in goForward() }
        case .refresh:
            let r = refreshAction
            return AppCommand(id: id, title: r.title, symbol: "arrow.clockwise", key: "r", blocker: r.blocker, perform: r.run)
        case .find:
            let blocker = pane.hasSearch ? nil : String(localized: "\(pane.title) has no search.")
            return AppCommand(id: id, title: String(localized: "Find"), symbol: "magnifyingglass", key: "f", blocker: blocker) { [self] in findRequest += 1 }
        case .undo:
            guard let u = paneUndo else {
                return AppCommand(id: id, title: String(localized: "Undo"), symbol: "arrow.uturn.backward", key: "z", blocker: String(localized: "Nothing on this pane to put back.")) {}
            }
            return AppCommand(id: id, title: u.title, symbol: "arrow.uturn.backward", key: "z", blocker: nil, perform: u.run)
        case .chooseFolder:
            return AppCommand(
                id: id, title: String(localized: "Map Another Folder…"), symbol: "folder.badge.plus", key: "o",
                blocker: diskMapBlocker ?? (storage.scanning ? String(localized: "Wait for the scan to finish, or stop it.") : nil)
            ) { [self] in
                pane = .diskMap
                storage.chooseFolder()
            }
        case .enclosingFolder:
            let up = storage.current?.parent
            return AppCommand(
                id: id, title: up.map { String(localized: "Back to \($0.name)") } ?? String(localized: "Enclosing Folder"), symbol: "chevron.backward", key: .upArrow,
                blocker: pane != .diskMap ? String(localized: "Only in the Disk Map.") : up == nil ? String(localized: "This is the top of the map.") : nil
            ) { [self] in storage.back() }
        case .settings:
            return AppCommand(id: id, title: String(localized: "Settings…"), symbol: "gearshape", key: ",", blocker: nil) { [self] in pane = .settings }
        case .palette:
            return AppCommand(id: id, title: String(localized: "Command Palette…"), symbol: "command", key: "k", blocker: nil) { [self] in showPalette = true }
        }
    }

    /// Why a pane that works in the user's folders can't now.
    private func accessBlocker(_ pane: Pane) -> String? {
        if let place = gate(for: pane) { return String(localized: "MyMole needs access to \(place.inSentence) first.") }
        if pane.needsDiskAccess && !fullDiskAccess { return String(localized: "MyMole needs Full Disk Access first.") }
        return nil
    }

    private var diskMapBlocker: String? { accessBlocker(.diskMap) }

    /// What ⌘R does on the pane showing, or why it can't.
    private var refreshAction: (title: String, blocker: String?, run: @MainActor @Sendable () -> Void) {
        let access = accessBlocker(pane)
        let busy = String(localized: "It's already running.")
        switch pane {
        case .dashboard:
            return (String(localized: "Scan All"), canScan ? nil : String(localized: "MyMole needs access first."), { [self] in scanAll() })
        case .clean:
            return (String(localized: "Scan Again"), access ?? (deepClean.scanning ? busy : nil), { [self] in deepClean.scan() })
        case .installer:
            return (String(localized: "Scan Again"), access ?? (installers.scanning ? busy : nil), { [self] in installers.scan() })
        case .projects:
            return (String(localized: "Scan Again"), access ?? (projects.scanning ? busy : nil), { [self] in projects.scan() })
        case .uninstall:
            return (String(localized: "Reload Apps"), access ?? (apps.loading ? busy : nil), { [self] in apps.load() })
        case .diskMap:
            return (String(localized: "Scan Again"), access ?? (storage.scanning ? busy : nil), { [self] in storage.rescan() })
        case .systemClean:
            return (String(localized: "Scan Again"), systemClean.scanning || systemClean.removing ? busy : nil, { [self] in systemClean.scan() })
        case .optimize:
            return (String(localized: "Check Again"), access ?? (maintenance.phase != .idle ? busy : nil), { [self] in maintenance.check() })
        case .status:
            return (String(localized: "Refresh"), nil, { [self] in Task { await refreshStatus(maxAge: 0) } })
        case .history:
            return (String(localized: "Refresh"), nil, { [self] in Task { await refreshHistory() } })
        case .startup:
            return (String(localized: "Reload"), access ?? (startup.loading ? busy : nil), { [self] in startup.load() })
        case .duplicates where UserDefaults.standard.string(forKey: DuplicatesShow.key) == DuplicatesShow.similar.rawValue:
            return (String(localized: "Search Again"), access ?? (similar.scanning ? busy : nil), { [self] in similar.scan() })
        case .duplicates:
            return (String(localized: "Search Again"), access ?? (duplicates.scanning ? busy : nil), { [self] in duplicates.scan() })
        case .settings:
            return (String(localized: "Refresh"), String(localized: "Nothing to refresh here."), {})
        }
    }

    /// The Trash Undo of the pane showing, while there's one to do.
    private var paneUndo: (title: String, run: @MainActor @Sendable () -> Void)? {
        switch pane {
        case .clean where deepClean.canUndo: (String(localized: "Undo Move to Trash"), { [self] in deepClean.undoTrash() })
        case .installer where installers.canUndo: (String(localized: "Undo Move to Trash"), { [self] in installers.undoTrash() })
        case .projects where projects.canUndo: (String(localized: "Undo Move to Trash"), { [self] in projects.undoTrash() })
        case .diskMap where storage.canUndo: (String(localized: "Undo Move to Trash"), { [self] in storage.undoTrash() })
        case .uninstall where apps.canUndo: (String(localized: "Undo Uninstall"), { [self] in apps.undoLatest() })
        case .startup where startup.canUndo: (String(localized: "Undo Move to Trash"), { [self] in startup.undoTrash() })
        case .duplicates where duplicates.canUndo: (String(localized: "Undo Move to Trash"), { [self] in duplicates.undoTrash() })
        case .duplicates where similar.canUndo: (String(localized: "Undo Move to Trash"), { [self] in similar.undoTrash() })
        default: nil
        }
    }

    /// Everything the palette offers: the commands, then every pane.
    var paletteEntries: [PaletteEntry] {
        let commands = AppCommand.ID.allCases.filter { $0 != .palette }.map(command).map {
            PaletteEntry(id: $0.id.rawValue, title: $0.title, symbol: $0.symbol, shortcut: $0.shortcutText, blocker: $0.blocker, perform: $0.perform)
        }
        let panes = Pane.groups.flatMap(\.1).map { p in
            PaletteEntry(
                id: "pane." + p.rawValue, title: String(localized: "Go to \(p.title)"), symbol: p.symbol,
                shortcut: p.shortcut.map { "⌘" + String($0.character) }, blocker: nil
            ) { [self] in pane = p }
        }
        return commands + panes
    }
}

/// How one module of a Smart Scan stands.
enum ModuleState: Equatable {
    case notYet, running, done, partial, failed
    /// The last Smart Scan didn't finish it (stopped, or access changed):
    /// what's shown is from before.
    case earlier

    var text: String {
        switch self {
        case .earlier: String(localized: "from an earlier scan")
        case .notYet: String(localized: "not scanned")
        case .running: String(localized: "scanning")
        case .done: String(localized: "scanned")
        case .partial: String(localized: "partly read")
        case .failed: String(localized: "failed")
        }
    }
}

@MainActor
extension AppModel {
    /// What a Smart Scan checks, in the order it shows them. Projects and the
    /// Disk Map walk whole folders and scan on their own panes.
    var smartScanModules: [Pane] {
        [.clean, .installer, .uninstall, .optimize] + (privileged.isAvailable && Edition.current.hasSystemTasks ? [.systemClean] : [])
    }

    func moduleState(_ pane: Pane) -> ModuleState {
        let state = readState(pane)
        // Finished before the last Smart Scan began: it didn't get through this time.
        if state == .done || state == .partial, let started = smartScanStarted, let at = smartScanFinishedAt(pane), at < started {
            return .earlier
        }
        return state
    }

    /// When the module last finished, for telling a fresh result from an earlier one.
    func smartScanFinishedAt(_ pane: Pane) -> Date? {
        switch pane {
        case .clean: deepClean.scannedAt
        case .installer: installers.scannedAt
        case .uninstall: apps.scannedAt
        case .optimize: maintenance.checkedAt
        case .systemClean: systemClean.scannedAt
        default: nil
        }
    }

    private func readState(_ pane: Pane) -> ModuleState {
        switch pane {
        case .clean:
            deepClean.scanning ? .running : deepClean.scannedAt == nil ? .notYet
                : !deepClean.unreadablePlaces.isEmpty || deepClean.candidates.contains(where: \.incomplete) ? .partial : .done
        case .installer:
            installers.scanning ? .running : installers.scannedAt == nil ? .notYet : !installers.unreadableFolders.isEmpty ? .partial : .done
        case .uninstall:
            apps.loading ? .running : apps.scannedAt == nil ? .notYet : !apps.unreadableFolders.isEmpty ? .partial : .done
        case .optimize:
            maintenance.phase != .idle ? .running : maintenance.checkedAt == nil ? .notYet : .done
        case .systemClean:
            systemClean.scanning ? .running : systemClean.currentError != nil ? .failed : systemClean.scannedAt == nil ? .notYet : .done
        default:
            .notYet
        }
    }

    /// "Checks Deep Clean, Installers, the app list and Optimize."
    var smartScanScope: String {
        let names = smartScanModules.map { $0 == .uninstall ? String(localized: "the app list") : $0.title }
        let list = names.count > 1
            ? String(localized: "\(names.dropLast().joined(separator: ", ")) and \(names.last ?? "")") : names.joined()
        return String(localized: "Checks \(list). Projects, Startup Items, Duplicates and the Disk Map read whole folders and scan on their own panes. Nothing is deleted until you confirm.")
    }
}

extension Pane {
    /// Panes whose list has a search field that ⌘F focuses.
    var hasSearch: Bool { [.clean, .installer, .uninstall, .diskMap, .projects, .startup, .duplicates, .settings].contains(self) }
}

struct PaletteEntry: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let shortcut: String?
    let blocker: String?
    let perform: @MainActor () -> Void

    /// Every word of the query, in order of typing or not, starts a word of
    /// the title or appears in it.
    static func matches(_ title: String, _ query: String) -> Bool {
        let words = query.lowercased().split(separator: " ")
        let t = title.lowercased()
        return words.allSatisfy { t.contains($0) }
    }
}

/// ⌘K: find a command or a pane by typing. ↑ and ↓ choose, Return runs it,
/// Escape closes. A command that can't run says why instead.
struct CommandPalette: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var chosen = 0
    @FocusState private var focused: Bool

    private var shown: [PaletteEntry] {
        query.isEmpty ? app.paletteEntries : app.paletteEntries.filter { PaletteEntry.matches($0.title, query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            DSControlField("Find a command or view") {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "command").foregroundStyle(.secondary)
                    TextField("Type a command or a pane", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                        .onSubmit(run)
                        .accessibilityLabel("Command")
                }
            }
            .padding(DS.Space.md)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, e in
                        row(e, highlighted: i == chosen)
                            .id(i)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                chosen = i
                                run()
                            }
                    }
                }
                .listStyle(.plain)
                .onChange(of: chosen) { _, i in proxy.scrollTo(i) }
            }
            .overlay {
                if shown.isEmpty { ContentUnavailableView.search(text: query) }
            }
            Divider()
            Text("↑ ↓ to choose · Return to open · Esc to close")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(DS.Space.sm)
        }
        .frame(width: 520, height: 380)
        .onAppear { focused = true }
        .onChange(of: query) { chosen = 0 }
        .onKeyPress(.downArrow) {
            chosen = min(chosen + 1, max(shown.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            chosen = max(chosen - 1, 0)
            return .handled
        }
        .onExitCommand { dismiss() }
    }

    private func row(_ e: PaletteEntry, highlighted: Bool) -> some View {
        HStack(spacing: DS.Space.sm) {
            DSIcon(symbol: e.symbol)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(e.title).foregroundStyle(e.blocker == nil ? .primary : .secondary)
                if let why = e.blocker { DSText(why, .metadata) }
            }
            Spacer(minLength: DS.Space.sm)
            if let s = e.shortcut { Text(s).font(.callout.monospaced()).foregroundStyle(.secondary) }
        }
        .padding(.vertical, DS.Space.xxs)
        .listRowBackground(highlighted ? Color.accentColor.opacity(0.18) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
        .accessibilityHint(e.blocker ?? "")
    }

    private func run() {
        guard chosen < shown.count else { return }
        let e = shown[chosen]
        guard e.blocker == nil else { return }
        dismiss()
        e.perform()
    }
}

// MARK: - Find

private struct FindRequestKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// Bumped by ⌘F: the search field of the pane showing takes the focus.
    var findRequest: Int {
        get { self[FindRequestKey.self] }
        set { self[FindRequestKey.self] = newValue }
    }
}
