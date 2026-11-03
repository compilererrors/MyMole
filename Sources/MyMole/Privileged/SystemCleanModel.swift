import Foundation
import PrivilegedKit
import StorageKit
import SwiftUI

/// State of the System Clean pane: system-wide caches and logs found by the
/// app, what's chosen, the user's keep list and the last removal.
/// Removal is permanent, so nothing is chosen that isn't marked Safe or that
/// the keep list holds, and the list is read again right before each run.
@MainActor
@Observable
final class SystemCleanModel {
    private(set) var candidates: [SystemCandidate] = []
    private(set) var scanning = false
    private(set) var removing = false
    private(set) var scannedAt: Date?
    private(set) var error: String?
    /// The error as it stands now: a run whose outcome wasn't known stops
    /// being one once the tool is seen to have ended.
    var currentError: String? {
        error == PrivilegedClient.Failure.unknownText && !privileged.outcomeUnknown ? nil : error
    }
    private(set) var lastResult: String?
    /// Items the last removal couldn't delete, and why: a removal that
    /// stopped part-way says where what's left is now.
    private(set) var problems: [(path: String, reason: String)] = []

    func dismissProblems() { problems = [] }
    var chosen = Set<String>()
    var selection = Set<String>()
    private(set) var keepFile: KeepListFile
    var keep: CleanKeepList { keepFile.list }
    /// Set when the keep list couldn't be read: nothing is removed until it can.
    var keepError: String? { keepFile.readError }
    /// Set when the user's change to the list couldn't be saved: nothing is
    /// removed until it is, or the change is given up.
    var keepSaveError: String? { keepFile.saveError }

    let privileged: PrivilegedClient
    private let logURL: URL
    private let backend: Backend
    private var generation = 0
    private(set) var scanJob: Task<Void, Never>?
    private(set) var removeJob: Task<Void, Never>?

    /// How system items are found and removed; injected so tests never
    /// ask for a password.
    struct Backend {
        var isReady: @MainActor () -> Bool
        var scan: @MainActor () async throws -> [SystemCandidate]
        /// Removes `paths`; the tool refuses any the keep list protects.
        var remove: @MainActor (_ paths: [String], _ keep: CleanKeepList) async throws -> RemovalReport
        /// Why the tool can't be asked now, such as another system task.
        var blocker: @MainActor () -> String? = { nil }

        static func live(_ privileged: PrivilegedClient) -> Backend {
            Backend(
                isReady: { privileged.isAvailable }, scan: { try await privileged.scanSystem() },
                remove: { try await privileged.removeSystem($0, keep: $1) }, blocker: { privileged.blocker })
        }
    }

    init(
        privileged: PrivilegedClient, logURL: URL = CleanupLog.defaultURL, keepURL: URL = CleanKeepList.systemURL,
        backend: Backend? = nil
    ) {
        self.privileged = privileged
        self.logURL = logURL
        self.backend = backend ?? .live(privileged)
        keepFile = KeepListFile(url: keepURL)
    }

    var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
    var chosenCandidates: [SystemCandidate] { candidates.filter { chosen.contains($0.path) } }
    var chosenBytes: Int64 { chosenCandidates.reduce(0) { $0 + $1.bytes } }

    func scanIfNeeded() {
        guard backend.isReady(), !scanning, scannedAt == nil else { return }
        scan()
    }

    func scan() {
        guard backend.isReady(), !removing else { return }
        generation += 1
        let run = generation
        scanning = true
        error = nil
        scanJob = Task {
            do {
                let found = try await backend.scan()
                guard run == generation else { return }
                let first = scannedAt == nil
                candidates = found
                scannedAt = .now
                let paths = Set(found.map(\.path))
                chosen = first ? Set(found.filter(startsChosen).map(\.path)) : chosen.intersection(paths)
                selection.formIntersection(paths)
            } catch {
                guard run == generation else { return }
                self.error = error.localizedDescription
            }
            scanning = false
        }
    }

    func startsChosen(_ c: SystemCandidate) -> Bool { c.safety == .safe && !keep.protects(c.path) }

