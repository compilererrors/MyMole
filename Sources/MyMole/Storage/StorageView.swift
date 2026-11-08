import StorageKit
import SwiftUI

/// The Disk Map pane: chart and list side by side, plus Large Files,
/// Changes since the last scan, and the folders that couldn't be read.
struct StorageView: View {
    @AppStorage("diskMap.listWidth") private var listWidth = 0.0
    @AppStorage("diskMap.chartHidden") private var chartHidden = false
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
        }
        .dsBottom(showing: !model.marked.isEmpty) {
            BasketBar(model: model)
        } toast: {
            NoticeToast(model: model)
        }
        .sheet(isPresented: $model.showReview) { ReviewSheet(model: model) }
        .paneToolbar("Disk Map", subtitle: "\(subtitle)") { tools }
        .onAppear {
            if model.root == nil && !model.scanning {
                model.scan(path: Home.path)
            }
        }
    }

    private var subtitle: String {
        if let opened = model.opened {
            return String(localized: "Saved scan \(opened.file), made \(opened.date.formatted(date: .abbreviated, time: .shortened)) · only to look at")
        }
        if model.scanning {
            return String(localized: "Scanning… \(model.liveFiles.formatted()) files · \(ByteCountFormatter.string(fromByteCount: model.liveBytes, countStyle: .file))")
        }
        guard let r = model.root else { return String(localized: "Where your space went") }
        let size = ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file)
        let files = r.fileCount.formatted()
        return model.lastDuration.map { String(localized: "\(size) in \(files) files in \(Int($0.rounded())) s") }
            ?? String(localized: "\(size) in \(files) files")
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
                Toggle(isOn: $chartHidden) {
                    Label("Hide Chart", systemImage: "sidebar.leading")
                }
                .help(chartHidden ? String(localized: "Show the chart beside the list") : String(localized: "Hide the chart and give the list the whole pane"))
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
                    .help("Scan again (⌘R)")
            }
            PlacesMenu(model: model)
            Button(action: model.chooseFolder) { Label("Choose Folder", systemImage: "folder.badge.plus") }
                .help("Map another folder or disk (⌘O)")
        }
    }

    /// The chart takes what the list leaves. The user drags the divider to
    /// set the list's width, which is kept, or hides the chart for a list as
    /// wide as the pane. Neither ever runs past the window, whatever its size.
    private var browse: some View {
        GeometryReader { g in
            if chartHidden {
                InspectorList(model: model)
            } else {
                let side = Self.listWidth(saved: listWidth, total: g.size.width)
                HStack(spacing: 0) {
                    chart
                        .frame(width: max(0, g.size.width - side - DS.Size.splitHandle))
                    SplitHandle(width: $listWidth, total: g.size.width)
                    InspectorList(model: model)
                        .frame(width: side)
                }
            }
        }
    }

    /// The list's width: as saved, kept between the narrowest readable list
    /// and the narrowest chart; nil (never dragged) is 44 % of the pane.
    static func listWidth(saved: Double, total: CGFloat) -> CGFloat {
        let narrowest = DS.Size.inspectorWidth
        let widest = max(narrowest, total - DS.Size.chartMinWidth - DS.Size.splitHandle)
        let wanted = saved > 0 ? CGFloat(saved) : min(max(narrowest, total * 0.44), 500)
        return min(max(wanted, narrowest), widest)
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
        // The chart is drawn, not built from views: VoiceOver gets its
        // folders here, the same ones the list beside it shows.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            model.current.map { String(localized: "\(model.chart.title) of \($0.name)") }
                ?? String(localized: "\(model.chart.title) of the disk"))
        .accessibilityChildren {
            ForEach((model.current?.subfolders ?? []).sorted { $0.size > $1.size }.prefix(30), id: \.path) { f in
                Text(f.name)
                    .accessibilityValue(Self.share(f, of: model.current))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.open(f) }
            }
        }
    }
}

extension StorageView {
    /// "1,2 GB, 14 % of Library", for VoiceOver.
    static func share(_ f: Folder, of parent: Folder?) -> String {
        let size = ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)
        guard let parent, parent.size > 0 else { return size }
        return String(localized: "\(size), \(Int((Double(f.size) / Double(parent.size) * 100).rounded())) % of \(parent.name)")
    }
}

