import AppKit
import StorageKit
import SwiftUI

/// Several apps uninstalled together: each with what it left in the
/// Library, caches and parts of the app chosen, settings and data only when
/// chosen. An app that's open, ships its own uninstaller or is kept stays.
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
    /// Chosen apps and leftovers, by path.
    @State private var chosen = Set<String>()
    @State private var selection = Set<String>()
    @State private var kept = Set<String>()
    @State private var locked = Set<String>()
    @State private var keepsUnreadable = false
    @State private var unchecked: [String] = []
    @State private var systemCount = 0
    @State private var confirm = false
    @State private var problems: [(name: String, reason: String)] = []
    @State private var ran = false

    private var chosenApps: [AppBundle] { apps.filter { chosen.contains($0.path) && blocked[$0.path] == nil } }

    private func chosenLeftovers(of app: AppBundle) -> [Leftover] {
        guard chosen.contains(app.path) else { return [] }
        return (found?[app.path] ?? []).filter { chosen.contains($0.path) }
    }

    private var total: Int64 {
        chosenApps.reduce(0) { sum, app in sum + app.bytes + chosenLeftovers(of: app).reduce(0) { $0 + $1.bytes } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("Uninstall \(apps.count) Apps").font(.title2.bold())
            DSText(
                "Each app goes to the Trash with what it left in your Library. Caches and parts of the apps are chosen; settings and data stay unless you choose them.",
                .metadata)
            if !problems.isEmpty {
                DSNotice(.warning, problems.map { "\($0.name): \($0.reason)" }.joined(separator: "\n"))
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
                    "MyMole couldn't look up other copies of \(unchecked.joined(separator: ", ")), so their leftovers aren't offered. The apps themselves can still go."
                )
            }
            if systemCount > 0 {
                DSNotice(
                    .info,
                    "\(systemCount) item\(systemCount == 1 ? "" : "s") outside your Library, such as launch jobs, \(systemCount == 1 ? "is" : "are") offered when you uninstall the app on its own."
                )
            }
            if found != nil {
                FileTable(
                    rows: rows,
                    columns: [.name, .size, .kind, .location],
                    titles: [.kind: String(localized: "What")],
                    autosave: "uninstall.batch",
                    selection: $selection,
                    marks: chosen,
                    onToggleMark: toggle,
                    onOpen: { FileActions.reveal($0) }
                )
                .frame(height: 320)
            } else {
                DSLoading("Finding everything \(apps.count) apps left behind…").frame(height: 320)
            }
            DSActionGroup {
                DSText(
                    String(
                        localized: "\(chosenApps.count) app\(chosenApps.count == 1 ? "" : "s") · \(ByteSize.format(total)) to the Trash"),
                    .lead)
            } trailing: {
                Button(ran ? "Done" : "Cancel") { dismiss() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                if !ran {
                    Button(
                        model.uninstalling ? String(localized: "Uninstalling…") : String(localized: "Uninstall \(chosenApps.count)"),
                        role: .destructive
                    ) { confirm = true }
                    .primaryAction()
                    .tint(.red)
                    .disabled(found == nil || chosenApps.isEmpty || model.uninstalling || keepsUnreadable)
                }
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.reviewWidth)
        .task { await load() }
        .actionConfirmation(
            String(localized: "Uninstall \(chosenApps.count) apps?"), isPresented: $confirm,
            action: .uninstall, message: confirmText
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
            if let why = blocked[app.path] {
                head.badge = why
                head.badgeTint = .systemOrange
            } else {
                head = marked(head)
            }
            let leftovers = (found?[app.path] ?? []).map {
                marked(FileRow(
                    id: $0.path, name: $0.name, size: $0.bytes, kind: "\(app.name): \($0.kind.title) · \($0.place)",
                    location: ($0.path as NSString).deletingLastPathComponent, symbol: "folder",
                    subtitle: String(localized: "Found \($0.evidence.title)")))
            }
            return [head] + (blocked[app.path] == nil ? leftovers : [])
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
        guard !ran, !kept.contains(id) else { return }
        if apps.contains(where: { $0.path == id }) {
            guard blocked[id] == nil else { return }
            let leftovers = found?[id] ?? []
            if chosen.contains(id) {
                chosen.remove(id)
                chosen.subtract(leftovers.map(\.path))
            } else {
                chosen.insert(id)
                chosen.formUnion(leftovers.filter { $0.chosenByDefault && !kept.contains($0.path) }.map(\.path))
            }
        } else if let owner = apps.first(where: { (found?[$0.path] ?? []).contains { $0.path == id } }), chosen.contains(owner.path) {
            if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
        }
    }

    private func load() async {
        var map: [String: [Leftover]] = [:]
        var why: [String: String] = [:]
        var notChecked: [String] = []
        var system = 0
        for app in apps {
            if model.isSelf(app) {
                why[app.path] = String(localized: "Uninstall MyMole on its own from Settings.")
            } else if app.isProtected {
                why[app.path] = String(localized: "Part of macOS")
            } else if model.running(app) {
                why[app.path] = String(localized: "Open")
            } else if await model.ownUninstaller(of: app) != nil {
                why[app.path] = String(localized: "Has its own uninstaller")
            }
            if let leftovers = await model.leftovers(for: app) {
                map[app.path] = leftovers
            } else {
                map[app.path] = []
                notChecked.append(app.name)
            }
            system += await model.systemLeftovers(for: app).count
        }
        let all = apps.map(\.path) + map.values.flatMap { $0.map(\.path) }
        let keptHere = await model.kept(among: all)
        keepsUnreadable = keptHere == nil
        kept = keptHere ?? []
        for app in apps where kept.contains(app.path) && why[app.path] == nil { why[app.path] = String(localized: "Kept") }
        locked = await Task.detached(priority: .userInitiated) { Set(all.filter(Locks.isLocked)) }.value
        blocked = why
        unchecked = notChecked
        systemCount = system
        chosen = Set(apps.filter { why[$0.path] == nil }.flatMap { app in
            [app.path] + (map[app.path] ?? []).filter(\.chosenByDefault).map(\.path)
        }).subtracting(kept)
        found = map
    }

    private func run() {
        let items = chosenApps.map { AppsModel.BatchItem(app: $0, leftovers: chosenLeftovers(of: $0)) }
        Task {
            problems = await model.uninstall(batch: items)
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
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            running = model.running(item.app)
                        }
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
        .task { running = model.running(item.app) }
        .confirmationDialog("Eject and move \(item.image?.name ?? "") to the Trash?", isPresented: $confirm) {
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
    }
}
