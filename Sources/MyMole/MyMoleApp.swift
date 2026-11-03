import AppKit
import SwiftUI

@main
struct MyMoleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup("MyMole") {
            RootView(app: app)
                .task { app.prefetchScans() }
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(after: .sidebar) {
                ForEach(Array(Pane.allCases.enumerated()), id: \.element) { i, pane in
                    if i < 9 {
                        Button(pane.title) { app.pane = pane }
                            .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    }
                }
            }
            // The disk map's views, also in the pane's toolbar menu.
            CommandMenu("Disk Map") {
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

/// Makes the SwiftPM executable behave like a normal foreground app:
/// shows in the Dock and takes focus on launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

struct RootView: View {
    @Bindable var app: AppModel
    /// A change of density makes every view, and the AppKit tables, again.
    @AppStorage(Density.key) private var density = Density.standard.rawValue

    var body: some View {
        NavigationSplitView {
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
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .top) { brandHeader }
            .safeAreaInset(edge: .bottom) { editionBadge }
        } detail: {
            detail
                .frame(minWidth: 760, minHeight: 560)
        }
        .tint(Theme.accent)
        .id(density)
        // Each pane draws its own title in the toolbar (see `paneToolbar`).
        .toolbar(removing: .title)
        // Re-probe whenever the app comes forward — the user is most likely
        // returning from System Settings after granting access.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.recheckDiskAccess()
        }
    }

    @ViewBuilder private var detail: some View {
        if let place = app.gate(for: app.pane) {
            FolderAccessGate(app: app, place: place)
                .paneToolbar(app.pane.title, subtitle: "Needs access to \(place.inSentence)")
        } else if app.pane.needsDiskAccess && !app.fullDiskAccess {
            FullDiskAccessGate(app: app)
                .paneToolbar(app.pane.title, subtitle: "Needs Full Disk Access")
        } else {
            switch app.pane {
            case .dashboard: DashboardView(app: app)
            case .optimize: OptimizeView(model: app.maintenance)
            case .clean: DeepCleanView(model: app.deepClean, openSystemClean: { app.pane = .systemClean })
            case .systemClean: SystemCleanView(model: app.systemClean)
            case .installer: InstallersView(model: app.installers)
            case .uninstall: UninstallView(model: app.apps)
            case .diskMap: StorageView(model: app.storage)
            case .projects: ProjectsView(app: app, model: app.projects)
            case .status: StatusView(app: app)
            case .history: HistoryView(app: app)
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
            || (pane == .uninstall && (app.apps.loading || app.apps.uninstalling))
            || (pane == .diskMap && app.storage.scanning)
            || (pane == .projects && app.projects.scanning)
            || (pane == .installer && app.installers.scanning)
            || (pane == .clean && (app.deepClean.scanning || app.deepClean.trashing))
        if busy {
            PulseDot(size: 7)
        } else if let text = app.badge(for: pane) {
            Text(text)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 8) {
            AppIconImage(size: 30)
            Text("MyMole").font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var editionBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(app.canScan ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(Edition.current.isSandboxed ? (app.canScan ? "App Store edition" : "Needs folder access") : (app.canScan ? "Ready" : "Needs Full Disk Access"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            title: "Allow Full Disk Access once",
            subtitle:
                "Cleaning and disk maps read your whole home folder, including other apps' data. Without Full Disk Access macOS asks again for every folder it protects. Turn on MyMole in System Settings → Privacy & Security → Full Disk Access — if it isn't listed, click + and pick MyMole.app. Nothing is scanned until then."
        ) {
            HStack {
                Button("Open System Settings") { FullDiskAccess.openSettings() }
                    .primaryAction()
                Button("Show MyMole.app") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                .controlSize(.large)
                Button("Check Again") { app.recheckDiskAccess() }
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
