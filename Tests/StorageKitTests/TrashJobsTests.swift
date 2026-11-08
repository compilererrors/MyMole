import Darwin
import Foundation
import Testing

@testable import StorageKit

/// The plan a destructive job carries out, and the queue that runs one job
/// at a time.
@Suite struct TrashPlanTests {
    @Test func aPlanSaysWhatBecameOfEachItem() throws {
        let box = try Sandbox()
        let a = try box.file("cache/a", bytes: 10).path
        let kept = try box.file("cache/kept", bytes: 10).path
        let gate = TrashGate(still: { _ in true }, protections: { { $0 == kept } })
        var plan = Trasher.plan([a, kept, box.path + "/cache/../x"], through: gate)
        Trasher.run(&plan, through: gate, backend: try testBin(box))
        #expect(plan.isFinished)
        #expect(plan.action == .moveToTrash && plan.policyVersion == TrashPlan.policyVersion)
        guard case .done(let to?) = plan.items[0].status else { Issue.record("not moved"); return }
        #expect(to.path.hasPrefix(box.path + "/Bin/"))
        #expect(plan.items[1].status == .refused("Kept"))
        #expect(plan.items[2].status == .refused("Not a plain full path"))
        // The report lists the refusals of the check first, then the run.
        #expect(plan.outcome.failed.map(\.reason) == ["Kept", "Not a plain full path"])
        #expect(plan.outcome.moved.map(\.original.path) == [a])
    }

    @Test func anItemWhoseFolderWasSwappedAfterTheCheckStays() throws {
        let box = try Sandbox()
        let a = try box.file("cache/a", bytes: 10).path
        let gate = TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing)
        var plan = Trasher.plan([a], through: gate)
        // The same file, now in another folder of the same name.
        #expect(rename(box.path + "/cache", box.path + "/old") == 0)
        try box.folder("cache")
        #expect(link(box.path + "/old/a", a) == 0)
        Trasher.run(&plan, through: gate, backend: try testBin(box))
        #expect(plan.items[0].status == .refused("Changed since it was checked"))
        #expect(FileManager.default.fileExists(atPath: a))
        #expect(FileManager.default.fileExists(atPath: box.path + "/old/a"))
    }

    @Test func aPlanCheckedUnderOtherRulesIsNeverCarriedOut() throws {
        let box = try Sandbox()
        let a = try box.file("a", bytes: 10).path
        let gate = TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing)
        var plan = Trasher.plan([a], through: gate, policyVersion: TrashPlan.policyVersion - 1)
        Trasher.run(&plan, through: gate, backend: try testBin(box))
        #expect(plan.outcome.moved.isEmpty && plan.outcome.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: a))
    }

    @Test func aRemovalElsewhereIsRecordedAsForGood() {
        let job = TrashJob(action: .deleteForGood)
        job.record(.deleteForGood, done: ["/Library/Caches/x"], failed: ["/Library/Caches/y": "Busy"], refused: ["/Library/z"])
        let plan = job.plans[0]
        #expect(!plan.action.isReversible)
        #expect(plan.items.map(\.status) == [.done(nil), .failed("Busy"), .refused("Refused by the rules.")])
        #expect(plan.job == job.id)
    }
}

@Suite struct TrashJobsTests {
    @Test func aStoppedJobLeavesTheRestAndSaysSo() async throws {
        let box = try Sandbox()
        let a = try box.file("cache/a", bytes: 10).path
        let b = try box.file("cache/b", bytes: 10).path
        let bin = try testBin(box)
        let jobs = TrashJobs()
        let job = await jobs.begin(.moveToTrash)
        // Stopped while the first item is checked right before its move (the
        // plan asks first): it still goes, the next doesn't.
        let asked = Counter()
        let gate = TrashGate(still: { p in
            if p == a, asked.next() == 2 { jobs.stop() }
            return true
        }, protections: TrashGate.keepsNothing)
        let out = job.moveToTrash([a, b], through: gate, backend: bin)
        jobs.end(job)
        #expect(out.moved.map(\.original.path) == [a])
        #expect(out.failed.map(\.path) == [b] && out.failed.first?.reason == TrashPlan.stoppedReason)
        #expect(FileManager.default.fileExists(atPath: b))
        #expect(job.plans.first?.items.last?.status == .cancelled)
        #expect(!jobs.isBusy)
    }

    @Test func jobsNeverOverlap() async {
        let jobs = TrashJobs()
        let state = Shared((active: 0, most: 0, ran: 0))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await jobs.perform(.moveToTrash) { _ in
                        state.withLock { $0.active += 1; $0.most = max($0.most, $0.active) }
                        usleep(20_000)
                        state.withLock { $0.active -= 1; $0.ran += 1 }
                    }
                }
            }
        }
        let s = state.withLock { $0 }
        #expect(s.most == 1 && s.ran == 6)
        #expect(!jobs.isBusy)
    }

    @Test func anUndoWaitsForTheMoveBeforeIt() async throws {
        let box = try Sandbox()
        let a = try box.file("a", bytes: 10).path
        let bin = try testBin(box)
        let jobs = TrashJobs()
        let move = await jobs.begin(.moveToTrash)
        let records = move.moveToTrash([a], through: TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing), backend: bin).moved
        let undone = Shared(false)
        let undo = Task {
            let failed = await jobs.perform(.putBack) { $0.putBack(records) }
            undone.withLock { $0 = true }
            return failed
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!undone.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: a))
        jobs.end(move)
        #expect(await undo.value.isEmpty)
        #expect(FileManager.default.fileExists(atPath: a))
    }

    @Test func aStopReachesTheJobsWaitingAndAPutBackStillRuns() async throws {
        let box = try Sandbox()
        let a = try box.file("a", bytes: 10).path
        let b = try box.file("b", bytes: 10).path
        let bin = try testBin(box)
        let jobs = TrashJobs()
        let first = await jobs.begin(.moveToTrash)
        let records = first.moveToTrash([a], through: TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing), backend: bin).moved
        let waitingMove = Task {
            await jobs.perform(.moveToTrash) { $0.moveToTrash([b], through: TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing), backend: bin) }
        }
        let waitingUndo = Task { await jobs.perform(.putBack) { $0.putBack(records) } }
        try await Task.sleep(for: .milliseconds(150))
        jobs.stop()
        jobs.end(first)
        let out = await waitingMove.value
        #expect(out.moved.isEmpty && out.failed.first?.reason == TrashPlan.stoppedReason)
        #expect(FileManager.default.fileExists(atPath: b))
        #expect(await waitingUndo.value.isEmpty)
        #expect(FileManager.default.fileExists(atPath: a))
        await jobs.idle()
        #expect(!jobs.isBusy)
    }

    @Test func aPutBackIsAStepOfItsJob() async throws {
        let box = try Sandbox()
        let a = try box.file("a", bytes: 10).path
        let bin = try testBin(box)
        let jobs = TrashJobs()
        let moved = await jobs.perform(.moveToTrash) { $0.moveToTrash([a], through: TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing), backend: bin).moved }
        // Something new where it was: never overwritten, and said so.
        FileManager.default.createFile(atPath: a, contents: Data("new".utf8))
        let job = await jobs.begin(.putBack)
        let failed = job.putBack(moved)
        jobs.end(job)
        #expect(failed == moved)
        #expect(job.plans.first?.action == .putBack)
        #expect(job.plans.first?.items.first?.status == .failed("Couldn't be put back"))
        #expect(String(decoding: FileManager.default.contents(atPath: a) ?? Data(), as: UTF8.self) == "new")
    }
}

/// A value several tasks change, one at a time.
final class Shared<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&value) } }
}