/// The divider between chart and list: dragged to set the list's width,
/// with the resize pointer, and no animation while it moves.
private struct SplitHandle: View {
    @Binding var width: Double
    let total: CGFloat
    @State private var start: CGFloat?

    var body: some View {
        Divider()
            .frame(width: DS.Size.splitHandle)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        let from = start ?? StorageView.listWidth(saved: width, total: total)
                        start = from
                        width = Double(StorageView.listWidth(saved: Double(from - g.translation.width), total: total))
                    }
                    .onEnded { _ in start = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("List width")
            .accessibilityAdjustableAction { direction in
                let now = StorageView.listWidth(saved: width, total: total)
                width = Double(StorageView.listWidth(saved: Double(now + (direction == .increment ? 40 : -40)), total: total))
            }
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
            Button(model.isMarked(path) ? String(localized: "Unchoose") : String(localized: "Choose for Removal")) {
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
                    .help(model.current?.parent.map { String(localized: "Back to \($0.name) (⌘↑)") } ?? String(localized: "You're at the top"))
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
        .overlay(alignment: .trailing) {
            if let space = model.diskSpace, let root = model.root, !model.scanning {
                OutsideTheMap(space: space, mapped: root.size)
                    .padding(.trailing, DS.Space.page)
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func displayRoot(_ f: Folder) -> String {
        f.path == Home.path ? String(localized: "Home") : f.path
    }
}

/// What's used on the disk but isn't in the map, and why: the system, apps
/// and other users outside the mapped folder, and space macOS frees by itself.
struct OutsideTheMap: View {
    let space: DiskSpace
    let mapped: Int64
    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            Label("\(ByteSize.format(space.outside(mapped: mapped))) not in the map", systemImage: "questionmark.circle")
                .labelStyle(.titleAndIcon)
                .fixedSize()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("What's on the disk but isn't in this map")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text("Not in the Map").font(.headline)
                row(String(localized: "Used on the disk"), space.used)
                row(String(localized: "In this map"), mapped)
                row(String(localized: "Not in the map"), space.outside(mapped: mapped))
                DSText("macOS itself, apps and other users' folders outside the mapped folder, and folders MyMole couldn't read.", .metadata)
                Divider()
                row(String(localized: "Purgeable"), space.purgeable)
                DSText(purgeableText, .metadata)
            }
            .padding(DS.Space.lg)
            .frame(width: 340)
        }
    }

    private var purgeableText: String {
        let count = space.snapshots?.count ?? 0
        let snapshots = count == 0 ? "" : String(localized: " \(count) local Time Machine snapshot\(count == 1 ? " is" : "s are") on this disk.")
        return String(localized: "Counted as free, as Finder does: macOS frees it by itself when space is needed, mostly caches it manages and local Time Machine snapshots.") + snapshots
    }

    private func row(_ title: String, _ bytes: Int64) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(ByteSize.format(bytes)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
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
        if model.denied.isEmpty {
            ContentUnavailableView(
                model.scanning ? String(localized: "Scan Still Running") : String(localized: "No Unreadable Folders"),
                systemImage: model.scanning ? "hourglass" : "checkmark.circle",
                description: Text(
                    model.scanning
                        ? "Folders the scan can't read appear here. The result is complete when scanning finishes."
                        : "This scan reported no folders it couldn't read."))
        } else {
            List {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(model.denied.count) folder\(model.denied.count == 1 ? "" : "s") couldn't be read").font(.headline)
                    Text(
                        "Their contents aren't counted above. Most are protected by macOS; Full Disk Access lets MyMole see inside the ones that belong to you."
                    )
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
}

/// What's marked, and the way to remove it.
struct BasketBar: View {
    @Bindable var model: StorageModel

    var body: some View {
        DSActionBar {
            DSIcon(symbol: "checklist")
            DSText("\(model.marked.count) chosen · \(ByteCountFormatter.string(fromByteCount: model.markedBytes, countStyle: .file))", .body)
        } trailing: {
            Button("Clear") { model.marked.removeAll() }
                .accessibilityLabel("Clear the choice")
                .controlSize(.large)
            Button("Review & Move to Trash…") { model.showReview = true }
                .primaryAction()
        }
    }
}

/// The last chance to look before anything moves. Flags protected paths
/// (skipped) and risky ones (your files, backups), and notes rebuildable ones.
/// What's chosen is looked at off the main thread while the sheet is open,
/// once per item: whether a keep list of another pane protects it (it then
/// stays), and what a folder holds, so a big one never stalls the window.
/// The move waits until everything has been looked at.
struct ReviewSheet: View {
    @Environment(\.palette) private var palette
    @Bindable var model: StorageModel
    @Environment(\.dismiss) private var dismiss
    /// What looking at each chosen item found.
    @State private var checks: [String: Check] = [:]
    /// The keep lists couldn't be read: nothing is moved until they can be.
    @State private var keepsUnreadable = false

    /// Whether a keep list protects the item, and for a folder the gravest
    /// thing it holds.
    struct Check: Equatable {
        var kept = false
        var inside: PathRisk?
        /// Programs that have the file open now.
        var openIn: [String] = []
        /// Other names the file has (hard links): its space stays until every one goes.
        var otherNames = 0
    }

    private var items: [Marked] { model.marked.values.sorted { $0.size > $1.size } }
    /// Files looked at for a program holding them open: the biggest, from this size.
    static let openCheckMinimum: Int64 = 100_000_000
    static let openCheckLimit = 20
    /// Chosen items not looked at yet, largest first.
    private var unchecked: [String] { items.map(\.path).filter { checks[$0] == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("Move \(items.count) item\(items.count == 1 ? "" : "s") to the Trash?").font(.title2.bold())
            Text(
                "\(ByteCountFormatter.string(fromByteCount: model.markedBytes, countStyle: .file)). Everything goes to the Trash, so you can undo right after or put things back from the Trash later."
            )
            .foregroundStyle(.secondary)
            if keepsUnreadable {
                DSNotice(
                    .critical,
                    "Your keep lists couldn't be read, so nothing is moved until they can be. Look at Deep Clean's list in Settings and your rules in Projects."
                )
            }
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
                    .accessibilityLabel("Unchoose \(m.name)")
                }
            }
            .frame(minHeight: 240)
            DSActionGroup {
                EmptyView()
            } trailing: {
                Button("Cancel") { dismiss() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") {
                    dismiss()
                    model.trashMarked()
                }
                .primaryAction()
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canTrash || !unchecked.isEmpty || keepsUnreadable)
                .help(
                    model.scanning
                        ? String(localized: "Available when the scan finishes")
                        : keepsUnreadable
                            ? String(localized: "Your keep lists couldn't be read")
                            : unchecked.isEmpty ? "" : String(localized: "Available once what's chosen has been looked through"))
            }
        }
        .padding(Theme.pad)
        .frame(width: DS.Size.reviewWidth)
        .frame(minHeight: 480, idealHeight: 540)
        .tint(palette.accent.color)  // sheets don't inherit the window's tint
        // Again only when the list changes, not as each result comes in.
        .task(id: items.map(\.path)) { await check() }
    }

    /// Looks at what's chosen, off the main thread: the keep lists first,
    /// read once, then inside each folder nothing keeps, one at a time.
    /// Stops at the next folder when the sheet goes or the list changes;
    /// what was found stays, so nothing is looked through twice.
    private func check() async {
        let pending = unchecked
        guard !pending.isEmpty else { return }
        let progress = ScanProgress()
        let protections = model.protections
        await withTaskCancellationHandler {
            let kept = await Task.detached(priority: .userInitiated) { () -> Set<String>? in
                guard let keeps = try? protections.read() else { return nil }
                return Set(pending.filter(keeps))
            }.value
            guard !Task.isCancelled else { return }
            keepsUnreadable = kept == nil
            // What's kept stays whatever it holds, and a path that warns by
            // itself needs no look inside: both are settled at once.
            var walks: [(path: String, folder: Folder)] = []
            var settled: [String: Check] = [:]
            // Big files a program has open, such as a virtual disk; a look
            // takes a moment each, so only the biggest few. The App Sandbox
            // can't see other programs.
            let files = Edition.current.isSandboxed ? [] : Array(pending
                .compactMap { model.marked[$0] }.filter { !$0.isFolder && $0.size >= Self.openCheckMinimum }
                .sorted { $0.size > $1.size }.prefix(Self.openCheckLimit).map(\.path))
            let open = await Task.detached(priority: .userInitiated) {
                Dictionary(uniqueKeysWithValues: files.compactMap { p in OpenFiles.users(of: p).flatMap { $0.isEmpty ? nil : (p, $0) } })
            }.value
            let plainFiles = pending.filter { model.marked[$0]?.isFolder == false }
            let links = await Task.detached(priority: .userInitiated) { HardLinks.otherNames(of: plainFiles) }.value
            for path in pending {
                let isKept = kept?.contains(path) ?? false
                if !isKept, model.marked[path]?.isFolder == true, PathRisk.of(path) == nil, let folder = model.root?.find(path: path) {
                    walks.append((path, folder))
                } else {
                    settled[path] = Check(kept: isKept, openIn: open[path] ?? [], otherNames: links[path] ?? 0)
                }
            }
            checks.merge(settled) { _, new in new }
            for (path, folder) in walks {
                guard !Task.isCancelled else { return }
                let found = await Task.detached(priority: .userInitiated) {
                    PathRisk.inside(folder, stop: { progress.isCancelled })
                }.value
                guard !Task.isCancelled else { return }
                checks[path] = Check(inside: found)
            }
        } onCancel: {
            progress.cancel()
        }
    }

    @ViewBuilder private func warning(_ m: Marked) -> some View {
        if Trasher.isProtected(m.path) {
            Label("Protected location — will be skipped", systemImage: "hand.raised.fill")
                .font(.caption).foregroundStyle(.red)
        } else if checks[m.path]?.kept == true {
            Label("On one of your keep lists, or holds something that is — will be skipped", systemImage: "lock.shield.fill")
                .font(.caption).foregroundStyle(.orange)
        } else if let open = checks[m.path]?.openIn, !open.isEmpty {
            Label("Open in \(open.joined(separator: ", ")) — quit it first, or it goes on writing to the file in the Trash", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        } else if let risk = PathRisk.of(m.path) {
            riskLabel(risk)
        } else if let n = checks[m.path]?.otherNames, n > 0 {
            Label("Has \(n) other name\(n == 1 ? "" : "s") (hard link\(n == 1 ? "" : "s")) — its space stays in use until every name goes", systemImage: "link")
                .font(.caption).foregroundStyle(.secondary)
        } else if m.isFolder, checks[m.path] == nil {
            HStack(spacing: DS.Space.xs) {
                PulseDot(size: 6)
                DSText("Looking through what it holds…", .metadata)
            }
        } else if let risk = checks[m.path]?.inside {
            riskLabel(risk)
        } else if let r = model.root?.find(path: m.path)?.rebuildable {
            Label("\(r.label) — \(r.reason)", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.green)
        }
    }

    private func riskLabel(_ risk: PathRisk) -> some View {
        Label(risk.reason, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(risk.level == .caution ? .red : .orange)
    }
}

/// Result of the last move, with Undo while it's still possible.
struct NoticeToast: View {
    let model: StorageModel

    var body: some View {
        if let n = model.notice {
            DSUndoToast(text: n.text, canUndo: n.canUndo, undo: { model.undoTrash() }, dismiss: { model.dismissNotice() })
        }
    }
}

/// Common folders and the disks mounted now, to map with one choice.
private struct PlacesMenu: View {
    let model: StorageModel
    @State private var places = PlacesModel()

    private var folders: [(String, String)] {
        let home = Home.path
        return [
            (String(localized: "Home"), home), (String(localized: "Desktop"), home + "/Desktop"),
            (String(localized: "Documents"), home + "/Documents"), (String(localized: "Downloads"), home + "/Downloads"),
            (String(localized: "Applications"), "/Applications"),
        ]
    }

    var body: some View {
        Menu {
            Section("Folders") {
                ForEach(folders, id: \.1) { name, path in
                    Button(name) { model.map(place: path) }
                }
            }
            Section("Disks") {
                if places.volumes.isEmpty, places.job != nil { Text("Reading disks…") }
                ForEach(places.volumes) { v in
                    Button(v.available.map { String(localized: "\(v.name) · \(ByteSize.format($0)) free") } ?? v.name) {
                        model.map(place: v.path)
                    }
                }
            }
        } label: {
            Label("Places", systemImage: "externaldrive")
        }
        .help("Map a common folder or a disk")
        .onAppear { places.refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in places.refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in places.refresh() }
    }
}
