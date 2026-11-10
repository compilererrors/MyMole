import AppKit
import ServiceManagement
import StorageKit
import SwiftUI

/// Settings stays in the main window, using the shared page width and section cards.
struct SettingsView: View {
    @Bindable var app: AppModel
    @AppStorage(PerformanceLevel.defaultsKey) private var performance = PerformanceLevel.standard.rawValue
    @AppStorage(Density.key) private var density = Density.standard.rawValue
    @AppStorage(AppearanceMode.key) private var mode = AppearanceMode.system.rawValue
    @AppStorage(ThemeFamily.key) private var theme = ThemeFamily.standard.rawValue
    @AppStorage(TableLines.key) private var lines = TableLines.standard.rawValue
    @AppStorage(MenuBarSettings.showKey) private var menuBar = MenuBarSettings.showStandard
    @AppStorage(MenuBarSettings.freeKey) private var menuBarFree = false
    @AppStorage(WatchSettings.scanKey) private var backgroundScan = WatchSettings.Cadence.standard.rawValue
    @AppStorage(WatchSettings.diskKey) private var notifyDisk = false
    @AppStorage(WatchSettings.findsKey) private var notifyFinds = false
    @AppStorage(WatchSettings.trashedAppsKey) private var notifyTrashedApps = false
    @AppStorage(WatchSettings.busyKey) private var notifyBusy = false
    @State private var notificationsRefused = false
    @State private var loginItem = LoginItem.state
    @State private var loginItemProblem: String?
    @AppStorage(LoadingSettings.prefetchKey) private var prefetch = true
    @AppStorage(LoadingSettings.historyKey) private var history = LoadingSettings.historyStandard
    @State private var savedBytes: Int64?
    @State private var confirmingClear = false
    @State private var showingSelfRemoval = false

    private var level: PerformanceLevel { PerformanceLevel(saved: performance) }

    private var diskAccessText: String {
        if !app.access.has(.home) {
            return String(localized: "Choose your home folder in Folder Access before MyMole can check Full Disk Access.")
        }
        if !app.diskAccess.hasResult { return String(localized: "Checking Full Disk Access…") }
        return switch app.diskAccessState {
        case .granted: String(localized: "MyMole has Full Disk Access.")
        case .denied: String(localized: "MyMole doesn't have Full Disk Access, so the folders macOS protects stay closed to it.")
        case .unknown: String(localized: "MyMole couldn't tell whether it has Full Disk Access: none of the folders it checks are on this Mac. It goes on as if it has; a folder it can't read is said where it shows up.")
        }
    }

    private var matches: [SettingsSection] {
        SettingsSection.matching(app.settingsQuery, sandboxed: Edition.current.isSandboxed, systemTasks: Edition.current.hasSystemTasks)
    }

    var body: some View {
        VStack(spacing: 0) {
            DSPaneHeader {
                DSMetric(
                    matches.count.formatted(),
                    app.settingsQuery.isEmpty ? String(localized: "settings sections") : String(localized: "matching sections"))
            } actions: {
                DSControlField("Search settings") {
                    DSFilterField(String(localized: "Search by name or purpose"), text: $app.settingsQuery)
                        .frame(minWidth: 180, idealWidth: 280, maxWidth: .infinity)
                        .accessibilityIdentifier("settings.search")
                }
            } strip: {
                DSCapsule("Changes apply as you make them", symbol: "checkmark")
                if !app.settingsQuery.isEmpty {
                    DSStripButton("Show All", symbol: "xmark") { app.settingsQuery = "" }
                }
            }
            Divider()
            if matches.isEmpty {
                ContentUnavailableView.search(text: app.settingsQuery)
            } else {
                DSPage {
                    ForEach(matches) { section in
                        settingsSection(section)
                            .accessibilityIdentifier("settings.section." + section.rawValue)
                    }
                }
            }
        }
        .paneToolbar("Settings", subtitle: "Appearance, behavior and safety")
    }

