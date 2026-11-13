import StorageKit
import SwiftUI

struct HistoryView: View {
    let app: AppModel
    @State private var loaded = false

    /// What the runs moved to the Trash or deleted, less what was put back.
    /// Not space won back: what sits in the Trash takes space until it's emptied.
    private var removed: Int64 {
        // An emptied Trash isn't added: what MyMole moved there was counted when it moved.
        app.cleanups.filter { $0.freedSomething && $0.source != TrashModel.source }.reduce(0) { $0 + $1.freedBytes }
    }

    private var movedToTrash: Bool {
        app.cleanups.contains { $0.items > $0.restored && $0.source != "Optimize" && $0.source != "System Clean" }
    }

    var body: some View {
        Group {
            if !loaded {
                DSLoading("Reading the history…")
            } else if app.cleanups.isEmpty {
                CenterCard(symbol: "leaf", title: "No History Yet", subtitle: "Cleanups you run show up here.") {}
            } else {
                VStack(spacing: 0) {
                    DSPaneHeader {
                        DSMetric(
                            ByteSize.format(removed), "moved or deleted in \(app.cleanups.count) run\(app.cleanups.count == 1 ? "" : "s")")
                    } actions: {
                        EmptyView()
                    } strip: {
                        if let last = app.cleanups.first?.date {
                            DSCapsule("Last run \(last.formatted(.relative(presentation: .named)))", symbol: "clock")
                        }
                        DSStatusFact("Undo: the last \(UndoLimit.runs) moves of each pane, until you quit", symbol: "arrow.uturn.backward")
                            .help(
                                "MyMole keeps what it needs to put things back for the last moves of each pane while it runs. After that, or after quitting, Finder's Put Back still works for whatever is in the Trash. This history keeps only counts and sizes, never names."
                            )
                        ForEach(app.trash.otherTrashes, id: \.volume) { t in
                            DSCapsule(
                                "Trash on \(t.name): \(t.partial ? "at least " : "")\(ByteSize.format(t.bytes))", symbol: "externaldrive"
                            )
                            .help(
                                "\(t.count) item\(t.count == 1 ? "" : "s") you moved to the Trash from \(t.name). MyMole only shows it; Finder's Empty Trash empties it with the rest."
                            )
                        }
                        if movedToTrash {
                            DSStatusFact("Trash space returns once it's emptied", symbol: "trash")
                                .help(
                                    "Items moved to the Trash still take space until you empty it. Items deleted for good are counted separately on each run."
                                )
                        }
                        if app.trash.canEmpty, let bytes = app.trash.frees {
                            DSStripButton("Empty Trash (\(ByteSize.format(bytes)))…", symbol: "trash") {
                                Task { await app.trash.askToEmpty() }
                            }
                            .help("Delete what's in the Trash for good, after a confirmation")
                        }
                        DSStatusFact("Counts and sizes only, no file names", symbol: "lock")
                    }
                    Divider()
                    DSPage {
                        DSSection("Runs") {
                            ForEach(app.cleanups) { row($0) }
                        }
                    }
                }
            }
        }
        .paneToolbar("History", subtitle: "Every cleanup run on this Mac") {
            PaneTool.button("history.refresh", "Refresh", symbol: "arrow.clockwise", help: "Reload history") {
                Task { await app.refreshHistory() }
            }
        }
        .task {
            await app.refreshHistory()
            loaded = true
            if app.fullDiskAccess { await app.trash.refresh() }
        }
    }

    private func row(_ r: CleanupRecord) -> some View {
        HStack(spacing: DS.Space.md) {
            DSIcon(symbol: Self.symbol(r.source), large: true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                DSText(r.source, .heading)
                DSText(([r.date.formatted(date: .abbreviated, time: .shortened)] + details(r)).joined(separator: " · "), .metadata)
            }
            Spacer(minLength: DS.Space.md)
            VStack(alignment: .trailing, spacing: DS.Space.xxs) {
                DSValue(r.undone ? "—" : ByteSize.format(r.freedBytes), .heading)
                DSValue(counts(r), .metadata)
            }
            if let undo = app.undo(for: r) {
                Button("Undo") { Task { await undo() } }
                    .controlSize(.small)
                    .fixedSize()
                    .help("Put back what this run moved to the Trash")
            }
        }
    }

    /// What happened besides the main count: failures, permanent
    /// deletions, and how much of an Undo worked.
    private func details(_ r: CleanupRecord) -> [String] {
        var out: [String] = []
        if r.failed > 0 { out.append(String(localized: "\(r.failed) couldn't be removed")) }
        if r.undone {
            out.append(String(localized: "undone"))
        } else if r.restored > 0 {
            out.append(String(localized: "\(r.restored) of \(r.items) put back"))
        }
        if r.restoreFailed > 0 { out.append(String(localized: "\(r.restoreFailed) couldn't be put back")) }
        if Self.inTrashWithoutUndo(r, undoable: app.undo(for: r) != nil) {
            out.append(Self.trashEmptied(after: r, in: app.cleanups)
                ? String(localized: "the Trash was emptied since")
                : String(localized: "Put Back from the Trash in Finder"))
        }
        return out
    }

    private func counts(_ r: CleanupRecord) -> String {
        var parts: [String] = []
        if r.items > 0 {
            let s = r.items == 1 ? "" : "s"
            parts.append(r.source == "Optimize" ? String(localized: "\(r.items) task\(s)") : String(localized: "\(r.items) item\(s)"))
        }
        if r.deleted > 0 { parts.append(String(localized: "\(r.deleted) deleted for good")) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// Moved to the Trash, not all put back, and no longer undoable here:
    /// from an earlier session, or one of more than ten moves ago.
    /// The Trash was emptied by MyMole after `r`, so nothing of it is there to put back.
    static func trashEmptied(after r: CleanupRecord, in all: [CleanupRecord]) -> Bool {
        all.contains { $0.source == TrashModel.source && $0.date > r.date && $0.deleted > 0 }
    }

    static func inTrashWithoutUndo(_ r: CleanupRecord, undoable: Bool) -> Bool {
        !undoable && r.items > r.restored && !["Optimize", "System Clean"].contains(r.source)
    }

    static func symbol(_ source: String) -> String {
        switch source {
        case "Deep Clean": Pane.clean.symbol
        case "Installers": Pane.installer.symbol
        case "Uninstall": Pane.uninstall.symbol
        case "Projects": Pane.projects.symbol
        case "Disk Map": Pane.diskMap.symbol
        case "System Clean": Pane.systemClean.symbol
        case "Optimize": Pane.optimize.symbol
        case StartupModel.source: Pane.startup.symbol
        case DuplicatesModel.source: Pane.duplicates.symbol
        case OrphansModel.source: Pane.uninstall.symbol
        case SimilarModel.source: "photo.on.rectangle"
        case AppsModel.resetSource: "arrow.counterclockwise"
        default: "trash"
        }
    }
}
