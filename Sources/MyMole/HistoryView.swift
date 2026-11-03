import StorageKit
import SwiftUI

struct HistoryView: View {
    let app: AppModel
    @State private var loaded = false

    private var freed: Int64 {
        app.cleanups.filter(\.freedSomething).reduce(0) { $0 + $1.freedBytes }
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
                        DSMetric(ByteSize.format(freed), "freed in \(app.cleanups.count) run\(app.cleanups.count == 1 ? "" : "s")")
                    } actions: {
                        EmptyView()
                    } strip: {
                        if let last = app.cleanups.first?.date {
                            DSCapsule("Last run \(last.formatted(.relative(presentation: .named)))", symbol: "clock")
                        }
                        DSCapsule("Counts and sizes only, no file names", symbol: "lock")
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await app.refreshHistory() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload history")
            }
        }
        .task {
            await app.refreshHistory()
            loaded = true
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
        if r.failed > 0 { out.append("\(r.failed) couldn't be removed") }
        if r.undone {
            out.append("undone")
        } else if r.restored > 0 {
            out.append("\(r.restored) of \(r.items) put back")
        }
        if r.restoreFailed > 0 { out.append("\(r.restoreFailed) couldn't be put back") }
        return out
    }

    private func counts(_ r: CleanupRecord) -> String {
        var parts: [String] = []
        if r.items > 0 { parts.append("\(r.items) \(r.source == "Optimize" ? "task" : "item")\(r.items == 1 ? "" : "s")") }
        if r.deleted > 0 { parts.append("\(r.deleted) deleted for good") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
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
        default: "trash"
        }
    }
}
