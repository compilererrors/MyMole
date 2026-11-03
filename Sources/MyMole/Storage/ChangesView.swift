import StorageKit
import SwiftUI

/// Compare any two saved scans of the mapped folder: what grew, what's new,
/// what shrank or disappeared — down to individual big files.
struct ChangesView: View {
    @Bindable var model: StorageModel
    @State private var filter: Filter = .all
    @State private var showFiles = true

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case grew = "Grew"
        case appeared = "New"
        case shrank = "Shrank"
        case vanished = "Removed"
        var id: String { rawValue }

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
                } else if rows.isEmpty {
                    ContentUnavailableView(
                        "No Big Changes", systemImage: "checkmark.circle",
                        description: Text("Nothing moved by 50 MB or more between these two scans."))
                } else {
                    list
                }
            }
        }
    }

    // MARK: Header: which scans, and the overall picture

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                scanPicker("From", selection: model.compareFrom) { model.compare(from: $0, to: model.compareTo) }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                scanPicker("To", selection: model.compareTo) { model.compare(from: model.compareFrom, to: $0) }
                Spacer()
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Toggle(isOn: $showFiles) { Text("Files").keepWhole() }
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help("Include individual big files")
            }
            summary
        }
    }

    private func scanPicker(_ title: String, selection: SnapshotRef?, set: @escaping @Sendable @MainActor (SnapshotRef?) -> Void) -> some View {
        Picker(title, selection: Binding(get: { selection }, set: set)) {
            ForEach(model.history) { ref in
                Text(label(ref)).tag(SnapshotRef?.some(ref))
            }
        }
        .fixedSize()
    }

    private func label(_ ref: SnapshotRef) -> String {
        let latest = ref == model.history.first ? " (latest)" : ""
        return ref.date.formatted(date: .abbreviated, time: .shortened) + latest
    }

    private var summary: some View {
        let counts = Dictionary(grouping: model.changes, by: \.kind).mapValues(\.count)
        let span: String = {
            guard let a = model.compareFrom?.date, let b = model.compareTo?.date else { return "" }
            return " in " + Duration.seconds(abs(b.timeIntervalSince(a))).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 1))
        }()
        return HStack(spacing: 14) {
            Label {
                Text(signed(model.overallDelta) + " overall" + span)
            } icon: {
                Image(systemName: model.overallDelta >= 0 ? "arrow.up.right" : "arrow.down.right")
            }
            .font(.headline)
            .foregroundStyle(model.overallDelta > 0 ? .orange : .green)
            ForEach(Change.Kind.allCases, id: \.self) { k in
                if let n = counts[k], n > 0 {
                    Text("\(n) \(name(k))").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func name(_ k: Change.Kind) -> String {
        switch k {
        case .grew: "grew"
        case .appeared: "new"
        case .shrank: "shrank"
        case .vanished: "removed"
        }
    }

    // MARK: Rows

    private var list: some View {
        let biggest = Double(rows.map { abs($0.delta) }.max() ?? 1)
        return List(rows) { c in
            row(c, scale: biggest)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func row(_ c: Change, scale: Double) -> some View {
        let (symbol, color) = style(c.kind)
        let absolute = absPath(c)
        return HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).font(.title3)
            Image(systemName: c.isFile ? "doc.fill" : "folder.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                DSPath(c.path, .body)
                HStack(spacing: 8) {
                    Text("\(bytes(c.before)) → \(bytes(c.after))")
                        .font(.caption).foregroundStyle(.secondary)
                    GeometryReader { g in
                        Capsule().fill(color.opacity(0.6))
                            .frame(width: max(2, g.size.width * Double(abs(c.delta)) / max(scale, 1)))
                    }
                    .frame(height: 4)
                }
            }
            Spacer(minLength: 10)
            DSValue(signed(c.delta), .lead, weight: .semibold)
                .foregroundStyle(color)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { show(c) }
        .contextMenu {
            Button("Show in Disk Map") { show(c) }
            if c.after > 0 {
                Button(model.isMarked(absolute) ? "Unmark" : "Mark for Removal") {
                    model.toggle(Marked(path: absolute, name: (c.path as NSString).lastPathComponent, size: c.after, isFolder: !c.isFile))
                }
                Divider()
                FileMenuItems(paths: [absolute], canOpen: c.isFile)
            }
        }
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
