import Darwin
import Foundation
import Synchronization

/// What a destructive job does to its items.
public enum TrashAction: String, Sendable {
    /// To the Trash; Undo or Finder's Put Back brings it back.
    case moveToTrash
    /// Back from the Trash to where it was.
    case putBack
    /// Gone for good, as the privileged tool removes system items.
    case deleteForGood

    public var isReversible: Bool { self != .deleteForGood }
}

/// One step of a destructive job, as approved and as carried out: the paths
/// that were handed over, each with the identity of the item and of the
/// folder holding it at that moment, the version of the rules it was
/// checked under, and what became of each. What a pane reports after a run
/// is read from this plan, so it says what was really done.
public struct TrashPlan: Sendable, Identifiable {
    /// Raised when the checks a plan relies on change meaning, so a plan
    /// made under other rules is never carried out.
    public static let policyVersion = 2

    public struct Item: Sendable, Equatable {
        public enum Status: Sendable, Equatable {
            case waiting
            /// Done; for a move, where the item went.
            case done(URL?)
            /// The checks kept it, before or during the run.
            case refused(String)
            case failed(String)
            /// The job was stopped before this item's turn.
            case cancelled
        }

        public let path: String
        let identity: Trasher.Identity?
        let parent: Trasher.Identity?
        public internal(set) var status: Status
    }

    public let id: UUID
    /// The job this step belongs to.
    public let job: UUID
    public let action: TrashAction
    public let policyVersion: Int
    public internal(set) var items: [Item]
    /// Items in the order they reached their status, so a report lists the
    /// refusals of the check first and then the run as it went.
    var order: [Int] = []

    init(job: UUID, action: TrashAction, paths: [String], policyVersion: Int = TrashPlan.policyVersion) {
        id = UUID()
        self.job = job
        self.action = action
        self.policyVersion = policyVersion
        items = paths.map { Item(path: $0, identity: nil, parent: nil, status: .waiting) }
    }

    mutating func set(_ i: Int, _ status: Item.Status) {
        guard items[i].status == .waiting else { return }
        items[i].status = status
        order.append(i)
    }

    public var isFinished: Bool { !items.contains { $0.status == .waiting } }
    public var waiting: [String] { items.filter { $0.status == .waiting }.map(\.path) }

    /// Reason given for an item stopped before its turn.
    public static let stoppedReason = "Stopped before it was moved."

    /// The plan as the flows have always read a move: what went where, and
    /// why each of the others stayed.
    public var outcome: TrashOutcome {
        var moved: [TrashRecord] = []
        var failed: [(path: String, reason: String)] = []
        for i in order {
            let item = items[i]
            switch item.status {
            case .done(let to):
                if let to { moved.append(TrashRecord(original: URL(fileURLWithPath: item.path), trashed: to)) }
            case .refused(let why), .failed(let why): failed.append((item.path, why))
            case .cancelled: failed.append((item.path, Self.stoppedReason))
            case .waiting: break
            }
        }
        return TrashOutcome(moved: moved, failed: failed)
    }
}

extension Trasher {
    /// The plan for moving `paths`: each cleared through the gate, and the
    /// identity of each item allowed and of its folder taken now, so the run
    /// can tell when either was swapped since.
    static func plan(_ paths: [String], through gate: TrashGate, job: UUID = UUID(), policyVersion: Int = TrashPlan.policyVersion) -> TrashPlan {
        var plan = TrashPlan(job: job, action: .moveToTrash, paths: paths, policyVersion: policyVersion)
        let (allowed, refused) = clear(paths, through: gate)
        let refusedWhy = Dictionary(refused.map { ($0.path, $0.reason) }, uniquingKeysWith: { a, _ in a })
        let allowedSet = Set(allowed)
        for i in plan.items.indices {
            let path = plan.items[i].path
            if let why = refusedWhy[path], !allowedSet.contains(path) {
                plan.set(i, .refused(why))
            } else {
                plan.items[i] = TrashPlan.Item(
                    path: path, identity: identity(of: path),
                    parent: identity(of: (path as NSString).deletingLastPathComponent), status: .waiting)
            }
        }
        return plan
    }

    /// Carries out a move plan. Each item is checked again right before it
    /// moves: still the same file in the same folder as when the plan was
    /// made, still meeting the flow's rule, and not kept by the protections,
    /// which are read again as the run goes on. Protections that stop
    /// reading stop the rest, and so does `stop`, checked before each item.
    static func run(_ plan: inout TrashPlan, through gate: TrashGate, backend: TrashBackend, stop: () -> Bool = { false }) {
        guard plan.action == .moveToTrash else { return }
        guard plan.policyVersion == TrashPlan.policyVersion else {
            for i in plan.items.indices { plan.set(i, .refused("Checked under other rules; check again.")) }
            return
        }
        var keeps: @Sendable (String) -> Bool
        do {
            keeps = try gate.protections()
        } catch {
            for i in plan.items.indices { plan.set(i, .refused(protectionsUnreadable)) }
            return
        }
        var readAt = Date()
        for i in plan.items.indices where plan.items[i].status == .waiting {
            if stop() {
                for j in plan.items.indices[i...] { plan.set(j, .cancelled) }
                return
            }
            if Date().timeIntervalSince(readAt) > refreshProtections {
                do {
                    keeps = try gate.protections()
                    readAt = Date()
                } catch {
                    for j in plan.items.indices[i...] { plan.set(j, .refused("Your protections couldn't be read, so it wasn't moved.")) }
                    return
                }
            }
            let item = plan.items[i]
            if item.identity == nil || identity(of: item.path) != item.identity
                || identity(of: (item.path as NSString).deletingLastPathComponent) != item.parent {
                plan.set(i, .refused("Changed since it was checked"))
            } else if keeps(item.path) {
                plan.set(i, .refused("Kept"))
            } else if !gate.still(item.path) {
                plan.set(i, .refused("Changed since it was checked"))
            } else if isProtectedResolved(item.path) {
                plan.set(i, .refused("Protected location"))
            } else {
                let r = backend.moveOne(item.path)
                plan.set(i, r.trashed.map { .done($0) } ?? .failed(r.error ?? "Not moved"))
            }
        }
    }
}

