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
            }
        }
        .dsBottom(showing: model.privileged.isAvailable && !model.chosen.isEmpty) {
            actionBar
        } toast: {
            EmptyView()
        }
        .paneToolbar("System Clean", subtitle: "System-wide caches and old logs") {
            PaneTool.button("system-clean.rescan", "Rescan", symbol: "arrow.clockwise", help: "Scan again",
                            enabled: model.privileged.isAvailable && !model.scanning && !model.removing) { model.scan() }
        }
        .actionConfirmation(String(localized: "Permanently delete \(fmt(model.chosenBytes))?"), isPresented: $confirming,
                            button: String(localized: "Delete for Good"),
                            message: String(localized: "\(model.chosen.count) system item\(model.chosen.count == 1 ? "" : "s") are deleted for good; they can't go to the Trash. The services that made them rebuild what they need. macOS asks for an administrator's password first.")) { model.removeChosen() }
        .onAppear { model.scanIfNeeded() }
    }

    private var header: some View {
        DSPaneHeader {
            DSMetric(fmt(model.totalBytes), "found in \(model.candidates.count.formatted()) items")
        } actions: {
            DSControlField("Choose for permanent deletion") {
                Button("Choose Safe Items") { model.chooseSafe() }
                    .disabled(model.candidates.isEmpty)
                    .fixedSize()
            }
        } strip: {
            if model.scanning {
                DSRunningCapsule(text: "Scanning", since: nil)
                DSStripButton("Stop", symbol: "stop.fill") { model.stopScan() }
            } else if model.removing {
                DSRunningCapsule(text: "Removing", since: nil)
            } else if let at = model.scannedAt {
                DSCapsule("Scanned \(at.formatted(.relative(presentation: .named)))", symbol: "checkmark", tint: .green)
            }
            if let r = model.lastResult { DSCapsule(r, symbol: "trash") }
            if !model.leftStaging.isEmpty {
                DSCapsule(
                    "An earlier removal left \(model.leftStaging.count) folder\(model.leftStaging.count == 1 ? "" : "s") aside",
                    symbol: "exclamationmark.triangle.fill", tint: .orange
                )
                .help(
                    "It stopped part-way, and what it had moved aside is still in \(model.leftStaging.joined(separator: ", ")), with a note of where each item came from. MyMole never deletes it by itself, and a new removal only deletes what it moves itself. Look at it in Finder; it needs an administrator to open."
                )
            }
            if !model.unreadable.isEmpty {
                DSCapsule(
                    "\(model.unreadable.count) place\(model.unreadable.count == 1 ? "" : "s") couldn't be read",
                    symbol: "exclamationmark.triangle.fill", tint: .orange
                )
                .help("What's in \(model.unreadable.joined(separator: ", ")) isn't listed.")
            }
            if !model.keep.paths.isEmpty {
                DSCountCapsule(model.keep.paths.count, "kept")
            }
            Spacer(minLength: 0)
        } detail: {
            if let error = model.keepError {
                DSNotice(.critical, "Your keep list couldn't be read (\(error.description)). Nothing is removed until it can be.") {
                    Button("Try Again") { model.reloadKeepList() }
                    CopyErrorCodeButton(error.code)
                }
            }
            if let error = model.keepSaveError {
                DSNotice(
                    .critical,
                    "Your change to the keep list couldn't be saved (\(error.description)). Nothing is removed until it is saved or given up."
                ) {
                    Button("Try Again") { model.reloadKeepList() }
                    Button("Discard Change") { model.discardKeepChange() }
                    CopyErrorCodeButton(error.code)
                }
            }
            if let e = model.currentError {
                DSNotice(.critical, e.description) {
                    Button("Try Again") { model.scan() }
                    CopyErrorCodeButton(e.code)
                }
            }
            if !model.problems.isEmpty {
                DSNotice(.warning, problemText(model.problems)) {
                    Button("Copy") { copyProblems(model.problems) }
                    Button("Dismiss") { model.dismissProblems() }
                        .accessibilityLabel("Dismiss these problems")
                }
            }
        }
        .contextualControls(
            "Review system cleanup",
            detail:
                "Choosing only ticks items. Delete for Good permanently removes your choice after confirmation and an administrator's password."
        )
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
            onSetMarks: { paths, checked in
                guard !model.removing else { return }
                if checked { model.choose(paths) } else { model.chosen.subtract(paths) }
            },
            bulkChoicesEnabled: !model.removing,
            menu: { ids in menu(ids.compactMap { byID[$0] }) })
        .dsEmptyOverlay(showing: model.candidates.isEmpty) {
            if model.candidates.isEmpty {
                if model.scanning {
                    DSLoading("Looking through system caches and logs…")
                } else if model.scannedAt != nil, !model.unreadable.isEmpty {
                    DSIncompleteEmpty(what: String(localized: "System cleanup"), unreadable: model.unreadable) { model.scan() }
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
            r.badge = String(localized: "Kept")
            r.badgeTint = .secondaryLabelColor
            r.canChoose = false
            r.badgeHelp = String(localized: "On your keep list; never removed")
            r.choiceHelp = r.badgeHelp
        } else if c.safety == .review {
            r.badge = String(localized: "Review")
            r.badgeTint = .systemOrange
            r.badgeHelp = String(localized: "Used by macOS itself. Usually rebuilt, but some services take a while.")
        }
        if c.incomplete == true {
            r.badge = (r.badge.map { $0 + " · " } ?? "") + String(localized: "Partly unreadable")
            r.badgeHelp = String(
                localized: "Part of it couldn't be read, so it's larger than shown; it's measured again as root when removed.")
        }
        return r
    }

    private func menu(_ picked: [SystemCandidate]) -> [TableMenuEntry] {
        guard !picked.isEmpty else { return [] }
        var out: [TableMenuEntry] = []
        let unchosen = picked.filter { !model.chosen.contains($0.path) && !model.keep.protects($0.path) }
        if !unchosen.isEmpty {
            out.append(.action(unchosen.count == 1 ? String(localized: "Choose") : String(localized: "Choose \(unchosen.count)")) { model.choose(unchosen.map(\.path)) })
        }
        if picked.contains(where: { model.chosen.contains($0.path) }) {
            out.append(.action(String(localized: "Unchoose")) { model.chosen.subtract(picked.map(\.path)) })
        }
        if model.keepError == nil {
            let kept = picked.filter { model.keep.paths.contains($0.path) }
            if kept.isEmpty {
                out.append(.action(String(localized: "Always Keep")) { model.keepAlways(picked.map(\.path)) })
            } else {
                out.append(.action(String(localized: "Stop Keeping")) { model.stopKeeping(kept.map(\.path)) })
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
            Button("Delete for Good…") { confirming = true }
                .primaryAction()
                .tint(.red)
                .disabled(model.removeBlocker != nil)
                .help(model.removeBlocker ?? "")
        }
    }
}

private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
