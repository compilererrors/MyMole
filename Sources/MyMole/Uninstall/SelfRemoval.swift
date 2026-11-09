import AppKit
import StorageKit
import SwiftUI

/// Self-removal uses the normal uninstall gate and Trash job. Only shutdown
/// preparation differs; no helper or delayed deletion script is installed.
@MainActor @Observable
final class SelfRemovalModel {
    let apps: AppsModel
    private let prepare: @MainActor () async -> String?
    private let resume: @MainActor () -> Void
    private let quit: @MainActor () -> Void
    private(set) var app: AppBundle?
    private(set) var leftovers: [Leftover] = []
    private(set) var loading = false
    private(set) var running = false
    private(set) var removed = false
    private(set) var problem: String?
    private(set) var dataUnavailable = false
    private(set) var dataIncomplete = false
    private(set) var kept = Set<String>()
    private(set) var keepsUnreadable = false
    var chosen = Set<String>()
    var selection = Set<String>()
    private var loadID: UUID?

    init(apps: AppsModel, prepare: @escaping @MainActor () async -> String?,
         resume: @escaping @MainActor () -> Void, quit: @escaping @MainActor () -> Void) {
        self.apps = apps
        self.prepare = prepare
        self.resume = resume
        self.quit = quit
    }

    var available: Bool { apps.ownAppPath != nil }
    var canRemove: Bool { app != nil && !keepsUnreadable && !kept.contains(app?.path ?? "") }
    var chosenLeftovers: [Leftover] { leftovers.filter { $0.canRemove && chosen.contains($0.path) } }

    func load() async {
        guard !running, !removed, let path = apps.ownAppPath else { return }
        let run = UUID()
        loadID = run
        loading = true
        problem = nil
        defer { if loadID == run { loading = false; loadID = nil } }
        let found = await Task.detached(priority: .userInitiated) { AppFinder.read(path) }.value
        guard !Task.isCancelled, loadID == run else { return }
        guard let found, apps.isSelf(found) else {
            problem = String(localized: "This copy of MyMole changed on disk. Open the installed app and try again.")
            app = nil
            return
        }
        app = found
        let report = await apps.leftoverReport(for: found)
        let data = report?.items
        guard !Task.isCancelled, loadID == run else { return }
        let protected = await apps.kept(among: [found.path] + (data ?? []).map(\.path))
        guard !Task.isCancelled, loadID == run else { return }
        leftovers = data ?? []
        dataUnavailable = report?.ownershipVerified != true
        dataIncomplete = report.map { $0.limited || !$0.unreadable.isEmpty } ?? false
        keepsUnreadable = protected == nil
        kept = protected ?? []
        chosen = Set(leftovers.filter(\.chosenByDefault).map(\.path)).subtracting(kept)
    }

    func remove() async {
        guard !running, !loading, !removed, canRemove, let app, apps.isSelf(app) else { return }
        running = true
        problem = nil
        // The capability is scoped to this call and this copy's exact path and ID.
        apps.prepareSelfRemoval = prepare
        defer { apps.prepareSelfRemoval = nil; running = false }
        let result = await apps.uninstall(app, leftovers: chosenLeftovers)
        switch result {
        case .done:
            removed = true
            if apps.leftoverProblems.isEmpty {
                quit()
            } else {
                problem = String(localized: "MyMole is in the Trash. Some chosen data couldn't be moved and stays where it is. Quit when you're ready.")
            }
        case .failed(let why), .refused(let why):
            problem = why
            resume()
        }
    }

    func finish() { guard removed, !running else { return }; quit() }
}

