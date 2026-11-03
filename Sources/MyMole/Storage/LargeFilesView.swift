import StorageKit
import SwiftUI

/// Every file of 1 MB or more in the scan, in one Finder-style table
/// (`FileTable`): filter by kind, date or name, sort by any column, tick as
/// many as you like. Files appear while the scan is still running.
struct LargeFilesView: View {
    @Bindable var model: StorageModel
    @State private var query = ""
    @State private var kind: FileKind?
    @State private var date = DateFilter()
    @State private var selection = Set<String>()

    private var rows: [LargeFile] {
        model.largeFiles.filter { f in
            (kind == nil || f.kind == kind)
                && date.matches(f.modified)
                && (query.isEmpty || f.name.localizedCaseInsensitiveContains(query)
                    || f.folder.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        let shown = rows
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let picked = shown.filter { selection.contains($0.id) }
        VStack(spacing: 0) {
            HStack(spacing: Theme.gap) {
                DSFilterField("Filter by name or folder", text: $query)
                    .frame(maxWidth: 260)
                Picker("Kind", selection: $kind) {
                    Text("All Kinds").tag(FileKind?.none)
                    Divider()
                    ForEach(FileKind.allCases, id: \.self) { Text($0.title).tag(FileKind?.some($0)) }
                }
                .fixedSize()
                DateFilterControl(filter: $date)
                Spacer()
                if model.scanning { PulseDot() }
                DSText(
                    picked.isEmpty
                        ? "\(shown.count.formatted()) files · \(ByteCountFormatter.string(fromByteCount: shown.reduce(0) { $0 + $1.size }, countStyle: .file))\(model.scanning ? " so far" : "")"
                        : "\(picked.count.formatted()) of \(shown.count.formatted()) selected · \(ByteCountFormatter.string(fromByteCount: picked.reduce(0) { $0 + $1.size }, countStyle: .file))",
                    .metadata)
                .keepWhole()
                Button("Select All") { selection = Set(shown.map(\.id)) }
                    .disabled(shown.isEmpty)
                    .fixedSize()
                Button("Mark Selected") { model.mark(picked.map(\.marked)) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .help("Mark the selected files for removal (⌘⌫)")
                    .disabled(picked.isEmpty)
                    .fixedSize()
            }
            .labelsHidden()
            .padding(.horizontal, Theme.pad)
            .padding(.vertical, 10)

            FileTable(
                rows: shown.map(fileRow),
                columns: [.name, .size, .modified, .kind, .location],
                hiddenByDefault: [.kind],
                autosave: "diskMap.largeFiles",
                selection: $selection,
                marks: Set(model.marked.keys),
                onToggleMark: { id in byID[id].map { model.toggle($0.marked) } },
                onOpen: { ids in FileActions.reveal(ids) },
                onMark: { ids in model.mark(ids.compactMap { byID[$0] }.map(\.marked)) },
                menu: { ids in menu(ids.compactMap { byID[$0] }, rows: shown) })
        }
        .overlay {
            if model.largeFiles.isEmpty {
                if model.scanning {
                    CenterCard(symbol: nil, title: "Looking for large files…", subtitle: "They appear here as the scan finds them.") {}
                } else {
                    ContentUnavailableView("No Large Files", systemImage: "doc.badge.ellipsis",
                                           description: Text("Nothing of 1 MB or more in this scan."))
                }
            }
        }
    }

    private func fileRow(_ f: LargeFile) -> FileRow {
        FileRow(
            id: f.path, name: f.name, size: f.size, modified: f.modified, kind: f.kind.title,
            location: f.folder, symbol: f.kind.symbol, tint: NSColor(ChartColors.kind(f.kind)))
    }

    private func menu(_ chosen: [LargeFile], rows: [LargeFile]) -> [TableMenuEntry] {
        guard !chosen.isEmpty else { return [] }
        var out: [TableMenuEntry] = [.quickLook]
        if chosen.count == 1, !model.scanning {
            out.append(.action("Show in Disk Map") { model.show(folder: chosen[0].folder, select: chosen[0].path) })
        }
        out.append(.divider)
        let unmarked = chosen.filter { !model.isMarked($0.path) }
        if !unmarked.isEmpty {
            out.append(.action(unmarked.count == 1 ? "Mark for Removal" : "Mark \(unmarked.count) for Removal") {
                model.mark(unmarked.map(\.marked))
            })
        }
        if unmarked.count < chosen.count {
            out.append(.action("Unmark") { model.unmark(chosen.map(\.path)) })
        }
        if chosen.count == 1 {
            let d = chosen[0].modified
            let folder = chosen[0].folder
            out.append(.divider)
            out.append(.submenu("Select by Date", [
                .action("Changed On or Before \(d.listText)") { selection = Set(rows.filter { $0.modified <= d }.map(\.id)) },
                .action("Changed On or After \(d.listText)") { selection = Set(rows.filter { $0.modified >= d }.map(\.id)) },
                .action("Changed the Same Day") {
                    selection = Set(rows.filter { Calendar.current.isDate($0.modified, inSameDayAs: d) }.map(\.id))
                },
            ]))
            out.append(.action("Select All in This Folder") { selection = Set(rows.filter { $0.folder == folder }.map(\.id)) })
        }
        out.append(.divider)
        out += FileActions.menu(chosen.map(\.path))
        return out
    }
}