    @ViewBuilder private func settingsSection(_ section: SettingsSection) -> some View {
        switch section {
        case .appearance: appearance
        case .menuBar: menuBarSection
        case .background: backgroundSection
        case .performance: performanceSection
        case .loading: loadingSection
        case .diskMap: DiskMapSkipsSection()
        case .confirmations: ConfirmationsSection()
        case .diskAccess: diskAccessSection
        case .appManagement: appManagementSection
        case .timings: TimingsSection()
        case .folderAccess: folderAccessSection
        case .systemTasks: systemTasksSection
        case .keep: keepSection
        case .systemKeep: systemKeepSection
        case .about: aboutSection
        case .uninstall: selfUninstallSection
        }
    }

    private var selfUninstallSection: some View {
        DSSection("Uninstall MyMole", footer: "Remove this copy whenever you want. Review its caches and settings, turn off Open at Login and move the app to the Trash. Nothing is deleted permanently.") {
            DSActionGroup {
                DSText(app.selfRemoval.available ? String(localized: "MyMole can uninstall itself, including the data you choose.")
                       : String(localized: "Self-uninstall is available when running the installed MyMole app."), .metadata)
            } trailing: {
                Button("Uninstall MyMole…", role: .destructive) { showingSelfRemoval = true }
                    .fixedSize()
                    .disabled(!app.selfRemoval.available)
            }
        }
        .sheet(isPresented: $showingSelfRemoval, onDismiss: { loginItem = LoginItem.state }) {
            SelfRemovalSheet(model: app.selfRemoval)
        }
    }

