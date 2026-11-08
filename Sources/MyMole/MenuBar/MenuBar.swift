import AppKit
import StorageKit
import SwiftUI
import SystemKit

/// The menu bar item: whether it shows, and what stands beside its icon.
enum MenuBarSettings {
    static let showKey = "menuBar.show"
    static let freeKey = "menuBar.showFree"

    /// On until turned off. The UI smoke test's copy has none, so closing
    /// its window still ends it.
    static var showStandard: Bool {
        #if SMOKE
        false
        #else
        true
        #endif
    }

    static func show(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showKey) as? Bool ?? showStandard
    }

    /// Set once the first start has asked whether the item stays.
    static let askedKey = "menuBar.asked"

    /// Asked on the first start only, while the item shows and nobody has
    /// chosen in Settings yet. Never in the smoke test's copy.
    static func shouldAsk(in defaults: UserDefaults = .standard) -> Bool {
        showStandard && !defaults.bool(forKey: askedKey) && defaults.object(forKey: showKey) == nil
    }

    /// The question has been put: it isn't asked again, answered or not.
    static func markAsked(in defaults: UserDefaults = .standard) { defaults.set(true, forKey: askedKey) }
}

/// The first start's question, above every pane until it's answered or
/// closed: does the menu bar item stay? Closing it keeps the item.
struct MenuBarQuestion: View {
    @AppStorage(MenuBarSettings.showKey) private var show = MenuBarSettings.showStandard
    @Binding var asking: Bool

