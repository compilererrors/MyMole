import Foundation

/// One reading of the Mac: what it is, how busy it is, and how full. Rates
/// (CPU, disk, network) are measured since the previous reading.
public struct SystemSnapshot: Sendable, Equatable {
    public struct Hardware: Sendable, Equatable {
        /// "MacBook Pro (14-inch, 2023)", or the model identifier.
        public var model: String?
        /// "Apple M3 Pro".
        public var chip: String?
        public var memoryBytes: Int64?
        /// "macOS 26.1".
        public var osVersion: String

        public init(model: String?, chip: String?, memoryBytes: Int64?, osVersion: String) {
            self.model = model
            self.chip = chip
            self.memoryBytes = memoryBytes
            self.osVersion = osVersion
        }
    }

    public struct CPU: Sendable, Equatable {
        /// 0–100, across all cores.
        public var usage: Double
        public var perCore: [Double]
        public var load: (one: Double, five: Double, fifteen: Double)?
        public var performanceCores: Int?
        public var efficiencyCores: Int?

        public init(
            usage: Double, perCore: [Double], load: (one: Double, five: Double, fifteen: Double)?,
            performanceCores: Int? = nil, efficiencyCores: Int? = nil
        ) {
            self.usage = usage
            self.perCore = perCore
            self.load = load
            self.performanceCores = performanceCores
            self.efficiencyCores = efficiencyCores
        }

        public static func == (a: CPU, b: CPU) -> Bool {
            a.usage == b.usage && a.perCore == b.perCore && a.load?.one == b.load?.one && a.load?.five == b.load?.five
                && a.load?.fifteen == b.load?.fifteen && a.performanceCores == b.performanceCores
                && a.efficiencyCores == b.efficiencyCores
        }
    }

    public enum Pressure: Int, Sendable, Equatable {
        case normal, warning, critical
    }

    public struct Memory: Sendable, Equatable {
        /// What Activity Monitor calls Memory Used: app memory, wired and
        /// compressed.
        public var used: Int64
        public var total: Int64
        public var swapUsed: Int64
        public var swapTotal: Int64
        public var pressure: Pressure

        public init(used: Int64, total: Int64, swapUsed: Int64, swapTotal: Int64, pressure: Pressure) {
            self.used = used
            self.total = total
            self.swapUsed = swapUsed
            self.swapTotal = swapTotal
            self.pressure = pressure
        }

        public var usedPercent: Double { total > 0 ? min(100, Double(used) / Double(total) * 100) : 0 }
    }

    public struct Volume: Sendable, Equatable, Identifiable {
        public var name: String
        public var mount: String
        public var total: Int64
        /// Free space as Finder counts it, purgeable space included.
        public var available: Int64
        public var isInternal: Bool

        public init(name: String, mount: String, total: Int64, available: Int64, isInternal: Bool) {
            self.name = name
            self.mount = mount
            self.total = total
            self.available = available
            self.isInternal = isInternal
        }

        public var id: String { mount }
        public var used: Int64 { max(0, total - available) }
        public var usedPercent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
    }

    /// Bytes per second.
    public struct Throughput: Sendable, Equatable {
        public var read: Double
        public var write: Double

        public init(read: Double, write: Double) {
            self.read = read
            self.write = write
        }
    }

    public struct Interface: Sendable, Equatable, Identifiable {
        public var name: String
        public var address: String?
        /// Bytes per second.
        public var received: Double
        public var sent: Double

        public init(name: String, address: String?, received: Double, sent: Double) {
            self.name = name
            self.address = address
            self.received = received
            self.sent = sent
        }

        public var id: String { name }
    }

    public struct Battery: Sendable, Equatable {
        public var percent: Double
        public var charging: Bool
        public var onPower: Bool
        /// Minutes until empty, when macOS has an estimate.
        public var minutesLeft: Int?
        /// macOS's own verdict, e.g. "Good".
        public var health: String?
        public var cycleCount: Int?
        /// What a full charge holds now, as a share of the design capacity.
        public var capacityPercent: Double?

        public init(
            percent: Double, charging: Bool, onPower: Bool, minutesLeft: Int? = nil, health: String? = nil,
            cycleCount: Int? = nil, capacityPercent: Double? = nil
        ) {
            self.percent = percent
            self.charging = charging
            self.onPower = onPower
            self.minutesLeft = minutesLeft
            self.health = health
            self.cycleCount = cycleCount
            self.capacityPercent = capacityPercent
        }

