import StorageKit
import SwiftUI

/// The Disk Map pane: chart and list side by side, plus Large Files,
/// Changes since the last scan, and the folders that couldn't be read.
struct StorageView: View {
    @Bindable var model: StorageModel

    var body: some View {
        VStack(spacing: 0) {
            PathBar(model: model)
            Group {
                switch model.tab {
                case .browse: browse
                case .largeFiles: LargeFilesView(model: model)
                case .changes: ChangesView(model: model)
                case .skipped: SkippedView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !model.marked.isEmpty { BasketBar(model: model) }
        }
        .overlay(alignment: .bottom) { NoticeToast(model: model).padding(.bottom, model.marked.isEmpty ? 16 : 70) }
        .sheet(isPresented: $model.showReview) { ReviewSheet(model: model) }
        .paneToolbar("Disk Map", subtitle: subtitle) { tools }
        .onAppear {
            if model.root == nil && !model.scanning {
                model.scan(path: Home.path)
            }
        }
    }

    private var subtitle: String {
        if model.scanning {
            return "Scanning… \(model.liveFiles.formatted()) files · \(ByteCountFormatter.string(fromByteCount: model.liveBytes, countStyle: .file))"
        }
        guard let r = model.root else { return "Where your space went" }
        let took = model.lastDuration.map { String(format: " in %.0f s", $0) } ?? ""
        return "\(ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file)) in \(r.fileCount.formatted()) files\(took)"
    }

    @ToolbarContentBuilder private var tools: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Section", selection: $model.tab) {
                Text("Browse").tag(StorageModel.Tab.browse)
                Text("Large Files").tag(StorageModel.Tab.largeFiles)
                Text("Changes").tag(StorageModel.Tab.changes)
                if !model.denied.isEmpty { Text("Skipped (\(model.denied.count))").tag(StorageModel.Tab.skipped) }
            }
            .pickerStyle(.segmented)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.tab == .browse {
                Menu {
                    Picker("View", selection: $model.chart) {
                        ForEach(StorageModel.Chart.allCases) { c in
                            Label {
                                Text(c.title)
                                Text(c.detail)
                            } icon: {
                                Image(systemName: c.symbol)
                            }
                            .tag(c)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(model.chart.title, systemImage: model.chart.symbol)
                        .labelStyle(.titleAndIcon)
                }
                .help("How to draw the disk map")
                Toggle(isOn: $model.colorByKind) {
                    Label("Color by Kind", systemImage: "paintpalette")
                }
                .help("Color by file kind instead of by folder")
            }
            if model.scanning {
                Button(action: model.cancelScan) { Label("Stop Scan", systemImage: "stop.fill") }
                    .help("Stop scanning")
            } else {
                Button(action: model.rescan) { Label("Rescan", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Scan again (⌘R)")
            }
            Button(action: model.chooseFolder) { Label("Choose Folder", systemImage: "folder.badge.plus") }
                .keyboardShortcut("o", modifiers: .command)
                .help("Map another folder or disk (⌘O)")
        }
    }

    /// The chart takes what the list leaves. The list is an inspector-like
    /// column of a fixed share of the width, so neither ever runs past the
    /// window, whatever its size.
    private var browse: some View {
        GeometryReader { g in
            let side = min(max(DS.Size.inspectorWidth, g.size.width * 0.44), 500)
            HStack(spacing: 0) {
                chart
                    .frame(width: max(0, g.size.width - side - 1))
                Divider()
                InspectorList(model: model)
                    .frame(width: side)
            }
        }
    }

    private var chart: some View {
        ZStack {
            if model.root == nil {
                CenterCard(symbol: nil, title: "Scanning…", subtitle: "\(model.liveFiles.formatted()) files so far") {}
            } else {
                switch model.chart {
                case .rings: SunburstChart(model: model)
                case .wheel: SliceChart(model: model, style: .wheel)
                case .pie: SliceChart(model: model, style: .pie)
                case .boxes: TreemapChart(model: model)
                case .columns: ColumnsChart(model: model)
                case .bars: BarsChart(model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            if model.colorByKind { KindLegend().padding(Theme.pad) }
        }
        .contextMenu { ChartMenu(model: model) }
    }
}

/// Right-click on the chart: acts on the segment under the pointer.
struct ChartMenu: View {
    let model: StorageModel

    var body: some View {
        switch model.hovered {
        case .folder(let f)?:
            let path = f.path
            Button("Open") { model.open(f) }
            Button("Select in List") { model.selection = [path] }
            Divider()
            Button(model.isMarked(path) ? "Unmark" : "Mark for Removal") {
                model.toggle(Marked(path: path, name: f.name, size: f.size, isFolder: true))
            }
            Divider()
            FileMenuItems(paths: [path])
        case .files(let f)?:
            if f !== model.current {
                Button("Open \(f.name)") { model.open(f) }
                Divider()
            }
            FileMenuItems(paths: [f.path], canOpen: false)
        case nil:
            if let cur = model.current {
                if cur.parent != nil { Button("Enclosing Folder") { model.back() } }
                FileMenuItems(paths: [cur.path], canOpen: false)
            }
        }
    }
}

/// Finder-style path bar: one line, scrolls sideways when deep, every
/// level clickable, the current folder emphasized.
struct PathBar: View {
    let model: StorageModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button(action: model.back) {
                        Label("Back", systemImage: "chevron.backward")
                            .labelStyle(.titleAndIcon)
                            .fixedSize()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.current?.parent == nil)
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .help(model.current?.parent.map { "Back to \($0.name) (⌘↑)" } ?? "You're at the top")
                    .padding(.trailing, DS.Space.sm)
                    let lineage = model.lineage
                    ForEach(Array(lineage.enumerated()), id: \.offset) { i, f in
                        if i > 0 {
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        let last = i == lineage.count - 1
                        Button {
                            model.open(f)
                        } label: {
                            Label(i == 0 ? displayRoot(f) : f.name, systemImage: i == 0 ? "internaldrive" : "folder")
                                .lineLimit(1)
                                .fixedSize()
                                .font(.callout.weight(last ? .semibold : .regular))
                                .foregroundStyle(last ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(last)
                        .id(i)
                    }
                }
                .padding(.horizontal, DS.Space.page)
            }
            .frame(height: 40)
            .onChange(of: model.lineage.count) { _, n in proxy.scrollTo(n - 1, anchor: .trailing) }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func displayRoot(_ f: Folder) -> String {
        f.path == Home.path ? "Home" : f.path
    }
}

struct KindLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(FileKind.allCases, id: \.self) { k in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(ChartColors.kind(k)).frame(width: 10, height: 10)
                    Text(k.title).font(.caption)
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
    }
}

/// Folders the scan couldn't open, so a gap in the numbers is never silent.
struct SkippedView: View {
    let model: StorageModel

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(model.denied.count) folders couldn't be read").font(.headline)
                Text("Their contents aren't counted above. Most are protected by macOS; Full Disk Access lets MyMole see inside the ones that belong to you.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Full Disk Access Settings") { FullDiskAccess.openSettings() }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, 6)
            .listRowSeparator(.hidden)
            ForEach(model.denied, id: \.self) { p in
                Label {
                    DSPath(p, .body)
                } icon: {
                    Image(systemName: "lock.fill")
                }
                    .contextMenu { FileMenuItems(paths: [p], canOpen: false) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

/// What's marked, and the way to remove it.
struct BasketBar: View {
    @Bindable var model: StorageModel

    var body: some View {
        DSActionBar {
            DSIcon(symbol: "checklist")
            DSText("\(model.marked.count) marked · \(ByteCountFormatter.string(fromByteCount: model.markedBytes, countStyle: .file))", .body)
        } trailing: {
            Button("Clear") { model.marked.removeAll() }
                .controlSize(.large)
            Button("Review & Move to Trash…") { model.showReview = true }
                .primaryAction()
        }
    }
}

/// The last chance to look before anything moves. Flags protected paths
/// (skipped) and risky ones (your files, backups), and notes rebuildable ones.
struct ReviewSheet: View {
    @Bindable var model: StorageModel
    @Environment(\.dismiss) private var dismiss

    private var items: [Marked] { model.marked.values.sorted { $0.size > $1.size } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("Move \(items.count) item\(items.count == 1 ? "" : "s") to the Trash?").font(.title2.bold())
            Text("\(ByteCountFormatter.string(fromByteCount: model.markedBytes, countStyle: .file)). Everything goes to the Trash, so you can undo right after or put things back from the Trash later.")
                .foregroundStyle(.secondary)
            List(items, id: \.path) { m in
                HStack(spacing: 8) {
                    Image(systemName: m.isFolder ? "folder.fill" : "doc.fill").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        DSName(m.name)
                        DSPath(m.path)
                        warning(m)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: m.size, countStyle: .file)).monospacedDigit()
                    Button {
                        model.marked[m.path] = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from the list")
                }
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") {
                    dismiss()
                    model.trashMarked()
                }
                .primaryAction()
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canTrash)
                .help(model.scanning ? "Available when the scan finishes" : "")
            }
        }
        .padding(Theme.pad)
        .frame(width: 620, height: 480)
        .tint(Theme.accent)  // sheets don't inherit the window's tint
    }

    @ViewBuilder private func warning(_ m: Marked) -> some View {
        if Trasher.isProtected(m.path) {
            Label("Protected location — will be skipped", systemImage: "hand.raised.fill")
                .font(.caption).foregroundStyle(.red)
        } else if let risk = PathRisk.of(m.path)
            ?? (m.isFolder ? model.root?.find(path: m.path).flatMap { PathRisk.inside($0) } : nil)
        {
            Label(risk.reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(risk.level == .caution ? .red : .orange)
        } else if let r = model.root?.find(path: m.path)?.rebuildable {
            Label("\(r.label) — \(r.reason)", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.green)
        }
    }
}

/// Result of the last move, with Undo while it's still possible.
struct NoticeToast: View {
    let model: StorageModel

    var body: some View {
        if let n = model.notice {
            HStack(spacing: 12) {
                Image(systemName: "trash").foregroundStyle(.secondary)
                Text(n.text)
                if n.canUndo {
                    Button("Undo") { model.undoTrash() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button {
                    model.dismissNotice()
                } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: .capsule)
            .shadow(radius: 8, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