/// One destructive job: a single approval of the user's, however many
/// steps it takes. Every file operation of the job goes through it, so each
/// step is recorded as a plan and a stop reaches the next item.
public final class TrashJob: Sendable {
    public let id = UUID()
    public let action: TrashAction
    private let state = Mutex(State())

    private struct State {
        var stopped = false
        var plans: [TrashPlan] = []
    }

    init(action: TrashAction) { self.action = action }

    public var isStopped: Bool { state.withLock { $0.stopped } }
    /// The steps so far, as carried out.
    public var plans: [TrashPlan] { state.withLock { $0.plans } }

    func stop() { state.withLock { $0.stopped = true } }

    /// Moves `paths` to the Trash through the gate, as one step of the job.
    public func moveToTrash(_ paths: [String], through gate: TrashGate, backend: TrashBackend = .system) -> TrashOutcome {
        var plan = Trasher.plan(paths, through: gate, job: id)
        if isStopped {
            for i in plan.items.indices { plan.set(i, .cancelled) }
        } else {
            Trasher.run(&plan, through: gate, backend: backend, stop: { self.isStopped })
        }
        state.withLock { $0.plans.append(plan) }
        return plan.outcome
    }

    /// Puts trashed items back, as one step of the job. A put-back is never
    /// stopped half-way: what was asked back is tried in full.
    public func putBack(_ records: [TrashRecord]) -> [TrashRecord] {
        var plan = TrashPlan(job: id, action: .putBack, paths: records.reversed().map(\.original.path))
        var failed: [TrashRecord] = []
        for (i, r) in records.reversed().enumerated() {
            if Trasher.restore(r) {
                plan.set(i, .done(r.original))
            } else {
                plan.set(i, .failed("Couldn't be put back"))
                failed.append(r)
            }
        }
        state.withLock { $0.plans.append(plan) }
        return failed
    }

    /// Notes what a step done elsewhere, such as by the privileged tool,
    /// did to each path.
    public func record(_ action: TrashAction, done: [String], failed: [String: String], refused: [String]) {
        var plan = TrashPlan(job: id, action: action, paths: done + failed.keys.sorted() + refused)
        for i in plan.items.indices {
            let p = plan.items[i].path
            if i < done.count { plan.set(i, .done(nil)) } else if let why = failed[p] { plan.set(i, .failed(why)) } else { plan.set(i, .refused("Refused by the rules.")) }
        }
        state.withLock { $0.plans.append(plan) }
    }
}

/// Runs destructive jobs one at a time, whichever pane asks, in the order
/// they asked: a move, an Undo and a system removal never overlap, so no
/// two jobs act on the same files at once and an Undo waits for the move
/// before it. A job holds its turn from `begin` to `end`; `stop` asks the
/// running job and those waiting to leave the rest of their items alone.
/// Nothing of a job is written to disk: the history keeps counts only.
public final class TrashJobs: Sendable {
    public static let shared = TrashJobs()

    private let state = Mutex(State())

    private struct State {
        var running: TrashJob?
        var queue: [(job: TrashJob, resume: CheckedContinuation<Void, Never>)] = []
    }

    public init() {}

    /// Waits for the job's turn, then holds it until `end`.
    public func begin(_ action: TrashAction) async -> TrashJob {
        let job = TrashJob(action: action)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = state.withLock { s -> Bool in
                if s.running == nil {
                    s.running = job
                    return true
                }
                s.queue.append((job, c))
                return false
            }
            if now { c.resume() }
        }
        return job
    }

    /// Gives the turn to the next job waiting.
    public func end(_ job: TrashJob) {
        let next = state.withLock { s -> CheckedContinuation<Void, Never>? in
            guard s.running === job else {
                s.queue.removeAll { $0.job === job }
                return nil
            }
            guard !s.queue.isEmpty else {
                s.running = nil
                return nil
            }
            let (j, c) = s.queue.removeFirst()
            s.running = j
            return c
        }
        next?.resume()
    }

    /// Runs `body` in a turn of its own, off the main thread.
    public func perform<T: Sendable>(_ action: TrashAction, _ body: @escaping @Sendable (TrashJob) -> T) async -> T {
        let job = await begin(action)
        defer { end(job) }
        return await Task.detached(priority: .userInitiated) { body(job) }.value
    }

    /// The job holding the turn now.
    public var running: TrashJob? { state.withLock { $0.running } }
    /// Whether a job holds the turn or waits for one.
    public var isBusy: Bool { state.withLock { $0.running != nil || !$0.queue.isEmpty } }

    /// How many jobs wait their turn behind the running one.
    public var waiting: Int { state.withLock { $0.queue.count } }

    /// Asks the running job and every waiting one to stop before their next
    /// item. A put-back already asked for still runs in full.
    public func stop() {
        let jobs = state.withLock { s in (s.running.map { [$0] } ?? []) + s.queue.map(\.job) }
        for j in jobs { j.stop() }
    }

    /// Returns once every job that held or waited for a turn has ended.
    public func idle() async {
        let job = await begin(.putBack)
        end(job)
    }
}