        public var state: String {
            charging ? "Charging" : onPower ? "On power" : "On battery"
        }
    }

    public struct Process: Sendable, Equatable, Identifiable {
        public var pid: Int32
        public var name: String
        /// Percent of one core, so a busy multi-threaded app can pass 100.
        public var cpu: Double
        public var memoryBytes: Int64

        public init(pid: Int32, name: String, cpu: Double, memoryBytes: Int64) {
            self.pid = pid
            self.name = name
            self.cpu = cpu
            self.memoryBytes = memoryBytes
        }

        public var id: Int32 { pid }
    }

    public var date: Date
    public var hardware: Hardware
    public var uptime: TimeInterval?
    public var cpu: CPU?
    public var memory: Memory?
    public var volumes: [Volume]
    public var disk: Throughput?
    public var network: [Interface]
    public var battery: Battery?
    public var topProcesses: [Process]
    public var health: Health

    public init(
        date: Date, hardware: Hardware, uptime: TimeInterval?, cpu: CPU?, memory: Memory?, volumes: [Volume],
        disk: Throughput?, network: [Interface], battery: Battery?, topProcesses: [Process]
    ) {
        self.date = date
        self.hardware = hardware
        self.uptime = uptime
        self.cpu = cpu
        self.memory = memory
        self.volumes = volumes
        self.disk = disk
        self.network = network
        self.battery = battery
        self.topProcesses = topProcesses
        self.health = Health.assess(
            memory: memory, startup: volumes.first { $0.mount == "/" } ?? volumes.first, cpu: cpu, battery: battery)
    }

    /// The startup volume, or the first one listed.
    public var startupVolume: Volume? { volumes.first { $0.mount == "/" } ?? volumes.first }

    /// "3 days, 4 hours", "2 hours, 5 minutes".
    public static func uptimeText(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .full
        f.maximumUnitCount = 2
        return f.string(from: max(60, t)) ?? ""
    }
}

/// A 0–100 score with the reasons it isn't 100, worst first. MyMole's own
/// rule of thumb, meant to point at what's worth a look, not a diagnosis.
public struct Health: Sendable, Equatable {
    public struct Issue: Sendable, Equatable {
        public let penalty: Int
        public let text: String
    }

    public let score: Int
    public let issues: [Issue]

    public var summary: String { issues.first?.text ?? "Everything looks good" }

    public static func assess(
        memory: SystemSnapshot.Memory?, startup: SystemSnapshot.Volume?, cpu: SystemSnapshot.CPU?,
        battery: SystemSnapshot.Battery?
    ) -> Health {
        var issues: [Issue] = []
        if let v = startup, v.total > 0 {
            let p = Int(v.usedPercent.rounded())
            if p >= 95 {
                issues.append(Issue(penalty: 35, text: "The startup disk is almost full (\(p)%)"))
            } else if p >= 90 {
                issues.append(Issue(penalty: 25, text: "The startup disk is \(p)% full"))
            } else if p >= 80 {
                issues.append(Issue(penalty: 10, text: "The startup disk is \(p)% full"))
            }
        }
        if let m = memory {
            switch m.pressure {
            case .critical: issues.append(Issue(penalty: 30, text: "Memory is critically short"))
            case .warning: issues.append(Issue(penalty: 15, text: "Memory is under pressure"))
            case .normal: break
            }
            let gb: Int64 = 1_073_741_824
            if m.swapUsed >= 4 * gb {
                issues.append(Issue(penalty: 10, text: "Heavy swapping to disk (\(format(m.swapUsed)))"))
            } else if m.swapUsed >= gb {
                issues.append(Issue(penalty: 5, text: "Swapping to disk (\(format(m.swapUsed)))"))
            }
        }
        if let c = cpu, let load = c.load, !c.perCore.isEmpty, load.five / Double(c.perCore.count) >= 1.5 {
            issues.append(Issue(penalty: 10, text: "The CPU has been overloaded for minutes"))
        }
        if let b = battery {
            if let cap = b.capacityPercent, cap < 80 {
                issues.append(Issue(penalty: 10, text: "The battery holds \(Int(cap.rounded()))% of its original charge"))
            } else if let h = b.health, !h.isEmpty, h != "Good" {
                issues.append(Issue(penalty: 10, text: "macOS says the battery needs service"))
            }
        }
        issues.sort { $0.penalty > $1.penalty }
        return Health(score: max(0, 100 - issues.reduce(0) { $0 + $1.penalty }), issues: issues)
    }

    private static func format(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .memory) }
}
