import AppKit
import StorageKit
import SwiftUI
import UserNotifications

@main
struct MyMoleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app: AppModel
    @AppStorage(MenuBarSettings.showKey) private var showMenuBar = MenuBarSettings.showStandard

    init() {
        let model = AppModel()
        AppModel.live = model
        _app = State(initialValue: model)
    }

    var body: some Scene {
        // The one main window is `MainWindow`, made by AppKit: the app's
        // scans, choices and Undo are shared state, so a second window would
        // only show the same pane twice and leave commands without a clear
        // target. New Window is left out below. The menu bar item's scene
        // carries the app's commands.
        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarPanel(app: app).disabled(app.leaving)
        } label: {
            MenuBarLabel(app: app)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // The window is AppKit's, so the sidebar command is the app's own.
            CommandGroup(replacing: .sidebar) {
                Button("Show or Hide Sidebar") { app.toggleSidebar?() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
            CommandGroup(replacing: .appSettings) { commandButton(.settings) }
            CommandGroup(replacing: .undoRedo) {
                // Text fields keep their own Undo and Redo; elsewhere Undo
                // puts back the pane's last move to the Trash.
                Button(app.command(.undo).title) {
                    if !Self.sendToTextField(Selector(("undo:"))) { app.command(.undo).perform() }
                }
                .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { _ = Self.sendToTextField(Selector(("redo:"))) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) { commandButton(.find) }
            CommandGroup(before: .sidebar) {
                commandButton(.back)
                commandButton(.forward)
                Divider()
                commandButton(.refresh)
                commandButton(.palette)
                Divider()
            }
            CommandGroup(after: .sidebar) {
                // The panes the sidebar shows, in its order.
                ForEach(Pane.groups.flatMap(\.1)) { pane in
                    if let key = pane.shortcut {
                        Button(pane.title) { app.pane = pane }
                            .keyboardShortcut(key, modifiers: .command)
                    }
                }
            }
            // The system's "Help isn't available" makes way for the real places.
            CommandGroup(replacing: .help) {
                Link("MyMole Website", destination: Links.website)
                Link("MyMole Support", destination: Links.support)
            }
            // The disk map's views, also in the pane's toolbar menu.
            CommandMenu(String(localized: "Disk Map")) {
                commandButton(.chooseFolder)
                commandButton(.enclosingFolder)
                Divider()
                Button("Save Scan…") {
                    app.pane = .diskMap
                    app.storage.exportScan()
                }
                .disabled(app.storage.root == nil || app.storage.scanning || app.storage.opened != nil)
                Button("Open Saved Scan…") {
                    app.pane = .diskMap
                    app.storage.openExportedScan()
                }
                .disabled(app.storage.scanning || app.storage.trashing)
                Divider()
                ForEach(Array(StorageModel.Chart.allCases.enumerated()), id: \.element) { i, chart in
                    Toggle(
                        chart.title,
                        isOn: Binding(
                            get: { app.storage.chart == chart },
                            // Choosing the checked view again still opens it.
                            set: { _ in
                                app.storage.chart = chart
                                app.pane = .diskMap
                            })
                    )
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
                }
            }
        }
    }
}

extension MyMoleApp {
    /// The status item reports its visibility back on every scene update,
    /// usually unchanged. Writing that to the setting again invalidates every
    /// scene, which shows the item again and reports again: a loop that keeps
    /// the main thread busy. Only a real change is saved.
    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { showMenuBar },
            set: { inserted in
                if inserted != showMenuBar { showMenuBar = inserted }
            })
    }

    /// A menu item for a registered command, off while it can't run.
    func commandButton(_ id: AppCommand.ID) -> some View {
        let c = app.command(id)
        return Button(c.title, action: c.perform)
            .keyboardShortcut(c.key ?? " ", modifiers: c.modifiers)
            .disabled(c.blocker != nil)
    }

    /// Sends an edit action to the text field being typed in, if one is;
    /// false when none is.
    @MainActor static func sendToTextField(_ action: Selector) -> Bool {
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable else { return false }
        return NSApp.sendAction(action, to: text, from: nil)
    }
}

