import AppKit
import StorageKit
import SwiftUI

/// Several apps uninstalled together: each with what it left in the
/// Library, only identity-linked caches and logs initially chosen. All other
/// data needs an explicit choice. An app that's open, has an uninstaller or is kept stays.
/// System-wide leftovers are offered when an app is uninstalled on its own.
struct BatchUninstallSheet: View {
    let model: AppsModel
    let apps: [AppBundle]
    /// Called once the batch has run.
    let finished: () -> Void
    @Environment(\.dismiss) private var dismiss
    /// Each app's leftovers, by the app's path; nil while they're looked for.
    @State private var found: [String: [Leftover]]?
    /// Why an app stays, by its path.
    @State private var blocked: [String: String] = [:]
    @State private var runningPaths = Set<String>()
    /// Chosen apps and leftovers, by path.
    @State private var chosen = Set<String>()
    @State private var selection = Set<String>()
    @State private var kept = Set<String>()
    @State private var locked = Set<String>()
    @State private var keepsUnreadable = false
    @State private var unchecked: [String] = []
    @State private var incomplete: [String] = []
    @State private var systemCount = 0
    @State private var confirm = false
    @State private var problems: [(name: String, reason: String)] = []
    @State private var ran = false

    @State private var pendingItems: [AppsModel.BatchItem] = []
    @State private var pendingMessage = ""
    @State private var choiceCommitted = false
    @State private var submitted = false
    @State private var searchRequest = UUID()
    @State private var searchFinished = false

    init(model: AppsModel, apps: [AppBundle], finished: @escaping () -> Void) {
        self.model = model
        self.apps = apps
        self.finished = finished
        let running = model.runningPaths(in: apps)
        _chosen = State(initialValue: Set(apps.filter { !$0.isProtected && !model.isSelf($0) }.map(\.path)).subtracting(running))
        _runningPaths = State(initialValue: running)
        _blocked = State(initialValue: Dictionary(apps.compactMap { app -> (String, String)? in
            if model.isSelf(app) { return (app.path, String(localized: "Uninstall MyMole on its own from Settings.")) }
            if app.isProtected { return (app.path, String(localized: "Part of macOS")) }
            return nil
        }, uniquingKeysWith: { first, _ in first }))
    }

    private var chosenApps: [AppBundle] { apps.filter { chosen.contains($0.path) && reason($0.path) == nil } }

    private func reason(_ path: String) -> String? {
        if kept.contains(path) { return String(localized: "Kept") }
        return blocked[path] ?? (runningPaths.contains(path) ? String(localized: "Open") : nil)
    }

    private func refreshRunning() {
        let current = model.runningPaths(in: apps)
        guard current != runningPaths else { return }
        let opening = current.subtracting(runningPaths)
        runningPaths = current
        if !opening.isEmpty {
            confirm = false
            chosen.subtract(opening)
            chosen.subtract(opening.flatMap { (found?[$0] ?? []).map(\.path) })
        }
    }

    private func chosenLeftovers(of app: AppBundle) -> [Leftover] {
        guard chosen.contains(app.path) else { return [] }
        return (found?[app.path] ?? []).filter { $0.canRemove && chosen.contains($0.path) }
    }

