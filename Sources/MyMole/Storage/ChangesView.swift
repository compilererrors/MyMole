import StorageKit
import SwiftUI

/// Compare any two saved scans of the mapped folder: what grew, what's new,
/// what shrank or disappeared — down to individual big files.
struct ChangesView: View {
    @State private var selection = Set<String>()
    @Bindable var model: StorageModel
    @State private var filter: Filter = .all
    @State private var showFiles = true
    @AppStorage(StorageModel.thresholdKey) private var threshold = Int(50 * 1_048_576)

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case grew = "Grew"
        case appeared = "New"
        case shrank = "Shrank"
        case vanished = "Removed"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .grew: String(localized: "Grew")
            case .appeared: String(localized: "New")
            case .shrank: String(localized: "Shrank")
            case .vanished: String(localized: "Removed")
            }
        }

        func matches(_ k: Change.Kind) -> Bool {
            switch self {
            case .all: true
            case .grew: k == .grew
            case .appeared: k == .appeared
            case .shrank: k == .shrank
            case .vanished: k == .vanished
            }
        }
    }

    private var rows: [Change] {
        model.changes.filter { filter.matches($0.kind) && (showFiles || !$0.isFile) }
    }

    var body: some View {
        if model.history.count < 2 {
            ContentUnavailableView {
                Label("One Scan So Far", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("MyMole keeps every scan of a folder. Scan again later — after an update, a project, a week of use — and compare any two to see exactly what grew.")
            } actions: {
                if !model.scanning {
                    Button("Scan Again Now", action: model.rescan).primaryAction()
                }
            }
        } else {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, Theme.pad)
                    .padding(.vertical, 12)
                Divider()
                if model.comparing {
                    DSLoading("Comparing scans…")
                } else if model.overallDelta == nil, model.changes.isEmpty, let why = model.compareProblem {
                    ContentUnavailableView("No Changes Known", systemImage: "exclamationmark.triangle", description: Text(why))
                } else if rows.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No Big Changes"), systemImage: "checkmark.circle",
                        description: Text("Nothing that's compared moved by \(ByteSize.format(Int64(threshold))) or more between these two scans. Smaller changes, and files under \(ByteSize.format(Snapshot.minimumFileSize)), aren't compared one by one."))
                } else {
                    list
                }
            }
        }
    }

    // MARK: Header: which scans, and the overall picture

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            DSControlBar("Compare saved scans", detail: "Choose the earlier and later scans, then narrow which changes appear below.") {
                DSControlField("Earlier scan") {
                    scanPicker(String(localized: "From"), selection: model.compareFrom) { model.compare(from: $0, to: model.compareTo) }
                }
                DSControlField("Later scan") {
                    scanPicker(String(localized: "To"), selection: model.compareTo) { model.compare(from: model.compareFrom, to: $0) }
                }
                DSControlField("Change type") {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                DSControlField("Include") {
                    Toggle(isOn: $showFiles) { Text("Files").keepWhole() }
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .help("Include individual big files")
                }
                DSControlField("Minimum change") {
                    Picker("Minimum change", selection: $threshold) {
                        ForEach(StorageModel.thresholds, id: \.self) { Text("\(ByteSize.format($0)) or more").tag(Int($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("The smallest change listed")
                    .onChange(of: threshold) { model.compare(from: model.compareFrom, to: model.compareTo) }
                }
            }
            summary
            DSText(coverage, .metadata)
        }
    }

    /// What a saved scan holds, so "no big changes" isn't read as "nothing changed".
    private var coverage: String {
        String(localized: "Each scan keeps folders \(Snapshot.depth) levels deep from \(ByteSize.format(Snapshot.minimumSize)) and files from \(ByteSize.format(Snapshot.minimumFileSize)); changes below \(ByteSize.format(Int64(threshold))) aren't listed, and smaller files aren't compared one by one.")
    }

    private func scanPicker(_ title: String, selection: SnapshotRef?, set: @escaping @Sendable @MainActor (SnapshotRef?) -> Void) -> some View {
        Picker(title, selection: Binding(get: { selection }, set: { value in set(value) })) {
            ForEach(model.history) { ref in
                Text(label(ref)).tag(SnapshotRef?.some(ref))
            }
        }
        .labelsHidden()
        .frame(width: 210, alignment: .leading)
        .help(selection.map(label) ?? String(localized: "Choose a saved scan"))
    }

    private func label(_ ref: SnapshotRef) -> String {
        let date = ref.date.formatted(date: .abbreviated, time: .shortened)
        return ref == model.history.first ? String(localized: "\(date) (latest)") : date
    }

    private var summary: some View {
        let counts = Dictionary(grouping: model.changes, by: \.kind).mapValues(\.count)
        let span: String? = {
            guard let a = model.compareFrom?.date, let b = model.compareTo?.date else { return nil }
            return Duration.seconds(abs(b.timeIntervalSince(a))).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 1))
        }()
        return HStack(spacing: 14) {
            if let delta = model.overallDelta {
                Label {
                    Text(span.map { String(localized: "\(signed(delta)) overall in \($0)") } ?? String(localized: "\(signed(delta)) overall"))
                } icon: {
                    Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                }
                .font(.headline)
                .foregroundStyle(delta > 0 ? .orange : .green)
            } else {
                Label("Overall change unknown", systemImage: "questionmark.circle")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .help(model.compareProblem ?? "")
            }
            ForEach(Change.Kind.allCases, id: \.self) { k in
                if let n = counts[k], n > 0 {
                    Text("\(n) \(name(k))").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func name(_ k: Change.Kind) -> String {
        switch k {
        case .grew: String(localized: "grew")
        case .appeared: String(localized: "new")
        case .shrank: String(localized: "shrank")
        case .vanished: String(localized: "removed")
        }
    }

    // MARK: Rows

    /// On the app's AppKit table, like every big file list: sorting,
    /// keyboard, Quick Look and menus behave the same as elsewhere.
    private var list: some View {
        let byID = Dictionary(rows.map { (absPath($0), $0) }, uniquingKeysWith: { a, _ in a })
        return FileTable(
            rows: rows.map(fileRow),
            columns: [.name, .change, .size, .kind, .location],
            titles: [.size: String(localized: "Now"), .kind: String(localized: "Change")],
            autosave: "diskMap.changes",
            defaultSort: .change,
            selection: $selection,
            marks: nil,
            onOpen: { ids in if let c = ids.first.flatMap({ byID[$0] }) { show(c) } },
            menu: { ids in menu(ids.compactMap { byID[$0] }) })
    }

    private func fileRow(_ c: Change) -> FileRow {
        let (symbol, color) = style(c.kind)
        let absolute = absPath(c)
        var r = FileRow(
            id: absolute, name: (c.path as NSString).lastPathComponent, size: c.after, kind: name(c.kind).capitalized,
            location: (absolute as NSString).deletingLastPathComponent, symbol: symbol, tint: NSColor(color))
        r.change = c.delta
        r.changeHelp = "\(bytes(c.before)) → \(bytes(c.after))"
        return r
    }

    private func menu(_ picked: [Change]) -> [TableMenuEntry] {
        guard let first = picked.first else { return [] }
        var out: [TableMenuEntry] = [.action(String(localized: "Show in Disk Map")) { show(first) }]
        let present = picked.filter { $0.after > 0 }
        if !present.isEmpty {
            let marks = present.map { Marked(path: absPath($0), name: ($0.path as NSString).lastPathComponent, size: $0.after, isFolder: !$0.isFile) }
            let allMarked = marks.allSatisfy { model.isMarked($0.path) }
            out.append(.action(allMarked ? String(localized: "Unchoose") : String(localized: "Choose for Removal")) { for m in marks where model.isMarked(m.path) == allMarked { model.toggle(m) } })
            out.append(.divider)
            out += FileActions.menu(present.map(absPath), canOpen: present.count == 1 && present[0].isFile)
        }
        return out
    }

    private func style(_ k: Change.Kind) -> (String, Color) {
        switch k {
        case .grew: ("arrow.up.circle.fill", .orange)
        case .appeared: ("plus.circle.fill", .orange)
        case .shrank: ("arrow.down.circle.fill", .green)
        case .vanished: ("minus.circle.fill", .green)
        }
    }

    private func absPath(_ c: Change) -> String {
        let root = model.root?.path ?? model.rootPath
        return root == "/" ? "/" + c.path : root + "/" + c.path
    }

    /// Opens the folder in the Browse tab (the file's folder, for a file).
    private func show(_ c: Change) {
        let target = c.isFile ? (absPath(c) as NSString).deletingLastPathComponent : absPath(c)
        guard let f = model.root?.find(path: target) else { return }
        model.open(f)
        model.tab = .browse
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private func signed(_ n: Int64) -> String {
        (n >= 0 ? "+" : "−") + ByteCountFormatter.string(fromByteCount: abs(n), countStyle: .file)
    }
}