    var body: some View {
        DSNotice(.info, "Keep MyMole in the menu bar? The disk, memory and what the scans found at a glance. You can change this in Settings.") {
            HStack(spacing: DS.Space.sm) {
                Button("Remove") { answer(keep: false) }
                    .help("Take MyMole out of the menu bar; closing its window quits it")
                Button("Keep") { answer(keep: true) }
                    .buttonStyle(.borderedProminent)
                Button { answer(keep: show) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close; MyMole stays in the menu bar")
                    .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.top, DS.Space.sm)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func answer(keep: Bool) {
        show = keep
        withAnimation(Motion.snappy) { asking = false }
    }
}

/// What the menu bar item says, kept short: a menu bar has no room to spare.
enum MenuBarText {
    /// The disk is this full before the icon warns.
    static let nearlyFull = 90.0

    /// "103 GB", "8,4 GB": whole gigabytes from ten up, one decimal below.
    static func free(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        guard gb >= 1 else { return ByteSize.format(bytes) }
        return gb.formatted(.number.precision(.fractionLength(gb >= 10 ? 0 : 1))) + " GB"
    }

    static func symbol(usedPercent: Double?) -> String {
        (usedPercent ?? 0) >= nearlyFull ? "externaldrive.badge.exclamationmark" : "internaldrive"
    }
}

struct MenuBarLabel: View {
    let app: AppModel
    @AppStorage(MenuBarSettings.freeKey) private var showFree = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let volume = app.status?.startupVolume
        HStack(spacing: 3) {
            Image(systemName: MenuBarText.symbol(usedPercent: volume?.usedPercent))
            if showFree, let volume { Text(MenuBarText.free(volume.available)) }
        }
        .accessibilityLabel(volume.map { String(localized: "MyMole, \(MenuBarText.free($0.available)) free") } ?? "MyMole")
        .task {
            app.openWindow = { openWindow(id: MyMoleApp.mainWindow) }
            app.startMonitoring()
        }
    }
}

/// The panel under the menu bar item: the Mac at a glance, what the scans
/// found, and the way into the window. Nothing is removed from here; the
/// Trash is emptied from the window, after its confirmation.
struct MenuBarPanel: View {
    let app: AppModel
    @AppStorage(ThemeFamily.key) private var theme = ThemeFamily.standard.rawValue
    @Environment(\.controlActiveState) private var active

    /// A reading this often while the panel is open.
    static let interval: Duration = .seconds(3)
    static let width: CGFloat = 300

    private var palette: Palette { (ThemeFamily(rawValue: theme) ?? .standard).palette }

    var body: some View {
        let finds = finds
        VStack(alignment: .leading, spacing: DS.Space.md) {
            header
            meters
            if !finds.isEmpty || app.trash.canEmpty {
                Divider()
                VStack(spacing: DS.Space.xxs) {
                    ForEach(finds, id: \.pane) { find in
                        row(find.pane.title, symbol: find.pane.symbol, value: find.text, help: "Open \(find.pane.title)") {
                            app.showWindow(on: find.pane)
                        }
                    }
                    if app.trash.canEmpty, let bytes = app.trash.bytes {
                        row(String(localized: "Trash"), symbol: "trash", value: ByteSize.format(bytes), help: "Empty the Trash, after a confirmation") {
                            app.showWindow(on: .history)
                            Task { await app.trash.askToEmpty() }
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: DS.Space.sm) {
                Button {
                    app.scanAll()
                    app.showWindow(on: .clean)
                } label: {
                    Label("Scan", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                Button("Open MyMole") { app.showWindow() }
                Spacer(minLength: 0)
                Button("Quit") { NSApp.terminate(nil) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.lg)
        .frame(width: Self.width)
        .tint(palette.accent.color)
        .environment(\.palette, palette)
        // Live only while the panel is the window in front.
        .task(id: active) {
            guard active == .key else { return }
            while !Task.isCancelled {
                await app.refreshStatus()
                try? await Task.sleep(for: AppModel.paced(Self.interval))
            }
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            AppIconImage(size: 22)
            Text("MyMole").font(.headline)
            Spacer(minLength: DS.Space.sm)
            if let health = app.status?.health {
                DSCapsule("Health \(health.scoreText)", tint: health.score >= 80 ? .secondary : health.score >= 60 ? palette.warning : palette.critical)
                    .help(health.summary)
            }
        }
    }

    private var meters: some View {
        VStack(spacing: DS.Space.sm) {
            if let volume = app.status?.startupVolume {
                meter(String(localized: "Disk"), volume.usedPercent, String(localized: "\(MenuBarText.free(volume.available)) free"))
            }
            if let memory = app.status?.memory {
                meter(String(localized: "Memory"), memory.usedPercent, "\(Int(memory.usedPercent))%")
            }
            if let cpu = app.status?.cpu {
                meter(String(localized: "CPU"), cpu.usage, "\(Int(cpu.usage.rounded()))%")
            }
            if app.status == nil { DSText("Reading your Mac's status…", .metadata) }
        }
    }

    private func meter(_ name: String, _ percent: Double, _ value: String) -> some View {
        HStack(spacing: DS.Space.sm) {
            Text(name).font(.callout).frame(width: 58, alignment: .leading)
            UsageBar(fraction: percent / 100)
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    /// What the last scans found, pane by pane.
    private var finds: [(pane: Pane, text: String)] {
        [Pane.clean, .projects, .installer, .systemClean].compactMap { pane in
            pane.isAvailable ? app.badge(for: pane).map { (pane, $0) } : nil
        }
    }

    private func row(_ title: String, symbol: String, value: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.sm) {
                DSIcon(symbol: symbol, tint: palette.accentText.color)
                Text(title).font(.callout)
                Spacer(minLength: DS.Space.sm)
                Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(minHeight: 24)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension AppModel {
    /// Brings the main window forward, on `pane` when one is given; opens
    /// it again when it was closed to the menu bar.
    func showWindow(on pane: Pane? = nil) {
        if let pane { self.pane = pane }
        waitsInMenuBar = false
        NSApp.setActivationPolicy(.regular)
        openWindow?()
        NSApp.activate(ignoringOtherApps: true)
        // The scans a launch at login left for later.
        prefetchScans()
    }
}
