import AppKit
import StorageKit
import SwiftUI

/// Laid out as a grouped Form, the same structure as System Settings.
struct SettingsView: View {
    let app: AppModel
    @AppStorage(PerformanceLevel.defaultsKey) private var performance = PerformanceLevel.standard.rawValue
    @AppStorage(Density.key) private var density = Density.standard.rawValue

    private var level: PerformanceLevel { PerformanceLevel(saved: performance) }

    var body: some View {
        Form {
            Section {
                Picker("Layout", selection: Binding(
                    get: { Density(rawValue: density) ?? .standard },
                    set: { d in
                        // Measures first, then the views are made again with them.
                        Density.current = d
                        density = d.rawValue
                    })
                ) {
                    ForEach(Density.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            } header: {
                Text("Appearance")
            } footer: {
                Text("Spacious gives margins, rows and the gaps between columns more room. Compact fits the most on screen.")
            }

            Section {
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
            } header: {
                Text("Performance")
            } footer: {
                Text("How hard scans may work. Lower levels use fewer threads at a lower priority, so the Mac stays quiet while scans take longer. A change applies from the next scan.")
            }

            if Edition.current.isSandboxed {
                Section {
                    ForEach(FolderAccess.Place.allCases) { place in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.title)
                                Text(place.why).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if app.access.has(place) {
                                Button("Take Back") { app.access.revoke(place) }
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
                } header: {
                    Text("Folder Access")
                } footer: {
                    Text("The App Store edition works only in the folders you choose here. Full Disk Access in System Settings also lets it into the folders macOS protects inside them.")
                }
            } else {
                Section {
                    Text("System Clean, Optimize's administrator tasks and system-wide app leftovers run as root. macOS asks for an administrator's password each time one runs; nothing is installed and nothing keeps running.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("System Tasks")
                }
            }

            Section {
                keepProblem(read: app.deepClean.keepError, save: app.deepClean.keepSaveError,
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
                            Spacer()
                            Button("Remove") { app.deepClean.stopKeeping([path]) }
                        }
                    }
                }
            } header: {
                Text("Deep Clean Keep List")
            } footer: {
                Text("Kept items, and anything inside them, are never offered or moved.")
            }

            if Edition.current.hasSystemTasks {
            Section {
                keepProblem(read: app.systemClean.keepError, save: app.systemClean.keepSaveError,
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
                            Spacer()
                            Button("Remove") { app.systemClean.stopKeeping([path]) }
                        }
                    }
                }
            } header: {
                Text("System Clean Keep List")
            } footer: {
                Text("Kept system items, and anything inside them, are never chosen or removed.")
            }
            }

            Section("About") {
                Text("MyMole is source-available. Personal non-commercial use is permitted; business and organizational use requires a paid commercial license.")
                    .foregroundStyle(.secondary)
                Text("MyMole is a native Mac cleaner. Everything it removes is chosen by you; your own files go to the Trash, with Undo. In the direct edition, system caches are deleted after macOS asks for an administrator's password.")
                    .foregroundStyle(.secondary)
                HStack {
                    if let url = Bundle.main.url(forResource: "MyMole-LICENSE", withExtension: "txt", subdirectory: "Licenses") {
                        Button("MyMole License") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .paneToolbar("Settings", subtitle: Edition.current.isSandboxed ? "Folder access and keep lists" : "System tasks and keep lists")
    }

    /// Why a keep list isn't what the user sees, as the pane that uses it
    /// says it: nothing is removed against it until this is resolved.
    @ViewBuilder
    private func keepProblem(read: String?, save: String?, retry: @escaping () -> Void, discard: @escaping () -> Void) -> some View {
        if let read {
            DSNotice(.critical, "This list couldn't be read (\(read)). Nothing is removed against it until it can be.") {
                Button("Try Again", action: retry)
            }
        } else if let save {
            DSNotice(.critical, "Your change couldn't be saved (\(save)). Nothing is removed until it's saved or given up.") {
                Button("Try Again", action: retry)
                Button("Discard Change", action: discard)
            }
        }
    }
}