    private var total: Int64 {
        chosenApps.reduce(0) { sum, app in sum + app.bytes + chosenLeftovers(of: app).reduce(0) { $0 + $1.bytes } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("Uninstall \(apps.count) Apps").font(.title2.bold())
            DSText(
                "Each app goes to the Trash with the leftovers you choose. Only caches and logs tied by identity start chosen; settings, website data, scripts, launch configuration and name matches stay unless you choose them.",
                .metadata)
            if !problems.isEmpty {
                DSNotice(.warning, problems.map { "\($0.name): \($0.reason)" }.joined(separator: "\n"))
                let denied = chosenApps.filter { model.appMoveFailures[$0.path]?.permissionDenied == true }
                if !denied.isEmpty {
                    AppMoveAccessNotice(paths: denied.map(\.path), code: model.appMoveFailures[denied[0].path]?.code,
                                        administratorMayBeNeeded: denied.contains { model.appMoveNeedsAdministrator.contains($0.path) })
                }
            }
            if keepsUnreadable {
                DSNotice(
                    .critical,
                    "Your keep lists couldn't be read, so nothing is uninstalled until they can be. Look at the lists in Settings and your rules in Projects."
                )
            }
            if !unchecked.isEmpty {
                DSNotice(
                    .warning,
                    "Ownership couldn't be fully verified for \(unchecked.joined(separator: ", ")). Possible leftovers are shown for inspection only. The apps themselves can still go."
                )
            }
            if !incomplete.isEmpty {
                DSNotice(.warning, "The search was limited or partly unreadable for \(incomplete.joined(separator: ", ")). Only completely measured candidates are offered; additional app data may remain.")
            }
            if systemCount > 0 {
                DSNotice(
                    .info,
                    "\(systemCount) item\(systemCount == 1 ? "" : "s") outside your Library, such as launch jobs, \(systemCount == 1 ? "is" : "are") offered when you uninstall the app on its own."
                )
            }
            if !searchFinished, !submitted, !ran {
                HStack(spacing: DS.Space.sm) {
                    PulseDot()
                    DSText("Finding related files…", .metadata)
                }
            }
            FileTable(
                rows: rows,
                columns: [.name, .size, .kind, .location],
                titles: [.kind: String(localized: "What")],
                autosave: "uninstall.batch",
                selection: $selection,
                marks: chosen,
                onToggleMark: toggle,
                onOpen: { FileActions.reveal($0) },
                onSetMarks: setListedMarks
            )
            .frame(height: 320)
            DSActionGroup {
                DSText(
                    String(
                        localized: "\(chosenApps.count) app\(chosenApps.count == 1 ? "" : "s") · \(ByteSize.format(total)) to the Trash"),
                    .lead)
            } trailing: {
                Button(ran ? "Done" : "Cancel") { dismiss() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.uninstalling)
                if !ran {
                    Button(
                        model.uninstalling ? String(localized: "Uninstalling…") : String(localized: "Uninstall \(chosenApps.count)"),
                        role: .destructive
                    ) {
                        choiceCommitted = true
                        pendingItems = chosenApps.map { AppsModel.BatchItem(app: $0, leftovers: chosenLeftovers(of: $0)) }
                        pendingMessage = confirmText
                        confirm = true
                    }
                    .primaryAction()
                    .tint(.red)
                    .disabled(chosenApps.isEmpty || model.uninstalling || submitted || keepsUnreadable)
                }
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.reviewWidth)
        .dialogControls()
        .dialogKeyboard(canClose: !model.uninstalling)
        .task(id: searchRequest) { if !submitted { await load() } }
        .liveRefresh { refreshRunning() }
        .liveRefresh(every: .seconds(10), events: .protections) { await refreshProtections() }
        .actionConfirmation(
            String(localized: "Uninstall \(pendingItems.count) apps?"), isPresented: $confirm,
            action: .uninstall, message: pendingMessage
        ) { run() }
    }

    private var confirmText: String {
        let leftovers = chosenApps.reduce(0) { $0 + chosenLeftovers(of: $1).count }
        var text = String(localized: "\(chosenApps.map(\.name).joined(separator: ", ")) and \(leftovers) leftover\(leftovers == 1 ? "" : "s") are moved to the Trash. You can undo right after.")
        let going = Set(chosenApps.map(\.path) + chosenApps.flatMap { chosenLeftovers(of: $0).map(\.path) })
        let n = locked.intersection(going).count
        if n > 0 { text += " " + String(localized: "\(n) of them \(n == 1 ? "is" : "are") locked in Finder and unlocked to move.") }
        return text
    }

    private var rows: [FileRow] {
        apps.flatMap { app -> [FileRow] in
            var head = FileRow(
                id: app.path, name: app.name, size: app.bytes, kind: String(localized: "App"),
                location: (app.path as NSString).deletingLastPathComponent, symbol: "macwindow")
            if let why = reason(app.path) {
                head.badge = why
                head.badgeTint = .systemOrange
                head.canChoose = false
            } else {
                head = marked(head)
            }
            let leftovers = (found?[app.path] ?? []).map {
                marked(FileRow(
                    id: $0.path, name: $0.name, size: $0.bytes, kind: "\(app.name): \($0.kind.title) · \($0.place)",
                    location: ($0.path as NSString).deletingLastPathComponent, symbol: "folder",
                    subtitle: String(localized: "Found \($0.evidence.title)"),
                    badge: $0.canRemove ? nil : String(localized: "Inspection only"),
                    canChoose: $0.canRemove))
            }
            return [head] + (reason(app.path) == nil ? leftovers : [])
        }
    }

    private func marked(_ row: FileRow) -> FileRow {
        var r = row
        if kept.contains(row.id) {
            r.badge = String(localized: "Kept")
            r.badgeTint = .secondaryLabelColor
            r.canChoose = false
            r.badgeHelp = String(localized: "On one of your keep lists, or holds something that is; it stays")
            r.choiceHelp = r.badgeHelp
        } else if locked.contains(row.id) {
            r.badge = String(localized: "Locked")
            r.badgeTint = .systemOrange
            r.badgeHelp = String(localized: "Locked in Finder: unlocked right before it moves, and locked again if it stays")
        }
        return r
    }

    /// An app's tick takes its leftovers along; a leftover can be ticked
    /// only while its app is.
    private func toggle(_ id: String) {
        guard !ran, !model.uninstalling, !submitted, !kept.contains(id) else { return }
        choiceCommitted = true
        if apps.contains(where: { $0.path == id }) {
            guard reason(id) == nil else { return }
            let leftovers = found?[id] ?? []
            if chosen.contains(id) {
                chosen.remove(id)
                chosen.subtract(leftovers.map(\.path))
            } else {
                chosen.insert(id)
                chosen.formUnion(leftovers.filter { $0.chosenByDefault && !kept.contains($0.path) }.map(\.path))
            }
        } else if let owner = apps.first(where: { (found?[$0.path] ?? []).contains { $0.path == id } }), chosen.contains(owner.path), reason(owner.path) == nil {
            guard (found?[owner.path] ?? []).contains(where: { $0.path == id && $0.canRemove }) else { return }
            if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
        }
    }

    private func setListedMarks(_ ids: [String], checked: Bool) {
        guard !ran, !model.uninstalling, !submitted else { return }
        choiceCommitted = true
        let paths = Set(ids)
        var next = chosen
        for app in apps where reason(app.path) == nil && !kept.contains(app.path) {
            let leftovers = found?[app.path] ?? []
            if paths.contains(app.path) {
                if checked {
                    next.insert(app.path)
                    next.formUnion(leftovers.filter { $0.chosenByDefault && !kept.contains($0.path) }.map(\.path))
                } else {
                    next.remove(app.path)
                    next.subtract(leftovers.map(\.path))
                }
            }
            guard next.contains(app.path) else { continue }
            let eligible = leftovers.filter { paths.contains($0.path) && $0.canRemove && !kept.contains($0.path) }.map(\.path)
            if checked { next.formUnion(eligible) } else { next.subtract(eligible) }
        }
        chosen = next
    }

    private func load() async {
        var map: [String: [Leftover]] = [:]
        var why: [String: String] = [:]
        var notChecked: [String] = []
        var notComplete: [String] = []
        var system = 0
        for app in apps {
            guard !Task.isCancelled else { return }
            if model.isSelf(app) {
                why[app.path] = String(localized: "Uninstall MyMole on its own from Settings.")
            } else if app.isProtected {
                why[app.path] = String(localized: "Part of macOS")
            } else if await model.ownUninstaller(of: app) != nil {
                why[app.path] = String(localized: "Has its own uninstaller")
            }
            if let report = await model.leftoverReport(for: app) {
                map[app.path] = report.items
                if !report.ownershipVerified { notChecked.append(app.name) }
                if report.limited || !report.unreadable.isEmpty { notComplete.append(app.name) }
            } else {
                map[app.path] = []
                notChecked.append(app.name)
            }
            let all = [app.path] + (map[app.path] ?? []).map(\.path)
            let keptHere = await model.kept(among: all)
            let foundLocked = await Task.detached(priority: .userInitiated) { Set(all.filter(Locks.isLocked)) }.value
            guard !Task.isCancelled, !submitted else { return }
            keepsUnreadable = keepsUnreadable || keptHere == nil
            kept.formUnion(keptHere ?? [])
            locked.formUnion(foundLocked)
            blocked.merge(why) { _, fresh in fresh }
            refreshRunning()
            unchecked = notChecked
            incomplete = notComplete
            found = map
            if !choiceCommitted, chosen.contains(app.path), reason(app.path) == nil {
                chosen.formUnion((map[app.path] ?? []).filter(\.chosenByDefault).map(\.path))
            }
            chosen.subtract(kept)
            if reason(app.path) != nil { chosen.subtract(all) }
            system += await model.systemLeftovers(for: app).count
            guard !Task.isCancelled, !submitted else { return }
            systemCount = system
        }
        if !Task.isCancelled, !submitted { searchFinished = true }
    }

    private func refreshProtections() async {
        guard let found, !model.uninstalling else { return }
        let current = await model.kept(among: apps.map(\.path) + found.values.flatMap { $0.map(\.path) })
        let paths = apps.map(\.path) + found.values.flatMap { $0.map(\.path) }
        let currentLocks = await Task.detached(priority: .utility) { Set(paths.filter(Locks.isLocked)) }.value
        guard !Task.isCancelled, !model.uninstalling else { return }
        let unreadable = current == nil
        let protected = current ?? []
        guard protected != kept || unreadable != keepsUnreadable || currentLocks != locked else { return }
        confirm = false
        keepsUnreadable = unreadable
        kept = protected
        locked = currentLocks
        chosen.subtract(kept)
    }

    private func run() {
        guard !submitted, !pendingItems.isEmpty else { return }
        let items = pendingItems
        submitted = true
        searchRequest = UUID()
        Task {
            problems = await model.uninstall(batch: items)
            submitted = false
            ran = true
            finished()
            if problems.isEmpty { dismiss() }
        }
    }
}

/// An app dropped from a mounted disk image: it can't be moved off the
/// image, so the image is ejected and its file moved to the Trash.
struct DiskImageSheet: View {
    let model: AppsModel
    let item: AppsModel.ImageApp
    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var confirm = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: 14) {
                Image(nsImage: AppIcons.icon(item.app.path))
                    .resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.app.name).font(.title2.bold())
                    DSPath(item.app.path, .mono)
                }
            }
            if let image = item.image {
                DSNotice(
                    .info,
                    "\(item.app.name) runs from the disk image \(image.name). An app can't be removed from a disk image: the image is ejected and its file moved to the Trash. A copy in Applications is uninstalled from the list."
                )
                DSPath(image.image, .mono)
            } else {
                DSNotice(
                    .warning,
                    "\(item.app.name) runs from a disk image mounted at \(item.mountPoint), and MyMole couldn't find the image file. Eject it in Finder, then move the image file to the Trash."
                )
            }
            if running {
                DSNotice(.warning, "\(item.app.name) is open. Quit it first.") {
                    Button("Quit App") {
                        model.quit(item.app)
                    }
                    .help("Quit \(item.app.name) before continuing")
                }
            }
            if let problem { DSNotice(.critical, problem) }
            DSActionGroup {
                EmptyView()
            } trailing: {
                Button("Cancel") { dismiss() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.uninstalling)
                if item.image != nil {
                    Button("Eject and Move to Trash…", role: .destructive) { confirm = true }
                        .primaryAction()
                        .tint(.red)
                        .disabled(running || model.uninstalling)
                } else {
                    Button("Show in Finder") { FileActions.reveal([item.mountPoint]) }
                        .primaryAction()
                }
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 560)
        .dialogControls()
        .dialogKeyboard(canClose: !model.uninstalling)
        .liveRefresh {
            let current = model.running(item.app)
            if current != running {
                running = current
                if current { confirm = false }
            }
        }
        .confirmationDialog("Eject and move \(item.image?.name ?? "") to the Trash?", isPresented: $confirm) {
            Button("Cancel", role: .cancel) { confirm = false }
            Button("Move to Trash", role: .destructive) {
                Task {
                    switch await model.removeImage(item) {
                    case .done: dismiss()
                    case .refused(let why), .failed(let why):
                        problem = why
                        running = model.running(item.app)
                    }
                }
            }
        } message: {
            Text("The disk image is ejected, then moved to the Trash. You can undo right after.")
        }
        .confirmationKeyboard(isPresented: $confirm)
    }
}
