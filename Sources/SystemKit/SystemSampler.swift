import Foundation
import Synchronization

/// One core's tick counters since boot.
public struct CoreTicks: Sendable, Equatable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// Busy share between two readings, 0–100. The counters are 32-bit and
    /// wrap, so the differences use wrapping arithmetic.
    public static func usage(from a: CoreTicks, to b: CoreTicks) -> Double {
        let busy = Double((b.user &- a.user) &+ (b.system &- a.system) &+ (b.nice &- a.nice))
        let total = busy + Double(b.idle &- a.idle)
        return total > 0 ? busy / total * 100 : 0
    }
}

/// Bytes read and written by every disk since boot.
public struct DiskCounters: Sendable, Equatable {
    public var read: UInt64
    public var written: UInt64

    public init(read: UInt64, written: UInt64) {
        self.read = read
        self.written = written
    }
}

/// A network interface's counters and address at one moment.
public struct InterfaceReading: Sendable, Equatable {
    public var name: String
    public var address: String?
    /// Received and sent; macOS keeps them as 32-bit counters per interface.
    public var received: UInt32
    public var sent: UInt32

    public init(name: String, address: String?, received: UInt32, sent: UInt32) {
        self.name = name
        self.address = address
        self.received = received
        self.sent = sent
    }
}

/// Where each part of a reading comes from. `live` asks macOS; tests pass
/// fixed values.
public struct SystemReaders: Sendable {
    public var hardware: @Sendable () -> SystemSnapshot.Hardware
    public var uptime: @Sendable () -> TimeInterval?
    public var cores: @Sendable () -> [CoreTicks]?
    public var load: @Sendable () -> (one: Double, five: Double, fifteen: Double)?
    public var coreSplit: @Sendable () -> (performance: Int?, efficiency: Int?)
    public var memory: @Sendable () -> SystemSnapshot.Memory?
    public var volumes: @Sendable () -> [SystemSnapshot.Volume]
    public var disk: @Sendable () -> DiskCounters?
    public var interfaces: @Sendable () -> [InterfaceReading]
    public var battery: @Sendable () -> SystemSnapshot.Battery?
    public var processes: @Sendable () -> [SystemSnapshot.Process]

    public init(
        hardware: @escaping @Sendable () -> SystemSnapshot.Hardware,
        uptime: @escaping @Sendable () -> TimeInterval?,
        cores: @escaping @Sendable () -> [CoreTicks]?,
        load: @escaping @Sendable () -> (one: Double, five: Double, fifteen: Double)?,
        coreSplit: @escaping @Sendable () -> (performance: Int?, efficiency: Int?),
        memory: @escaping @Sendable () -> SystemSnapshot.Memory?,
        volumes: @escaping @Sendable () -> [SystemSnapshot.Volume],
        disk: @escaping @Sendable () -> DiskCounters?,
        interfaces: @escaping @Sendable () -> [InterfaceReading],
        battery: @escaping @Sendable () -> SystemSnapshot.Battery?,
        processes: @escaping @Sendable () -> [SystemSnapshot.Process]
    ) {
        self.hardware = hardware
        self.uptime = uptime
        self.cores = cores
        self.load = load
        self.coreSplit = coreSplit
        self.memory = memory
        self.volumes = volumes
        self.disk = disk
        self.interfaces = interfaces
        self.battery = battery
        self.processes = processes
    }
}

/// Takes readings of the Mac. Rates need two readings, so the sampler keeps
/// the previous counters; the very first call takes a short baseline first.
/// Calls are serialized, so two panes asking at once don't mix counters.
public final class SystemSampler: Sendable {
    private struct Previous {
        var at: Date
        var cores: [CoreTicks]
        var disk: DiskCounters?
        var interfaces: [String: InterfaceReading]
    }

    private struct State {
        var previous: Previous?
        var hardware: SystemSnapshot.Hardware?
    }

    private let state = Mutex(State())
    private let readers: SystemReaders
    private let warmup: Duration

    public init(readers: SystemReaders = .live, warmup: Duration = .milliseconds(400)) {
        self.readers = readers
        self.warmup = warmup
    }

    /// Blocks for the warm-up on the first call; run it off the main thread.
    public func sample(clock: @Sendable () -> Date = { Date() }) -> SystemSnapshot {
        state.withLock { s in
            if s.previous == nil {
                s.previous = counters(at: clock())
                if warmup > .zero { Thread.sleep(forTimeInterval: warmup / .seconds(1)) }
            }
            let hardware = s.hardware ?? readers.hardware()
            s.hardware = hardware
            let now = counters(at: clock())
            let prev = s.previous!
            s.previous = now
            let seconds = max(0.001, now.at.timeIntervalSince(prev.at))

            var cpu: SystemSnapshot.CPU?
            if !now.cores.isEmpty {
                let perCore =
                    now.cores.count == prev.cores.count
                    ? zip(prev.cores, now.cores).map { CoreTicks.usage(from: $0, to: $1) }
                    : now.cores.map { CoreTicks.usage(from: CoreTicks(user: 0, system: 0, idle: 0, nice: 0), to: $0) }
                let split = readers.coreSplit()
                cpu = SystemSnapshot.CPU(
                    usage: perCore.reduce(0, +) / Double(perCore.count), perCore: perCore, load: readers.load(),
                    performanceCores: split.performance, efficiencyCores: split.efficiency)
            }

            var disk: SystemSnapshot.Throughput?
            if let a = prev.disk, let b = now.disk {
                // A disk detached in between can make a total go down.
                disk = SystemSnapshot.Throughput(
                    read: b.read >= a.read ? Double(b.read - a.read) / seconds : 0,
                    write: b.written >= a.written ? Double(b.written - a.written) / seconds : 0)
            }

            let network = now.interfaces.values
                .filter { $0.address != nil }
                .sorted { $0.name < $1.name }
                .map { i in
                    let old = prev.interfaces[i.name]
                    return SystemSnapshot.Interface(
                        name: i.name, address: i.address,
                        received: old.map { Double(i.received &- $0.received) / seconds } ?? 0,
                        sent: old.map { Double(i.sent &- $0.sent) / seconds } ?? 0)
                }

            return SystemSnapshot(
                date: now.at, hardware: hardware, uptime: readers.uptime(), cpu: cpu, memory: readers.memory(),
                volumes: readers.volumes(), disk: disk, network: network, battery: readers.battery(),
                topProcesses: readers.processes())
        }
    }

    private func counters(at date: Date) -> Previous {
        Previous(
            at: date, cores: readers.cores() ?? [], disk: readers.disk(),
            interfaces: Dictionary(readers.interfaces().map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }))
    }
}
