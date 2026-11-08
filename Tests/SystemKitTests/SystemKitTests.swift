import Foundation
import Synchronization
import Testing

@testable import SystemKit

@Suite struct CounterMathTests {
    @Test func coreUsageIsTheBusyShare() {
        let a = CoreTicks(user: 100, system: 50, idle: 800, nice: 50)
        let b = CoreTicks(user: 160, system: 70, idle: 900, nice: 70)
        #expect(CoreTicks.usage(from: a, to: b) == 50)
        #expect(CoreTicks.usage(from: a, to: a) == 0)
    }

    @Test func coreUsageSurvivesWrappedCounters() {
        let a = CoreTicks(user: UInt32.max - 9, system: 0, idle: UInt32.max - 29, nice: 0)
        let b = CoreTicks(user: 10, system: 0, idle: 10, nice: 0)
        // 20 busy ticks and 40 idle ones across the wrap.
        #expect(abs(CoreTicks.usage(from: a, to: b) - 100.0 / 3) < 0.0001)
    }

    @Test func memoryUsedMatchesActivityMonitor() {
        #expect(MemoryMath.used(anonymous: 1_000, purgeable: 200, wired: 300, compressed: 100, pageSize: 16_384) == 1_200 * 16_384)
        #expect(MemoryMath.used(anonymous: 10, purgeable: 50, wired: 0, compressed: 0, pageSize: 4_096) == 0)
        #expect(MemoryMath.pressure(level: 1) == .normal)
        #expect(MemoryMath.pressure(level: 2) == .warning)
        #expect(MemoryMath.pressure(level: 4) == .critical)
    }

    @Test func parsesPsOutput() {
        let out = """
              1   0.3  13456 launchd
            812  45.5 204800 Code Helper (Renderer)
            90  120.0  51200 compiler
            bad line
            77   abc   100 nope
            """
        let top = ProcessList.parse(out, limit: 2)
        // The two busiest, then the biggest of the rest.
        #expect(top.map(\.name) == ["compiler", "Code Helper (Renderer)", "launchd"])
        #expect(top[1].memoryBytes == 204_800 * 1024)
        #expect(top[0].pid == 90)
        #expect(ProcessList.parse(out, limit: 10).count == 3)
    }

    @Test func aStuckProcessReadingIsStoppedAtItsTimeLimit() {
        let start = Date()
        #expect(ProcessList.output("/bin/sleep", ["30"], timeLimit: 0.3) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(ProcessList.output("/bin/echo", ["synthetic"], timeLimit: 10) == "synthetic\n")
    }

    @Test func uptimeReadsAsWords() {
        #expect(!SystemSnapshot.uptimeText(3 * 86_400 + 4 * 3_600).isEmpty)
        #expect(SystemSnapshot.uptimeText(3 * 86_400 + 4 * 3_600) != SystemSnapshot.uptimeText(2 * 3_600))
    }
}

@Suite struct HealthTests {
    private let gb: Int64 = 1_073_741_824

    private func volume(_ usedPercent: Int64) -> SystemSnapshot.Volume {
        SystemSnapshot.Volume(name: "Disk", mount: "/", total: 100 * gb, available: (100 - usedPercent) * gb, isInternal: true)
    }

    private func memory(_ pressure: SystemSnapshot.Pressure, swap: Int64 = 0) -> SystemSnapshot.Memory {
        SystemSnapshot.Memory(used: 8 * gb, total: 16 * gb, swapUsed: swap, swapTotal: 8 * gb, pressure: pressure)
    }

    @Test func aHealthyMacScoresFull() {
        let h = Health.assess(memory: memory(.normal), startup: volume(50), cpu: nil, battery: nil)
        #expect(h.score == 100)
        #expect(h.summary == "Everything looks good")
    }

    @Test func worstIssueComesFirst() {
        let cpu = SystemSnapshot.CPU(usage: 90, perCore: [90, 90], load: (4, 4, 4))
        let battery = SystemSnapshot.Battery(percent: 50, charging: false, onPower: false, capacityPercent: 72)
        let h = Health.assess(memory: memory(.warning, swap: 2 * gb), startup: volume(96), cpu: cpu, battery: battery)
        #expect(h.issues.map(\.penalty) == [35, 15, 10, 10, 5])
        #expect(h.score == 25)
        #expect(h.summary.hasPrefix("The startup disk is almost full"))
    }

    @Test func everyIssueAtOnce() {
        let cpu = SystemSnapshot.CPU(usage: 100, perCore: [100], load: (9, 9, 9))
        let battery = SystemSnapshot.Battery(percent: 5, charging: false, onPower: false, health: "Check Battery")
        let h = Health.assess(memory: memory(.critical, swap: 9 * gb), startup: volume(99), cpu: cpu, battery: battery)
        #expect(h.issues.count == 5)
        #expect(h.score == 5)
    }
}

@Suite struct SamplerTests {
    /// Counters that advance by a fixed step per reading.
    private final class Fake: Sendable {
        let step = Atomic<Int>(0)

