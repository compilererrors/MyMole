import Foundation
import StorageKit
import SwiftUI

/// The Trash on the startup disk: what it holds, and emptying it. Emptying
/// is the one removal in MyMole that can't be undone, so it always goes
/// through a confirmation that shows exactly what was listed, and only that
/// is removed.
@MainActor
@Observable
final class TrashModel {
    /// The history's name for an emptying of the Trash.
    static let source = "Trash"
    /// The Trash is measured again at most this often.
    static let freshFor: TimeInterval = 60

    /// What the Trash held when last measured; nil when it wasn't measured
    /// or can't be read (no Full Disk Access).
    private(set) var listing: TrashEmptier.Listing?
    private(set) var measuring = false
    private(set) var emptying = false
    /// The listing a confirmation is asking about.
    var confirming: TrashEmptier.Listing?
    /// What the last emptying did, or why it didn't start.
    var notice: String?

    @ObservationIgnored private var measuredAt: Date?
    @ObservationIgnored private var measureJob: Task<TrashEmptier.Listing?, Never>?
    private let folder: String
    private let jobs: TrashJobs
    private let logURL: URL

    init(folder: String = Home.path + "/.Trash", jobs: TrashJobs = .shared, logURL: URL = CleanupLog.defaultURL) {
        self.folder = folder
        self.jobs = jobs
        self.logURL = logURL
    }

    var bytes: Int64? { listing?.bytes }
    var count: Int { listing?.count ?? 0 }
    /// Something lies in the Trash and nothing is working on it.
    var canEmpty: Bool { count > 0 && !emptying }

    /// Measures the Trash off the main thread, unless it was measured within the last minute.
    func refresh(force: Bool = false) async {
        guard !measuring, !emptying else { return }
        if !force, let measuredAt, Date().timeIntervalSince(measuredAt) < Self.freshFor { return }
        listing = await measure()
        // The App Sandbox can't look at other disks' Trash.
        guard !Edition.current.isSandboxed else { return }
        let volumes = Volumes.mounted().map { (path: $0.path, name: $0.name) }
        otherTrashes = await Task.detached(priority: .utility) { TrashEmptier.otherTrashes(on: volumes) }.value
    }

    /// Your Trash on other disks, only measured: Finder empties those.
    private(set) var otherTrashes: [TrashEmptier.VolumeTrash] = []

    /// One listing at a time. A caller that comes while one runs waits for
    /// it and then lists again, so what it gets is the Trash as it is now.
    private func measure() async -> TrashEmptier.Listing? {
        while let running = measureJob {
            _ = await running.value
            if measureJob == running { break }
        }
        let folder = folder
        let job = Task.detached(priority: .utility) { TrashEmptier.list(folder) }
        measureJob = job
        measuring = true
        let found = await job.value
        if measureJob == job {
            measureJob = nil
            measuring = false
        }
        measuredAt = Date()
        return found
    }

    /// Lists the Trash as it is now and asks to confirm exactly that. A
    /// listing under way is waited for, so the ask is never dropped.
    func askToEmpty() async {
        guard !emptying else { return }
        notice = nil
        listing = await measure()
        guard let listing else {
            notice = String(localized: "MyMole couldn't read the Trash.")
            return
        }
        guard listing.count > 0 else {
            notice = String(localized: "The Trash is already empty.")
            return
        }
        confirming = listing
    }

    /// Deletes what the confirmation showed, for good. Runs in the turn of
    /// destructive jobs, so it never overlaps a move to the Trash or an
    /// Undo, and a quit stops it before its next item.
    func empty(_ confirmed: TrashEmptier.Listing) async {
        guard !emptying else { return }
        confirming = nil
        emptying = true
        let out = await jobs.perform(.deleteForGood) { job in
            TrashEmptier.empty(confirmed, stop: { job.isStopped })
        }
        CleanupLog.submit(
            CleanupRecord(source: Self.source, items: 0, bytes: out.bytes, failed: out.failed, deleted: out.removed), to: logURL)
        emptying = false
        notice = Self.report(out)
        listing = await measure()
    }

    static func report(_ out: TrashEmptier.Outcome) -> String {
        var parts: [String] = []
        if out.removed > 0 {
            parts.append(String(localized: "Deleted \(out.removed) item\(out.removed == 1 ? "" : "s") (\(ByteSize.format(out.bytes))) for good"))
        } else {
            parts.append(String(localized: "Nothing was deleted"))
        }
        if out.failed > 0 { parts.append(String(localized: "\(out.failed) couldn't be removed (locked, or not yours to remove)")) }
        if out.partly > 0 { parts.append(String(localized: "\(out.partly) partly deleted when you stopped; the rest is still in the Trash")) }
        if out.skipped > 0 { parts.append(String(localized: "\(out.skipped) left: changed since you confirmed, or stopped")) }
        return parts.joined(separator: " · ")
    }
}

extension View {
    /// The confirmation before the Trash is emptied, and what came of it,
    /// wherever in the window the user asked.
    func emptyTrashFlow(_ trash: TrashModel) -> some View {
        confirmationDialog(
            String(localized: "Empty the Trash?"),
            isPresented: Binding(get: { trash.confirming != nil }, set: { if !$0 { trash.confirming = nil } }),
            presenting: trash.confirming
        ) { listing in
            Button("Delete \(listing.count) Item\(listing.count == 1 ? "" : "s") for Good", role: .destructive) {
                Task { await trash.empty(listing) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { listing in
            Text(listing.partial
                ? String(localized: "\(listing.count) item\(listing.count == 1 ? "" : "s"), at least \(ByteSize.format(listing.bytes)) (part couldn't be measured), will be deleted for good. This can't be undone. Anything you move to the Trash after this stays there.")
                : String(localized: "\(listing.count) item\(listing.count == 1 ? "" : "s"), \(ByteSize.format(listing.bytes)), will be deleted for good. This can't be undone. Anything you move to the Trash after this stays there."))
        }
        .overlay(alignment: .bottom) {
            if let notice = trash.notice {
                DSUndoToast(text: notice, canUndo: false, undo: {}) { trash.notice = nil }
                    .padding(.bottom, DS.Space.lg)
            }
        }
        .animation(Motion.snappy, value: trash.notice)
    }
}