struct SelfRemovalSheet: View {
    @Bindable var model: SelfRemovalModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.md) {
                AppIconImage(size: 48)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    DSText("Uninstall MyMole", .title)
                    DSText("Review this copy and its data before it goes to the Trash.", .metadata)
                }
            }
            DSNotice(
                .info,
                "MyMole stops its scans, turns off Open at Login and moves this copy to the Trash, then quits. Settings and saved results stay unless you choose them. Data another installed copy uses stays. Use Put Back in Finder's Trash to restore anything moved."
            )
            if model.dataUnavailable {
                DSNotice(
                    .warning, "Ownership couldn't be fully verified. Possible data matches are shown for inspection only and stay. This app can still go to the Trash.")
            }
            if model.dataIncomplete {
                DSNotice(.warning, "Some app-data locations couldn't be inspected or the search reached its limit. Only completely measured candidates are offered; additional data may remain.")
            }
            if let problem = model.problem { DSNotice(.warning, problem) }
            if model.keepsUnreadable {
                DSNotice(.critical, "Your keep lists couldn't be read. Nothing is removed until they can be.")
            } else if model.app.map({ model.kept.contains($0.path) }) == true {
                DSNotice(.warning, "This copy of MyMole is kept. Remove it from your Keep list before uninstalling it.")
            }
            if model.loading {
                DSLoading("Finding MyMole and its data…").frame(height: 240)
            } else {
                FileTable(
                    rows: rows, columns: [.name, .size, .kind, .location], autosave: "uninstall.self",
                    selection: $model.selection, marks: model.chosen.union(model.app.flatMap { model.kept.contains($0.path) ? nil : [$0.path] } ?? []),
                    onToggleMark: { path in
                        guard !model.kept.contains(path), model.leftovers.contains(where: { $0.path == path && $0.canRemove }) else { return }
                        if model.chosen.contains(path) { model.chosen.remove(path) } else { model.chosen.insert(path) }
                    }, onOpen: { FileActions.reveal($0) }
                )
                .frame(height: 240)
                .disabled(model.running || model.removed)
            }
            if model.removed, !model.apps.leftoverProblems.isEmpty {
                DSText(
                    model.apps.leftoverProblems.map { ($0.path as NSString).abbreviatingWithTildeInPath + ": " + $0.reason }.joined(
                        separator: "\n"), .metadata)
            }
            DSActionGroup {
                DSText("\(model.chosenLeftovers.count) data item\(model.chosenLeftovers.count == 1 ? "" : "s") chosen", .metadata)
            } trailing: {
                if model.removed {
                    Button("Quit MyMole") { model.finish() }.primaryAction()
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                        .disabled(model.running)
                    Button(model.running ? "Uninstalling…" : "Uninstall MyMole and Quit…", role: .destructive) { confirming = true }
                        .primaryAction().tint(.red)
                        .disabled(model.loading || model.running || !model.canRemove)
                }
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.reviewWidth)
        .dialogKeyboard(canClose: !model.running && !model.removed)
        .task { await model.load() }
        .actionConfirmation(
            String(localized: "Uninstall this copy of MyMole?"), isPresented: $confirming,
            button: String(localized: "Uninstall MyMole and Quit"),
            message: String(
                localized:
                    "This app and the \(model.chosenLeftovers.count) chosen data item\(model.chosenLeftovers.count == 1 ? "" : "s") go to the Trash. Open at Login is turned off. MyMole then quits. You can restore them with Put Back in Finder's Trash; in-app Undo isn't available after quitting."
            )
        ) {
            Task { await model.remove() }
        }
    }

    private var rows: [FileRow] {
        (model.app.map {
            let kept = model.kept.contains($0.path)
            return [
                FileRow(
                    id: $0.path, name: $0.name, size: $0.bytes, kind: String(localized: "This app"),
                    location: ($0.path as NSString).deletingLastPathComponent,
                    symbol: "app", badge: kept ? String(localized: "Kept") : String(localized: "Required"), badgeTint: .secondaryLabelColor,
                    canChoose: false,
                    choiceHelp: kept
                        ? String(localized: "This copy is kept and cannot be uninstalled.")
                        : String(localized: "This copy is included when you uninstall MyMole."))
            ]
        } ?? [])
            + model.leftovers.map {
                let kept = model.kept.contains($0.path)
                return FileRow(
                    id: $0.path, name: $0.name, size: $0.bytes, kind: $0.kind.title,
                    location: ($0.path as NSString).deletingLastPathComponent, symbol: "folder",
                    badge: kept ? String(localized: "Kept") : ($0.canRemove ? nil : String(localized: "Inspection only")), badgeTint: .secondaryLabelColor, canChoose: !kept && $0.canRemove,
                    choiceHelp: kept ? String(localized: "On your keep list; this data stays.") : nil)
            }
    }
}
