import AppKit
import StorageKit
import SwiftUI

/// What Homebrew and installer packages put on the Mac, only to look at:
/// read from where they keep it, never by running a package tool. A
/// package is removed with its own tool; MyMole can copy the command.
struct PackagesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var listing: PackageListing?
    @State private var selection = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("Installed Packages").font(.title2.bold())
            DSText(
                "Homebrew formulae and casks, and packages installers put on the Mac, read from where they're kept. Nothing is run and nothing is removed here: a package goes with its own tool, so its records stay right.",
                .metadata)
            if let listing {
                if listing.noHomebrew {
                    DSNotice(
                        .info,
                        Edition.current.isSandboxed
                            ? "Homebrew wasn't found, or this edition may not look where it installs: the App Sandbox keeps App Store apps out of /opt/homebrew and /usr/local."
                            : "Homebrew isn't installed in /opt/homebrew or /usr/local.")
                }
                if !listing.unreadable.isEmpty {
                    DSNotice(
                        .warning,
                        "\(listing.unreadable.count) place\(listing.unreadable.count == 1 ? "" : "s") couldn't be read, so what's there isn't listed: \(listing.unreadable.joined(separator: ", "))."
                    )
                }
                FileTable(
                    rows: listing.packages.map(row), columns: [.name, .size, .kind, .modified, .location],
                    hiddenByDefault: [.location], titles: [.kind: String(localized: "What"), .modified: String(localized: "Installed")],
                    autosave: "packages.list", selection: $selection, marks: nil,
                    onOpen: { ids in FileActions.reveal(ids.compactMap { id in listing.packages.first { $0.id == id }?.path }) },
                    menu: { ids in menu(listing.packages.filter { ids.contains($0.id) }) },
                    filePaths: { ids in let wanted = Set(ids); return listing.packages.filter { wanted.contains($0.id) }.compactMap(\.path) }
                )
                .frame(height: 360)
            } else {
                DSLoading("Reading installed packages…").frame(height: 360)
            }
            DSActionGroup {
                if let listing { DSText(String(localized: "\(listing.packages.count) packages"), .metadata) }
            } trailing: {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.reviewWidth)
        .dialogControls()
        .dialogKeyboard()
        .task { listing = await Task.detached(priority: .userInitiated) { Packages.list() }.value }
    }

    private func row(_ p: InstalledPackage) -> FileRow {
        FileRow(
            id: p.id, name: p.name, size: p.bytes, modified: p.installed,
            kind: ([p.source.title] + (p.versions.isEmpty ? [] : [p.versions.joined(separator: ", ")])).joined(separator: " · "),
            location: p.path, symbol: p.source == .receipt ? "shippingbox" : "mug")
    }

    private func menu(_ chosen: [InstalledPackage]) -> [TableMenuEntry] {
        guard !chosen.isEmpty else { return [] }
        var out = FileActions.menu(chosen.map(\.path), canOpen: false)
        let brew = chosen.filter { $0.source != .receipt }
        if !brew.isEmpty {
            out.append(.action(String(localized: "Copy Uninstall Command")) {
                let formulae = brew.filter { $0.source == .formula }.map(\.name)
                let casks = brew.filter { $0.source == .cask }.map(\.name)
                let lines = (formulae.isEmpty ? [] : ["brew uninstall " + formulae.joined(separator: " ")])
                    + (casks.isEmpty ? [] : ["brew uninstall --cask " + casks.joined(separator: " ")])
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            })
        }
        return out
    }
}
