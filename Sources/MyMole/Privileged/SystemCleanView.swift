import PrivilegedKit
import StorageKit
import SwiftUI

/// The System Clean pane: caches and logs in /Library and /private/var that
/// only root may remove: found as the user, removed by MyMole's privileged
/// tool after macOS asks for an administrator's password. They're
/// deleted for good, so only Safe items start chosen, kept items never are,
/// and every run confirms.
struct SystemCleanView: View {
    @Bindable var model: SystemCleanModel
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.privileged.isAvailable {
                CenterCard(symbol: "lock.shield", title: "Not in this edition", subtitle: "System caches belong to root, which App Store apps may not ask for. The direct edition of MyMole cleans them.") {}
            } else {
                header
                Divider()
                table
                if !model.chosen.isEmpty { actionBar }
            }
        }
        .paneToolbar("System Clean", subtitle: "System-wide caches and old logs") {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.scan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Scan again")
                .disabled(!model.privileged.isAvailable || model.scanning || model.removing)
            }
        }
        .confirmationDialog("Permanently delete \(fmt(model.chosenBytes))?", isPresented: $confirming) {
            Button("Delete", role: .destructive) { model.removeChosen() }
        } message: {
            Text("\(model.chosen.count) system item\(model.chosen.count == 1 ? "" : "s") are deleted for good; they can't go to the Trash. The services that made them rebuild what they need. macOS asks for an administrator's password first.")
        }
        .onAppear { model.scanIfNeeded() }
    }

    private var header: some View {
        DSPaneHeader {
            DSMetric(fmt(model.totalBytes), "found in \(model.candidates.count.formatted()) items")
        } actions: {
            Button("Choose Safe Items") { model.chooseSafe() }
                .disabled(model.candidates.isEmpty)
                .fixedSize()
        } strip: {
            if model.scanning {
                DSRunningCapsule(text: "Scanning", since: nil)
            } else if model.removing {
                DSRunningCapsule(text: "Removing", since: nil)
            } else if let at = model.scannedAt {
                DSCapsule("Scanned \(at.formatted(.relative(presentation: .named)))", symbol: "checkmark", tint: .green)
            }
            if let r = model.lastResult { DSCapsule(r, symbol: "trash") }
            if !model.keep.paths.isEmpty {
                DSCountCapsule(model.keep.paths.count, "kept")
            }
            Spacer(minLength: 0)
        } detail: {
            if let error = model.keepError {
                DSNotice(.critical, "Your keep list couldn't be read (\(error)). Nothing is removed until it can be.") {
                    Button("Try Again") { model.reloadKeepList() }
                }
            }
            if let error = model.keepSaveError {
                DSNotice(.critical, "Your change to the keep list couldn't be saved (\(error)). Nothing is removed until it is saved or given up.") {
                    Button("Try Again") { model.reloadKeepList() }
                    Button("Discard Change") { model.discardKeepChange() }
                }
            }
            if let e = model.currentError {
                DSNotice(.critical, e) { Button("Try Again") { model.scan() } }
            }
            if !model.problems.isEmpty {
                DSNotice(.warning, problemText(model.problems)) {
                    Button("Copy") { copyProblems(model.problems) }
                    Button("Dismiss") { model.dismissProblems() }
                }
            }
        }
    }

    private var table: some View {
        let byID = Dictionary(model.candidates.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return FileTable(
            rows: model.candidates.map(row),
            columns: [.name, .size, .modified, .location],
            autosave: "systemClean.list",
            selection: $model.selection,
            marks: model.chosen,
            onToggleMark: { model.toggle($0) },
            onOpen: { FileActions.reveal($0) },
            onMark: { model.choose($0) },
            menu: { ids in menu(ids.compactMap { byID[$0] }) })
        .overlay {
            if model.candidates.isEmpty {
                if model.scanning {
                    DSLoading("Looking through system caches and logs…")
                } else if model.scannedAt != nil {
                    ContentUnavailableView("Nothing to Clean", systemImage: "bubbles.and.sparkles",
                                           description: Text("System caches and logs are already tidy."))
                }
            }
        }
    }

    private func row(_ c: SystemCandidate) -> FileRow {
        var r = FileRow(
            id: c.path, name: c.name, size: c.bytes, modified: c.modified > .distantPast ? c.modified : nil,
            location: (c.path as NSString).deletingLastPathComponent, symbol: "gearshape",
            tint: c.safety == .safe ? .systemGreen : .systemOrange)
        if model.keep.protects(c.path) {
            r.badge = "Kept"
            r.badgeHelp = "On your keep list; never removed"
        } else if c.safety == .review {
            r.badge = "Review"
            r.badgeHelp = "Used by macOS itself. Usually rebuilt, but some services take a while."
        }
        if c.incomplete == true {
            r.badge = (r.badge.map { $0 + " · " } ?? "") + "Partly unreadable"
            r.badgeHelp = "Part of it couldn't be read, so it's larger than shown; it's measured again as root when removed."
        }
        return r
    }

    private func menu(_ picked: [SystemCandidate]) -> [TableMenuEntry] {
        guard !picked.isEmpty else { return [] }
        var out: [TableMenuEntry] = []
        let unchosen = picked.filter { !model.chosen.contains($0.path) && !model.keep.protects($0.path) }
        if !unchosen.isEmpty {
            out.append(.action(unchosen.count == 1 ? "Choose" : "Choose \(unchosen.count)") { model.choose(unchosen.map(\.path)) })
        }
        if picked.contains(where: { model.chosen.contains($0.path) }) {
            out.append(.action("Unchoose") { model.chosen.subtract(picked.map(\.path)) })
        }
        if model.keepError == nil {
            let kept = picked.filter { model.keep.paths.contains($0.path) }
            if kept.isEmpty {
                out.append(.action("Always Keep") { model.keepAlways(picked.map(\.path)) })
            } else {
                out.append(.action("Stop Keeping") { model.stopKeeping(kept.map(\.path)) })
            }
        }
        out.append(.divider)
        out += FileActions.menu(picked.map(\.path))
        return out
    }

    private var actionBar: some View {
        DSActionBar {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                DSText("\(model.chosen.count.formatted()) chosen · \(fmt(model.chosenBytes))", .lead).keepWhole()
                Label("Deleted for good — system files can't go to the Trash.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        } trailing: {
            Button("Delete…") { confirming = true }
                .primaryAction()
                .disabled(model.removeBlocker != nil)
                .help(model.removeBlocker ?? "")
        }
    }
}

private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