    private var appearance: some View {
        DSSection("Appearance", footer: "Themes change the surfaces and the accent; text and warning colours stay the system's. Spacious gives margins, rows and the gaps between columns more room. Compact fits the most on screen. Table lines separate the rows of every list, or its rows and columns; without them, file lists are striped.") {
            Picker("Appearance", selection: $mode) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Picker("Theme", selection: $theme) {
                ForEach(ThemeFamily.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .fixedSize()
            ThemePreview()
            Picker("Layout", selection: Binding(
                get: { Density(rawValue: density) ?? .standard },
                set: { d in
                    // Update observed metrics without recreating open panes.
                    Density.current = d
                    density = d.rawValue
                })
            ) {
                ForEach(Density.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Picker("Table lines", selection: $lines) {
                ForEach(TableLines.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private var menuBarSection: some View {
        DSSection("Menu Bar") {
            Toggle(isOn: $menuBar) {
                Text("Show MyMole in the menu bar")
                Text("The disk, memory and what the scans found at a glance. MyMole keeps running there when its window is closed; Quit ends it.")
            }
            Toggle("Show free space beside the icon", isOn: $menuBarFree)
                .disabled(!menuBar)
            Toggle(isOn: Binding(
                get: { loginItem == .on },
                set: { on in
                    loginItemProblem = LoginItem.set(on)
                    loginItem = LoginItem.state
                })
            ) {
                Text("Open MyMole at login")
                Text(menuBar
                    ? "It starts in the menu bar, without a window, and scans when the Mac has time to spare."
                    : "Its window opens at login. With the menu bar item on, it starts there instead.")
            }
            .disabled(loginItem == .unavailable)
            if loginItem == .needsApproval {
                DSActionGroup {
                    Text("macOS is waiting for you to allow MyMole in System Settings → General → Login Items.")
                        .foregroundStyle(.secondary)
                } trailing: {
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let loginItemProblem { Text(loginItemProblem).foregroundStyle(.red) }
        }
        .liveRefresh(every: .seconds(5), events: []) {
            let current = LoginItem.state
            if loginItem != current { loginItem = current }
        }
    }

    private var backgroundSection: some View {
        DSSection("In the Background") {
            Picker(selection: $backgroundScan) {
                ForEach(WatchSettings.Cadence.allCases) { Text($0.title).tag($0.rawValue) }
            } label: {
                Text("Scan in the background")
                Text("While MyMole runs, also in the menu bar, when the Mac has time to spare. Scans only read; nothing is removed until you choose it.")
            }
            .onChange(of: backgroundScan) { app.watch.schedule { await app.backgroundScan() } }
            Toggle("Notify me when the disk is nearly full", isOn: notifying($notifyDisk))
            Toggle(isOn: notifying($notifyFinds)) {
                Text("Notify me when a scan finds a lot to clean")
                Text("At least \(ByteSize.format(Alerts.findsMinimum)) in one pane, at most once a week.")
            }
            Toggle(isOn: notifying($notifyTrashedApps)) {
                Text("Notify me when an app in the Trash left things behind")
                Text("An app dragged to the Trash leaves its settings, caches and data in your Library. Nothing is removed until you choose it.")
            }
            // The App Sandbox keeps other apps' processes from MyMole.
            if !Edition.current.isSandboxed {
                Toggle(isOn: notifying($notifyBusy)) {
                    Text("Notify me when an app keeps the processor busy")
                    Text("A whole core for \(Int(BusyProcesses.lasting / 60)) minutes, at most once a day for each app.")
                }
            }
            if notificationsRefused {
                Text("Notifications are turned off for MyMole in System Settings → Notifications.")
                    .foregroundStyle(.red)
            }
        }
        .liveRefresh(every: .seconds(5), events: []) {
            let denied = await Notifier.notificationsDenied()
            guard !Task.isCancelled else { return }
            if denied != notificationsRefused { notificationsRefused = denied }
        }
    }

    private var performanceSection: some View {
        DSSection("Performance", footer: "How hard scans may work. Lower levels use fewer threads at a lower priority, so the Mac stays quiet while scans take longer. A change applies from the next scan.") {
            VStack(alignment: .leading, spacing: 6) {
                Slider(
                    value: Binding(get: { Double(level.rawValue) }, set: { performance = Int($0.rounded()) }),
                    in: 1...Double(PerformanceLevel.allCases.count), step: 1
                ) {
                    Text("Scan speed")
                } minimumValueLabel: {
                    Image(systemName: "tortoise").help("Gentle")
                } maximumValueLabel: {
                    Image(systemName: "hare").help("Full")
                }
                .accessibilityValue("\(level.title), level \(level.rawValue) of \(PerformanceLevel.allCases.count)")
                HStack(spacing: 6) {
                    Text("\(level.title) · level \(level.rawValue) of \(PerformanceLevel.allCases.count)")
                        .fontWeight(.medium)
                    if level == .standard {
                        Text("Default").foregroundStyle(.secondary)
                    } else {
                        Button("Reset") { performance = PerformanceLevel.standard.rawValue }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
                Text(level.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var loadingSection: some View {
        DSSection("Loading and Memory", footer: "Disk Map's saved scans take \(ByteSize.format(SnapshotStore.totalLimit)) at most together; the oldest go first, and the newest of each folder always stays.") {
            Toggle(isOn: $prefetch) {
                Text("Get every pane ready at launch")
                Text("Scans run one after another in the background, at a lower priority, so each pane opens with a fresh result. Off: a pane scans when you open it.")
            }
            Stepper(value: Binding(
                get: { LoadingSettings.history() },
                set: { history = min(max($0, LoadingSettings.historyRange.lowerBound), LoadingSettings.historyRange.upperBound) }),
                in: LoadingSettings.historyRange, step: 5
            ) {
                Text("Disk map history: \(LoadingSettings.history()) scans per folder")
                Text("What Changes compares against. Fewer keep less on disk; older scans go as new ones are saved.")
            }
            DSActionGroup {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved results")
                    Text("Each pane's last scan and the disk map's history, shown at once after a launch: \(savedBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…").")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } trailing: {
                Button("Clear…") { confirmingClear = true }
                    .disabled(savedBytes == 0)
            }
            .actionConfirmation(String(localized: "Clear the saved results?"), isPresented: $confirmingClear,
                                action: .savedResults, button: String(localized: "Clear Saved Results"),
                                message: String(localized: "What's on screen stays until you quit. After the next launch each pane scans afresh. Keep lists, project rules and History aren't touched.")) {
                Task {
                    await Task.detached(priority: .userInitiated) { SavedResults.clear() }.value
                    await measureSaved()
                }
            }
            SavedResultsList(changed: { await measureSaved() })
        }
        .task { await measureSaved() }
    }

    private var diskAccessSection: some View {
        DSSection("Full Disk Access") {
            DSActionGroup {
                Text(diskAccessText)
                    .foregroundStyle(.secondary)
            } trailing: {
                Button("Open Privacy Settings") { FullDiskAccess.openSettings() }
            }
        }
    }

    private var appManagementSection: some View {
        DSSection("App Management") {
            DSActionGroup {
                Text("macOS can require App Management permission to remove other apps. Full Disk Access is a separate permission. Allow the copy of MyMole you're using in Privacy & Security → App Management; file permissions or administrator approval can also affect a move.")
                    .foregroundStyle(.secondary)
            } trailing: {
                DSFlow(spacing: DS.Space.sm) {
                    AppManagementButton()
                }
            }
        }
    }

    private var folderAccessSection: some View {
        DSSection("Folder Access", footer: "The App Store edition works only in the folders you choose here. Full Disk Access in System Settings also lets it into the folders macOS protects inside them.") {
            ForEach(FolderAccess.Place.allCases) { place in
                DSActionGroup {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.title)
                        Text(place.why).font(.caption).foregroundStyle(.secondary)
                    }
                } trailing: {
                    if app.access.has(place) {
                        Button("Take Back") { Task { await app.takeBack(place) } }
                            .disabled(app.takeBackBlocker != nil)
                            .help(app.takeBackBlocker ?? String(localized: "Stops running scans, then closes the folder to MyMole."))
                    } else {
                        Button("Give Access…") {
                            app.access.request(place)
                            app.recheckDiskAccess()
                        }
                    }
                }
            }
            if let problem = app.access.lastProblem {
                Text(problem).foregroundStyle(.red)
            }
        }
    }

    private var systemTasksSection: some View {
        DSSection("System Tasks") {
            Text("System Clean, Optimize's administrator tasks and system-wide app leftovers run as root. macOS asks for an administrator's password each time one runs; nothing is installed and nothing keeps running.")
                .foregroundStyle(.secondary)
        }
    }

    private var keepSection: some View {
        DSSection("Deep Clean Keep List", footer: "Kept items, and anything inside them, are never offered or moved.") {
            keepProblem(
                read: app.deepClean.keepError, save: app.deepClean.keepSaveError,
                retry: app.deepClean.reloadKeepList, discard: app.deepClean.discardKeepChange)
            if app.deepClean.keep.paths.isEmpty {
                Text("Nothing kept yet. Right-click an item in Deep Clean and choose Always Keep.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.deepClean.keep.paths.sorted(), id: \.self) { path in
                    HStack {
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            .help(path)
                            .contextMenu { FileMenuItems(paths: [path], canOpen: false) }
                        Spacer()
                        Button("Stop Keeping") { app.deepClean.stopKeeping([path]) }
                            .fixedSize()
                            .help("Remove this protection. No files are moved.")
                    }
                }
            }
        }
    }

    private var systemKeepSection: some View {
        DSSection("System Clean Keep List", footer: "Kept system items, and anything inside them, are never chosen or removed.") {
            keepProblem(
                read: app.systemClean.keepError, save: app.systemClean.keepSaveError,
                retry: app.systemClean.reloadKeepList, discard: app.systemClean.discardKeepChange)
            if app.systemClean.keep.paths.isEmpty {
                Text("Nothing kept yet. Right-click an item in System Clean and choose Always Keep.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.systemClean.keep.paths.sorted(), id: \.self) { path in
                    HStack {
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            .help(path)
                            .contextMenu { FileMenuItems(paths: [path], canOpen: false) }
                        Spacer()
                        Button("Stop Keeping") { app.systemClean.stopKeeping([path]) }
                            .fixedSize()
                            .help("Remove this protection. No files are moved.")
                    }
                }
            }
        }
    }

    private var aboutSection: some View {
        DSSection("About") {
            Text("MyMole is source-available. Personal non-commercial use is permitted; business and organizational use requires a paid commercial license.")
                .foregroundStyle(.secondary)
            Text("MyMole is a native Mac cleaner. Everything it removes is chosen by you; your own files go to the Trash, with Undo. In the direct edition, system caches are deleted after macOS asks for an administrator's password.")
                .foregroundStyle(.secondary)
            DSFlow(spacing: DS.Space.md) {
                Link(destination: Links.website) { Text(verbatim: "mymole.viktornyberg.com") }
                Link("Support", destination: Links.support)
            }
            HStack {
                if let url = Bundle.main.url(forResource: "MyMole-LICENSE", withExtension: "txt", subdirectory: "Licenses") {
                    Button("MyMole License") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    /// A notification switch: turning it on asks macOS for permission, and
    /// it stays off when the user says no.
    private func notifying(_ setting: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { setting.wrappedValue },
            set: { on in
                guard on else {
                    setting.wrappedValue = false
                    return
                }
                Task {
                    let allowed = await app.watch.authorize()
                    setting.wrappedValue = allowed
                    notificationsRefused = !allowed
                }
            })
    }

    /// Why a keep list isn't what the user sees, as the pane that uses it
    /// says it: nothing is removed against it until this is resolved.
    @ViewBuilder
    private func keepProblem(read: Problem?, save: Problem?, retry: @escaping () -> Void, discard: @escaping () -> Void) -> some View {
        if let read {
            DSNotice(.critical, "This list couldn't be read (\(read.description)). Nothing is removed against it until it can be.") {
                Button("Try Again", action: retry)
                CopyErrorCodeButton(read.code)
            }
        } else if let save {
            DSNotice(.critical, "Your change couldn't be saved (\(save.description)). Nothing is removed until it's saved or given up.") {
                Button("Try Again", action: retry)
                Button("Discard Change", action: discard)
                CopyErrorCodeButton(save.code)
            }
        }
    }
}

/// A row, a selected row, a status and a button in the theme as chosen, so
/// a theme can be judged before leaving Settings.
private struct ThemePreview: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            row(String(localized: "Caches"), "1,2 GB", selected: false)
            row(String(localized: "Logs"), "240 MB", selected: true)
            HStack(spacing: DS.Space.sm) {
                DSCapsule("Scanned 2 minutes ago", symbol: "clock")
                DSCapsule("1 couldn't be read", symbol: "exclamationmark.triangle.fill", tint: palette.warning)
                Spacer(minLength: DS.Space.sm)
                Button("Move to Trash") {}.buttonStyle(.borderedProminent).allowsHitTesting(false)
            }
        }
        .padding(DS.Space.md)
        .background(palette.workspace.color, in: .rect(cornerRadius: DS.Radius.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the \(palette.family.title) theme")
    }

    private func row(_ name: String, _ size: String, selected: Bool) -> some View {
        HStack {
            DSIcon(symbol: "folder", tint: palette.accentText.color)
            Text(name)
            Spacer()
            Text(size).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, DS.Space.sm)
        .frame(height: DS.Size.rowMinHeight)
        .background(selected ? palette.selection : .clear, in: .rect(cornerRadius: DS.Radius.control))
        .dsCard(radius: DS.Radius.control)
    }
}


extension SettingsView {
    fileprivate func measureSaved() async {
        savedBytes = await Task.detached(priority: .utility) { SavedResults.bytes() }.value
    }
}

/// The interface's own timings, kept on this Mac when turned on: what a
/// report about slowness can include. Nothing is sent anywhere.
private struct TimingsSection: View {
    @AppStorage(Timings.key) private var keeping = false
    @State private var summary: [Timings.Summary] = []

    var body: some View {
        DSSection("Timings") {
            Toggle(isOn: $keeping) {
                Text("Keep timings of the interface")
                Text("How long lists, table menus, app listings and Disk Map scans take, including the first content. Kept in memory until you quit; no file names or paths.")
            }
            if keeping {
                if summary.isEmpty {
                    Text("Nothing measured yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(summary, id: \.step) { s in
                        LabeledContent(s.step.title) {
                            Text("median \(Self.ms(s.median)) · p95 \(Self.ms(s.p95)) · longest \(Self.ms(s.longest)) · \(s.count)×")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Copy Timings") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Timings.text(), forType: .string)
                    }
                    .disabled(summary.isEmpty)
                    Button("Clear") {
                        Timings.clear()
                        summary = []
                    }
                    .disabled(summary.isEmpty)
                }
            }
        }
        .task(id: keeping) {
            while keeping, !Task.isCancelled {
                summary = Timings.summary()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private static func ms(_ seconds: Double) -> String {
        (seconds * 1_000).formatted(.number.precision(.fractionLength(seconds < 0.01 ? 1 : 0))) + " ms"
    }
}

/// The folders the Disk Map doesn't scan.
private struct DiskMapSkipsSection: View {
    @State private var paths = DiskMapSkips.paths()

    var body: some View {
        DSSection("Disk Map", footer: "A folder left out isn't read or counted, and isn't compared in Changes, so it never looks deleted. It's apart from Keep, which only stops moves, and from Browse's filter, which only hides rows.") {
            if paths.isEmpty {
                Text("Every folder is scanned. To leave one out, choose Don't Scan This Folder from its menu in Browse.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(paths, id: \.self) { p in
                    HStack {
                        DSPath(p, .mono)
                        Spacer()
                        Button("Scan Again") {
                            DiskMapSkips.remove(p)
                            paths = DiskMapSkips.paths()
                        }
                        .help("Include this folder in the next scan")
                    }
                }
            }
        }
    }
}

/// Each kind of saved result with its size and age, to clear on its own.
private struct SavedResultsList: View {
    let changed: () async -> Void
    @State private var parts: [SavedResults.Part] = []
    @State private var problem: String?
    @State private var pending: SavedResults.Part?
    @State private var confirming = false

    var body: some View {
        DisclosureGroup("Saved results by feature") {
            ForEach(parts.filter { $0.bytes > 0 }) { p in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title)
                        Text(
                            [
                                ByteSize.format(p.bytes),
                                p.modified.map { String(localized: "saved \($0.formatted(.relative(presentation: .named)))") },
                            ].compactMap { $0 }.joined(separator: " · ")
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear Saved Results…") {
                        pending = p; confirming = true
                    }
                    .controlSize(.small)
                }
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        }
        .task { await reload() }
        .actionConfirmation(
            String(localized: "Clear saved \(pending?.title ?? "") results?"), isPresented: $confirming,
            action: .savedResults, button: String(localized: "Clear Saved Results"),
            message: String(
                localized:
                    "Only these saved scan results are cleared. The next scan rebuilds them. Keep lists, project rules and cleanup history stay."
            )
        ) {
            guard let part = pending else { return }
            Task {
                let failed = await Task.detached(priority: .userInitiated) { SavedResults.clear(part) }.value
                problem = failed.isEmpty ? nil : String(localized: "Couldn't remove \(failed.joined(separator: ", ")).")
                await reload()
                await changed()
            }
        }
    }

    private func reload() async {
        parts = await Task.detached(priority: .utility) { SavedResults.parts() }.value
    }
}