    func chooseSafe() { chosen = Set(candidates.filter(startsChosen).map(\.path)) }

    func choose(_ paths: some Sequence<String>) { chosen.formUnion(paths.filter { !keep.protects($0) }) }

    func toggle(_ path: String) {
        if chosen.contains(path) {
            chosen.remove(path)
        } else if !keep.protects(path) {
            chosen.insert(path)
        }
    }

    // MARK: Keep list

    /// Reads the keep list again, and saves a change still waiting.
    func reloadKeepList() { keepFile.reload() }

    /// Gives up a change to the keep list that couldn't be saved.
    func discardKeepChange() { keepFile.discardChange() }

    func keepAlways(_ paths: [String]) {
        changeKeep(keep: paths, stop: [])
        chosen = chosen.filter { !keep.protects($0) }
    }

    func stopKeeping(_ paths: [String]) {
        changeKeep(keep: [], stop: paths)
    }

    /// The list a running removal was checked against stays as it was:
    /// what's sent to the tool can't follow a later change.
    private func changeKeep(keep add: [String], stop remove: [String]) {
        guard !removing else {
            error = "Wait for the removal to finish before changing the keep list."
            return
        }
        keepFile.change(keep: add, stop: remove)
    }

    var removeBlocker: String? {
        if !backend.isReady() { return "System tasks aren't part of this edition." }
        if let why = keepFile.blocker { return why }
        if chosen.isEmpty { return "Choose at least one item." }
        if scanning { return "Wait for the scan to finish." }
        if removing { return "Removing…" }
        if let why = backend.blocker() { return why }
        return nil
    }

    func removeChosen() {
        guard removeBlocker == nil else { return }
        // The list as it is now, not as it was at the scan: a run never
        // goes ahead against a list that didn't load.
        keepFile.reload()
        if let why = keepFile.blocker {
            lastResult = "Nothing was removed: \(why.prefix(1).lowercased() + why.dropFirst())"
            return
        }
        // Held until the removal ends: another window or copy of MyMole
        // can't change the list while the prompt waits or the tool works,
        // and is told so instead of having its change ignored.
        let held: FileLock
        let fresh: CleanKeepList
        do {
            held = try FileLock(keepFile.url, wait: 0.5)
            fresh = try CleanKeepList.load(from: keepFile.url)
        } catch {
            lastResult = "Nothing was removed: the keep list couldn't be read (\(error.localizedDescription))."
            return
        }
        let all = chosenCandidates.map(\.path)
        let picked = all.filter { !fresh.protects($0) }
        let kept = all.count - picked.count
        chosen.subtract(all.filter(fresh.protects))
        guard !picked.isEmpty else {
            lastResult = "Nothing was removed: everything chosen is on your keep list."
            return
        }
        removing = true
        generation += 1
        removeJob = Task {
            defer { held.release() }
            do {
                let report = try await backend.remove(picked, fresh)
                problems = report.failed.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
                    + report.refused.map { ($0, "Refused by the rules.") }
                let gone = Set(report.removed)
                candidates.removeAll { gone.contains($0.path) }
                chosen.subtract(gone)
                var text = report.removed.isEmpty
                    ? "Nothing was removed"
                    : "Removed \(ByteCountFormatter.string(fromByteCount: report.bytes, countStyle: .file)) from \(report.removed.count) item\(report.removed.count == 1 ? "" : "s")"
                if !report.failed.isEmpty { text += " · \(report.failed.count) couldn't be removed" }
                if !report.refused.isEmpty { text += " · \(report.refused.count) refused by the rules" }
                if kept > 0 { text += " · \(kept) kept" }
                lastResult = text
                let record = CleanupRecord(
                    source: "System Clean", items: 0, bytes: report.bytes,
                    failed: report.failed.count + report.refused.count, deleted: report.removed.count)
                CleanupLog.submit(record, to: logURL)
            } catch {
                self.error = error.localizedDescription
            }
            removing = false
        }
    }
}
