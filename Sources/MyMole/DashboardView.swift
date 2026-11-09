import StorageKit
import SwiftUI
import SystemKit

/// The start page: how full the disk is, how the Mac is doing and what the
/// scans found. Every card that shows something a pane has more of opens
/// that pane; the tools themselves are in the sidebar.
struct DashboardView: View {
    @AppStorage(DuplicatesShow.key) private var duplicateShow: DuplicatesShow = .identical
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette
    let app: AppModel

    /// A reading every few seconds keeps the tiles live; it costs a few
    /// milliseconds, so the dashboard never shows up as load itself.
    static let interval: Duration = .seconds(5)
    static let ring: CGFloat = 170
    /// The disk card: the ring and the room around it, as wide as it is tall.
    @MainActor static var diskWidth: CGFloat { ring + 2 * (DS.Space.md + DS.Space.sm) }
    /// The narrowest a metric tile gets: four fit a row in the smallest
    /// window, each with room for "99,99 GB" at the tiles' tighter padding.
    static let statMinimum: CGFloat = 160
    /// Beside the disk the tiles start with a little more room.
    static let statBesideDisk: CGFloat = 172
    static let listMinimum: CGFloat = 320
    /// Rows a list card shows before "Show All".
    static let listRows = 4

    private var greeting: LocalizedStringResource {
        let h = Calendar.current.component(.hour, from: .now)
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    /// The width at which the four metric tiles fit on one row beside the disk.
    @MainActor static var wideWidth: CGFloat { diskWidth + 4 * (statBesideDisk + Theme.gap) }

    var body: some View {
        DSPage(width: .full) {
            if !app.canScan { accessNotice }
            // Wide: the tiles and Smart Scan beside the disk, all one height.
            // Narrower: Smart Scan beside the disk, the tiles on a row of their own.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.gap) {
                    disk
                    VStack(spacing: Theme.gap) {
                        stats
                        smartScan
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: Self.wideWidth, idealWidth: Self.wideWidth, maxWidth: .infinity)

                VStack(spacing: Theme.gap) {
                    HStack(alignment: .top, spacing: Theme.gap) {
                        disk
                        smartScan
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    stats
                }
            }

            DSTiles(minimum: Self.listMinimum, spacing: Theme.gap) {
                recent
                finds
            }
        }
        .paneToolbar(greeting, subtitle: "Here's how your Mac is doing")
        .task {
            await app.refreshHistory()
            while !Task.isCancelled {
                await app.refreshStatus()
                try? await Task.sleep(for: AppModel.paced(Self.interval))
            }
        }
    }

    // MARK: Top

    private var accessNotice: some View {
        DSNotice(
            .warning,
            Edition.current.isSandboxed
                ? "MyMole needs access to your home folder before it can scan. What's shown is from earlier scans."
                : "MyMole needs Full Disk Access before it can scan. What's shown is from earlier scans."
        ) {
            Button("Set Up…") { app.pane = .clean }
        }
    }

    private var disk: some View {
        let volume = app.status?.startupVolume
        let fraction = (volume?.usedPercent ?? 0) / 100
        return Button {
            app.pane = .diskMap
        } label: {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 14)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Theme.load(fraction * 100), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.8), value: fraction)
                VStack(spacing: 2) {
                    Metric(volume.map { "\(Int($0.usedPercent))%" } ?? "—")
                        .accessibilityLabel(volume.map { String(localized: "\(Int($0.usedPercent)) percent of the disk used") } ?? String(localized: "Disk use not read yet"))
                    Text("disk used").font(.caption).foregroundStyle(.secondary)
                    if let volume {
                        Text("\(ByteSize.format(volume.used)) of \(ByteSize.format(volume.total))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: Self.ring, height: Self.ring)
            .padding(DS.Space.md)
            .frame(maxHeight: .infinity)
            .card(padding: DS.Space.sm)
        }
        .buttonStyle(DSTileButtonStyle())
        .help("Open \(Pane.diskMap.title)")
        .frame(width: Self.diskWidth)
    }

    private var stats: some View {
        DSTiles(minimum: Self.statMinimum, spacing: Theme.gap) {
            stat("Health", opens: .status) {
                Metric(app.status?.health.scoreText ?? "—")
                DSText(app.status?.health.summary ?? " ", .metadata)
            }
            stat("CPU", opens: .status) {
                let cpu = app.status?.cpu
                Metric(cpu.map { "\(Int($0.usage.rounded()))%" } ?? "—")
                UsageBar(fraction: (cpu?.usage ?? 0) / 100)
            }
            stat("Memory", opens: .status) {
                let memory = app.status?.memory
                Metric(memory.map { "\(Int($0.usedPercent))%" } ?? "—")
                UsageBar(fraction: (memory?.usedPercent ?? 0) / 100)
            }
            stat("Last cleanup", opens: .history) {
                if let last = app.lastCleanup {
                    Metric(ByteSize.format(last.freedBytes))
                    // Moved, not yet free: the Trash holds it until it's emptied.
                    Text(last.source == TrashModel.source || last.deleted > 0
                        ? last.date.formatted(.relative(presentation: .named))
                        : String(localized: "\(last.date.formatted(.relative(presentation: .named))) · in the Trash until it's emptied"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Metric(String(localized: "Never"))
                    Text("Nothing cleaned yet").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stat(_ caption: LocalizedStringResource, opens pane: Pane, @ViewBuilder content: () -> some View) -> some View {
        Button {
            app.pane = pane
        } label: {
            StatTile(caption: caption, linked: true, padding: DS.Space.md, content: content)
        }
        .buttonStyle(DSTileButtonStyle())
        .help("Open \(pane.title)")
    }

    private var smartScan: some View {
        HStack(spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Smart Scan").font(.headline)
                Text(app.smartScanScope)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Each module's own state, and the way to its pane.
                DSFlow(spacing: DS.Space.xs) {
                    ForEach(app.smartScanModules) { pane in
                        let state = app.moduleState(pane)
                        Button {
                            if pane == .duplicates { duplicateShow = .identical }
                            app.pane = pane
                        } label: {
                            DSCapsule(
                                "\(pane.title): \(state.text)",
                                symbol: state == .partial || state == .failed || state == .earlier ? "exclamationmark.triangle.fill" : nil,
                                tint: state == .running ? palette.accentText.color
                                    : state == .partial || state == .earlier ? palette.warning : state == .failed ? palette.critical : .secondary,
                                live: state == .running)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(pane.title)")
                    }
                }
                .padding(.top, DS.Space.xxs)
            }
            Spacer(minLength: 0)
            Button {
                if app.smartScanning { app.stopSmartScan() }
                else { app.scanAll() }
            } label: {
                Label(app.smartScanning ? String(localized: "Stop Scan") : String(localized: "Scan"), systemImage: app.smartScanning ? "stop.fill" : "sparkles")
            }
            .primaryAction()
        }
        .frame(maxHeight: .infinity)
        .card()
    }

    // MARK: Lists

    private var recent: some View {
        // The runs that removed something, as the Last cleanup tile counts them.
        let runs = app.cleanups.filter { $0.freedSomething && $0.freedBytes > 0 }.prefix(Self.listRows)
        return DSSection("Recent cleanups") {
            if runs.isEmpty { DSText("Cleanups you run show up here.", .lead) }
            ForEach(Array(runs)) { run in
                link(help: "Open \(Pane.history.title)") {
                    app.pane = .history
                } label: {
                    listRow(
                        symbol: HistoryView.symbol(run.source), name: run.source,
                        detail: run.date.formatted(.relative(presentation: .named)), bytes: run.freedBytes)
                }
            }
        }
        .filling()
    }

    /// Where a find comes from and how old that scan is, apart from the
    /// Mac's own readings above, which are live.
    private func findDetail(_ find: Find) -> String {
        guard let at = app.scannedAt(of: find.pane) else { return find.pane.title }
        return String(localized: "\(find.pane.title) · scanned \(at.formatted(.relative(presentation: .named)))")
    }

    private var finds: some View {
        let top = app.biggestFinds(limit: Self.listRows)
        return DSSection("Biggest finds") {
            if top.isEmpty {
                DSText(
                    app.anyScanRunning ? "Scanning…"
                        : [Pane.clean, .installer, .projects].allSatisfy({ app.scannedAt(of: $0) == nil })
                            ? "Nothing scanned yet. Smart Scan looks for what could go."
                            : "Nothing to clean in what was scanned.",
                    .lead)
            }
            ForEach(top) { find in
                link(help: "Show in \(find.pane.title)") {
                    app.show(find)
                } label: {
                    listRow(symbol: find.pane.symbol, name: find.name, detail: findDetail(find), bytes: find.bytes)
                }
            }
        }
        .filling()
    }

    /// A list row that goes somewhere, with the arrow the tiles have.
    private func link(help: LocalizedStringKey, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.sm) {
                label()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func listRow(symbol: String, name: String, detail: String, bytes: Int64) -> some View {
        HStack(spacing: DS.Space.md) {
            DSIcon(symbol: symbol, tint: palette.accentText.color)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                DSName(name, .body, lines: 1)
                DSText(detail, .metadata, lines: 1)
            }
            .layoutPriority(1)
            Spacer(minLength: DS.Space.sm)
            DSValue(bytes: bytes)
        }
    }
}

/// One of the biggest things the last scans found that could go.
struct Find: Identifiable, Equatable {
    let pane: Pane
    /// The item's path: what its pane selects it by.
    let path: String
    let name: String
    let bytes: Int64

    var id: String { pane.rawValue + ":" + path }

    /// The `limit` biggest. A path two panes found is listed once, where it's bigger.
    /// The biggest, each place once: a find inside or holding one already
    /// listed, as a cache in a project both panes found, is the same space.
    static func biggest(_ finds: [Find], limit: Int) -> [Find] {
        var listed: [String] = []
        var out: [Find] = []
        for f in finds.filter({ $0.bytes > 0 }).sorted(by: { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }) {
            guard out.count < limit else { break }
            let overlaps = listed.contains { $0 == f.path || f.path.hasPrefix($0 + "/") || $0.hasPrefix(f.path + "/") }
            guard !overlaps else { continue }
            listed.append(f.path)
            out.append(f)
        }
        return out
    }
}

extension AppModel {
    /// The biggest things the last scans of Deep Clean, Installers and
    /// Projects found. Each list gives its own biggest first, so a pane with
    /// thousands of items costs one sort, not a merge of everything.
    func biggestFinds(limit: Int) -> [Find] {
        let cleans = deepClean.candidates.sorted { $0.bytes > $1.bytes }.lazy
            .filter { !self.deepClean.isKept($0.path) }.prefix(limit)
            .map { Find(pane: .clean, path: $0.path, name: $0.name, bytes: $0.bytes) }
        let files = installers.files.sorted { $0.bytes > $1.bytes }.prefix(limit)
            .map { Find(pane: .installer, path: $0.path, name: $0.name, bytes: $0.bytes) }
        let builds = projects.footprints.sorted { $0.removableBytes > $1.removableBytes }.prefix(limit)
            .map { Find(pane: .projects, path: $0.id, name: $0.project.name, bytes: $0.removableBytes) }
        return Find.biggest(Array(cleans) + files + builds, limit: limit)
    }

    /// Opens a find's pane with it selected. Selecting only highlights the
    /// row: nothing is chosen for removal.
    func show(_ find: Find) {
        switch find.pane {
        case .clean: deepClean.selection = [find.path]
        case .installer: installers.selection = [find.path]
        case .projects: projects.selection = [find.path]
        default: break
        }
        pane = find.pane
    }
}