        func readers() -> SystemReaders {
            SystemReaders(
                hardware: { .init(model: "Test Mac", chip: "Test Chip", memoryBytes: 16, osVersion: "macOS 99.0") },
                uptime: { 3_600 },
                cores: { [self] in
                    let n = UInt32(step.load(ordering: .relaxed))
                    // Core 0 is half busy, core 1 idle.
                    return [CoreTicks(user: n * 50, system: 0, idle: n * 50, nice: 0), CoreTicks(user: 0, system: 0, idle: n * 100, nice: 0)]
                },
                load: { (1, 1, 1) },
                coreSplit: { (1, 1) },
                memory: { .init(used: 1, total: 2, swapUsed: 0, swapTotal: 0, pressure: .normal) },
                volumes: { [.init(name: "Disk", mount: "/", total: 100, available: 40, isInternal: true)] },
                disk: { [self] in
                    let n = UInt64(step.load(ordering: .relaxed))
                    return DiskCounters(read: n * 2_000, written: n * 1_000)
                },
                interfaces: { [self] in
                    let n = UInt32(step.load(ordering: .relaxed))
                    return [
                        InterfaceReading(name: "en0", address: "192.0.2.10", received: n &* 4_000, sent: n &* 500),
                        InterfaceReading(name: "awdl0", address: nil, received: n, sent: n),
                    ]
                },
                battery: { nil },
                processes: { [.init(pid: 1, name: "proc", cpu: 1, memoryBytes: 1)] })
        }
    }

    @Test func ratesComeFromTheLastTwoReadings() {
        let fake = Fake()
        let sampler = SystemSampler(readers: fake.readers(), warmup: .zero)
        let times = Mutex<[Date]>([Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 2), Date(timeIntervalSince1970: 4)])
        let clock: @Sendable () -> Date = {
            fake.step.add(1, ordering: .relaxed)
            return times.withLock { $0.removeFirst() }
        }
        let first = sampler.sample(clock: clock)
        #expect(first.cpu?.perCore == [50, 0])
        #expect(first.cpu?.usage == 25)
        #expect(first.disk == SystemSnapshot.Throughput(read: 1_000, write: 500))
        #expect(first.network.map(\.name) == ["en0"])
        #expect(first.network.first?.received == 2_000)
        #expect(first.startupVolume?.usedPercent == 60)
        #expect(first.hardware.model == "Test Mac")

        let second = sampler.sample(clock: clock)
        #expect(second.date == Date(timeIntervalSince1970: 4))
        #expect(second.cpu?.perCore == [50, 0])
        #expect(second.network.first?.sent == 250)
    }

    @Test func liveReadersAnswer() {
        // Reads only kernel counters and process names, never files.
        let s = SystemSampler(warmup: .milliseconds(100)).sample()
        #expect(s.cpu.map { $0.usage >= 0 && $0.usage <= 100 } ?? false)
        #expect((s.memory?.total ?? 0) > 0)
        #expect(s.volumes.contains { $0.mount == "/" })
        #expect(!s.hardware.osVersion.isEmpty)
    }
}

@Suite struct DiskHealthTests {
    @Test func readsTheStatusAndLeavesOutADiskThatDoesntSay() {
        let plist = { (status: String) in
            "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>SMARTStatus</key><string>\(status)</string></dict></plist>"
        }
        #expect(DiskHealth.parse(plist("Verified")) == "Verified")
        #expect(DiskHealth.parse(plist("Not Supported")) == nil)
        #expect(DiskHealth.parse("not a property list") == nil)
    }

    @Test func aFailingDiskWeighsMostInTheScore() {
        let failing = Health.assess(memory: nil, startup: nil, cpu: nil, battery: nil, diskHealth: "Failing")
        #expect(failing.score == 60 && failing.summary.hasPrefix("The startup disk reports"))
        #expect(Health.assess(memory: nil, startup: nil, cpu: nil, battery: nil, diskHealth: "Verified").score == 100)
    }
}

@Suite struct HealthUnknownTests {
    @Test func whatCouldntBeReadIsNeverCalledGood() {
        let h = Health.assess(memory: nil, startup: nil, cpu: nil, battery: nil)
        #expect(h.unknown == ["memory", "the startup disk"])
        #expect(h.scoreText == "—" && h.summary.hasPrefix("Couldn't read"))
        #expect(h.summary != "Everything looks good")
    }
}

@Suite struct ProcessOrderTests {
    @Test func theBusiestAndTheBiggestAreBothKept() {
        let out = """
            1 90.0 1000 Busy
            2 50.0 2000 Middle
            3 0.1 9000000 Big
            4 0.0 10 Idle
            """
        let ps = ProcessList.parse(out, limit: 2)
        #expect(ps.map(\.name) == ["Busy", "Middle", "Big", "Idle"])
        let top = ProcessList.parse(out, limit: 1)
        #expect(Set(top.map(\.name)) == ["Busy", "Big"])
    }
}