/// Makes the SwiftPM executable behave like a normal foreground app:
/// shows in the Dock and takes focus on launch. With the menu bar item on,
/// closing the window leaves MyMole running there, without a Dock icon,
/// until its window is opened again or it's quit.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if SMOKE
        HitchLog.start()
        #endif
        DialogKeyboardRegistry.shared.start()
        NSApp.servicesProvider = self
        if let app = AppModel.live {
            let window = MainWindow(app: app)
            MainWindow.shared = window
            app.openWindow = { window.show() }
        }
        if LoginItem.startsInMenuBar(openedAtLogin: LoginItem.wasOpenedAtLogin(), menuBar: MenuBarSettings.show()) {
            startInMenuBar()
        } else {
            NSApp.setActivationPolicy(.regular)
            MainWindow.shared?.show()
            NSApp.activate(ignoringOtherApps: true)
        }
        if Notifier.isAvailable { UNUserNotificationCenter.current().delegate = self }
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
    }

    /// "Uninstall with MyMole" in Finder's Services menu: the apps chosen
    /// there open in Uninstall's review, as a drop does.
    @MainActor @objc func uninstallApps(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = String(localized: "No apps were chosen.") as NSString
            return
        }
        application(NSApp, open: urls)
    }

    /// Apps dropped on the Dock icon: the window opens on Uninstall with them.
    @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        guard let app = AppModel.live else { return }
        app.showWindow(on: .uninstall)
        app.apps.open(urls)
    }

    /// Opened by macOS at login: straight to the menu bar, with the window
    /// left closed until the user asks for it.
    @MainActor private func startInMenuBar() {
        AppModel.live?.waitsInMenuBar = true
        NSApp.setActivationPolicy(.accessory)
    }

    /// The last window of the app's own closing while the menu bar item is
    /// on: the Dock icon goes with it.
    @MainActor @objc private func windowWillClose(_ note: Notification) {
        guard MenuBarSettings.show(), let closing = note.object as? NSWindow, Self.isDocument(closing) else { return }
        // Asked once the window has gone.
        Task { @MainActor in
            if !NSApp.windows.contains(where: { $0 !== closing && $0.isVisible && Self.isDocument($0) }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// A window of the app's own, as opposed to the menu bar item's panel or a sheet.
    @MainActor private static func isDocument(_ window: NSWindow) -> Bool {
        window.canBecomeMain && !(window is NSPanel)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { !MenuBarSettings.show() }

    /// A click on a notification opens the window on the pane it's about.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let pane = (info[Alert.paneKey] as? String).flatMap(Pane.init)
        let showOrphans = (info[Alert.actionKey] as? String) == Alert.showOrphans
        await MainActor.run {
            AppModel.live?.showWindow(on: pane)
            if showOrphans { AppModel.live?.orphans.requested = true }
        }
    }

    /// Shown also while MyMole is in front: its window may be closed.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// Opened again while it runs in the menu bar: the window comes back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.live?.showWindow() }
        return true
    }

    /// Large results kept on disk belong to this run only.
    func applicationWillTerminate(_ notification: Notification) { SpillTable.removeAll() }

    /// A quit during a move or removal stops it before its next item and
    /// waits for the job to end, so its history record is written. A job
    /// that doesn't end within the time limit, such as one waiting for an
    /// administrator's password, is left to the quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let jobs = TrashJobs.shared
        guard jobs.isBusy else { return .terminateNow }
        jobs.stop()
        Task { @MainActor in
            let deadline = ContinuousClock.now + .seconds(10)
            while jobs.isBusy, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            // A pane writes its record right after its job ends.
            try? await Task.sleep(for: .milliseconds(200))
            CleanupLog.flush()
            StoreWrites.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct RootView: View {
    @Bindable var app: AppModel
    /// Density changes layout while native views keep their identity.
    @AppStorage(Density.key) private var density = Density.standard.rawValue
    @AppStorage(ThemeFamily.key) private var theme = ThemeFamily.standard.rawValue
    @AppStorage(AppearanceMode.key) private var mode = AppearanceMode.system.rawValue
    @AppStorage(TableLines.key) private var lines = TableLines.standard.rawValue
    @AppStorage(MenuBarSettings.showKey) private var showMenuBar = MenuBarSettings.showStandard
    /// Read once per window: the first start asks about the menu bar item.
    @State private var askMenuBar = MenuBarSettings.shouldAsk()
    @State private var sidebarShown = true

    private func toggleSidebar() {
        withAnimation(Motion.snappy) { sidebarShown.toggle() }
    }

    private var palette: Palette { (ThemeFamily(rawValue: theme) ?? .standard).palette }

    var body: some View {
        MainSplit(sidebarShown: $sidebarShown) {
            List(selection: $app.pane) {
                ForEach(Pane.groups, id: \.0) { group, panes in
                    Section(group) {
                        ForEach(panes) { pane in
                            Label {
                                HStack {
                                    Text(pane.title)
                                    Spacer(minLength: 4)
                                    badge(pane)
                                }
                            } icon: {
                                Image(systemName: pane.symbol)
                            }
                            .tag(pane)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .focusSection()
            .safeAreaInset(edge: .top) { brandHeader }
            .safeAreaInset(edge: .bottom) { editionBadge }
            .frame(minWidth: 210)
        } detail: {
            PaneFrame(minWidth: 760, minHeight: 560) {
                detail
                    .focusSection()
                    .background(palette.workspace.color)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if askMenuBar { MenuBarQuestion(asking: $askMenuBar) }
                    }
            }
        }
        .tint(palette.accent.color)
        // A theme reaches every view through the environment: they redraw,
        // nothing is made again and no scan restarts.
        .environment(\.palette, palette)
        .environment(\.tableLines, TableLines(rawValue: lines) ?? .standard)
        .environment(\.layoutDensity, Density(rawValue: density) ?? .standard)
        .controlSize((Density(rawValue: density) ?? .standard) == .compact ? .small : .regular)
        .onChange(of: density) { _, value in Density.current = Density(rawValue: value) ?? .standard }
        .environment(\.findRequest, app.findRequest)
        // For Back and Forward in every pane's toolbar (`paneToolbar`).
        .environment(app)
        .sheet(isPresented: $app.showPalette) { CommandPalette(app: app).environment(\.palette, palette) }
        .emptyTrashFlow(app.trash)
        .overlay(alignment: .topTrailing) {
            if !app.apps.uninstalling, !app.deepClean.trashing, !app.installers.trashing,
               !app.projects.trashing, !app.duplicates.trashing, !app.orphans.trashing {
                ConfirmationToast {
                    app.settingsQuery = String(localized: "Confirmations")
                    app.pane = .settings
                }
            }
        }
        // The window's appearance, which its AppKit tables follow too.
        .preferredColorScheme((AppearanceMode(rawValue: mode) ?? .system).colorScheme)
        // The window's toolbar is AppKit's own (`MainToolbar`); each pane
        // hands it its title and tools (see `paneToolbar`).
        .background(MainToolbarHost(app: app, back: app.command(.back), forward: app.command(.forward), toggleSidebar: toggleSidebar))
        // Re-probe whenever the app comes forward — the user is most likely
        // returning from System Settings after granting access.
        .liveRefresh(every: .seconds(2), events: []) {
            app.recheckDiskAccess()
            #if !APPSTORE
            app.privileged.helper?.refresh()
            #endif
            await app.diskAccess.job?.value
        }
        .task {
            app.toggleSidebar = { toggleSidebar() }
            app.startMonitoring()
            if askMenuBar { MenuBarSettings.markAsked() }
        }
        // Chosen in Settings meanwhile: nothing left to ask.
        .onChange(of: showMenuBar) { withAnimation(Motion.snappy) { askMenuBar = false } }
    }

    @ViewBuilder private var detail: some View {
        if let place = app.gate(for: app.pane) {
            FolderAccessGate(app: app, place: place)
                .paneToolbar("\(app.pane.title)", subtitle: "Needs access to \(place.inSentence)")
        } else if app.pane.needsDiskAccess && !app.fullDiskAccess {
            FullDiskAccessGate(app: app)
                .paneToolbar("\(app.pane.title)", subtitle: "Needs Full Disk Access")
        } else {
            switch app.pane {
            case .dashboard: DashboardView(app: app)
            case .optimize: OptimizeView(model: app.maintenance)
            case .clean: DeepCleanView(model: app.deepClean, openSystemClean: { app.pane = .systemClean })
            case .systemClean: SystemCleanView(model: app.systemClean)
            case .installer: InstallersView(model: app.installers)
            case .uninstall: UninstallView(model: app.apps, orphans: app.orphans, selfRemoval: app.selfRemoval)
            case .diskMap: StorageView(model: app.storage)
            case .projects: ProjectsView(app: app, model: app.projects)
            case .status: StatusView(app: app)
            case .history: HistoryView(app: app)
            case .startup: StartupView(model: app.startup)
            case .duplicates: DuplicatesPane(duplicates: app.duplicates, similar: app.similar)
            case .settings: SettingsView(app: app)
            }
        }
    }

    /// Per-pane scan state in the sidebar: a spinner while a scan runs, the
    /// result once it's in, so parallel scans are visible at a glance.
    @ViewBuilder private func badge(_ pane: Pane) -> some View {
        let busy =
            (pane == .optimize && app.maintenance.phase != .idle)
            || (pane == .systemClean && (app.systemClean.scanning || app.systemClean.removing))
            || (pane == .uninstall && (app.apps.loading || app.apps.uninstalling || app.orphans.loading || app.orphans.trashing))
            || (pane == .diskMap && app.storage.scanning)
            || (pane == .projects && app.projects.refreshing)
            || (pane == .installer && app.installers.scanning)
            || (pane == .clean && (app.deepClean.scanning || app.deepClean.trashing))
            || (pane == .duplicates && (app.duplicates.scanning || app.duplicates.trashing || app.similar.scanning || app.similar.trashing))
            || (pane == .startup && (app.startup.loading || app.startup.trashing))
        if busy {
            PulseDot(size: 7)
        } else if let text = app.badge(for: pane) {
            Text(text)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var brandHeader: some View {
        HStack(spacing: DS.Space.sm) {
            AppIconImage(size: 30)
            Text("MyMole").font(.title3.weight(.semibold)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Spacer()
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.xs)
    }

    private var editionBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(app.canScan ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(Edition.current.isSandboxed ? (app.canScan ? String(localized: "App Store edition") : String(localized: "Needs folder access")) : (app.canScan ? String(localized: "Ready") : String(localized: "Needs Full Disk Access")))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
    }
}

/// The single permission step. Scanning without Full Disk Access makes macOS
/// ask separately for every protected folder and every other app's data the
/// walk touches — dozens of dialogs. Granting it once here replaces them all,
/// so nothing that scans runs until it's granted.
struct FullDiskAccessGate: View {
    let app: AppModel

    var body: some View {
        CenterCard(
            symbol: "lock.shield",
            title: "Allow Full Disk Access",
            subtitle:
                "MyMole needs access to protected folders to find caches, app leftovers and disk usage. Scanning waits until access is available."
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Text("In Privacy & Security → Full Disk Access, turn on this copy of MyMole. If it isn't listed, use + to add it. Show This Copy in Finder locates the app you're using now.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button { FullDiskAccess.openSettings() } label: {
                    Text("Open System Settings").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                DSControlGrid(minimum: 200, spacing: DS.Space.sm) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    } label: { Text("Show This Copy in Finder").foregroundStyle(.primary).frame(maxWidth: .infinity, minHeight: 24) }
                    Button { app.recheckDiskAccess() } label: { Text("Check Now").foregroundStyle(.primary).frame(maxWidth: .infinity, minHeight: 24) }
                        .disabled(app.diskAccess.checking)
                }
                Label(app.diskAccess.checking ? String(localized: "Checking access…") : String(localized: "Checks automatically while this page is open"),
                      systemImage: "arrow.trianglehead.2.clockwise")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("If macOS asks you to quit and reopen MyMole, follow that prompt. This page continues automatically when access is detected.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A switch turned on in System Settings is noticed while this shows,
        // without having to come back to MyMole first.
    }
}
