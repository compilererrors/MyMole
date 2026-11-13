import Darwin
import Foundation
import IOKit
import IOKit.ps
import Synchronization

// The live readers: kernel counters through sysctl and Mach, volumes through
// Foundation, disks and the battery through IOKit, processes through ps.
// Each returns nil or empty when macOS won't say, so one missing value
// never blanks the pane.

extension SystemReaders {
    #if SMOKE
    public static let live = synthetic
    #else
    public static let live = SystemReaders(
        hardware: {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            let os = "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
            return SystemSnapshot.Hardware(
                model: Kernel.productName() ?? Kernel.string("hw.model"),
                chip: Kernel.string("machdep.cpu.brand_string"),
                memoryBytes: Kernel.value("hw.memsize", as: UInt64.self).map { Int64($0) }, osVersion: os,
                diskHealth: ProcessList.sandboxed ? nil : DiskHealth.startup())
        },
        uptime: {
            guard let boot = Kernel.value("kern.boottime", as: timeval.self) else { return nil }
            return Date().timeIntervalSince1970 - (TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1e6)
        },
        cores: { Kernel.cores() },
        load: {
            var l = [Double](repeating: 0, count: 3)
            return getloadavg(&l, 3) == 3 ? (l[0], l[1], l[2]) : nil
        },
        coreSplit: {
            (
                Kernel.value("hw.perflevel0.logicalcpu", as: Int32.self).map(Int.init),
                Kernel.value("hw.perflevel1.logicalcpu", as: Int32.self).map(Int.init)
            )
        },
        memory: { Kernel.memory() },
        volumes: { Volumes.mounted() },
        disk: { IORegistry.diskCounters() },
        interfaces: { Interfaces.read() },
        battery: { IORegistry.battery() },
        // The App Sandbox hides other processes' counters, so `ps` shows
        // nothing there; the tile stays away instead of running it in vain.
        // Every process: the list is small, and the Processes sheet draws only the rows in view.
        processes: { ProcessList.sandboxed ? [] : ProcessList.top(limit: .max) })
    #endif

    #if DEBUG || SMOKE
    public static let synthetic = SystemReaders(
        hardware: { .init(model: "Synthetic Mac", chip: "Synthetic CPU", memoryBytes: 16 << 30, osVersion: "macOS Test", diskHealth: "Verified") },
        uptime: { 7_200 }, cores: { [.init(user: 20, system: 10, idle: 70, nice: 0)] },
        load: { (0.5, 0.4, 0.3) }, coreSplit: { (2, 2) },
        memory: { .init(used: 4 << 30, total: 16 << 30, swapUsed: 0, swapTotal: 0, pressure: .normal) },
        volumes: { [.init(name: "Synthetic Disk", mount: "/", total: 100 << 30, available: 60 << 30, isInternal: true)] },
        disk: { .init(read: 100_000, written: 50_000) }, interfaces: { [] }, battery: { nil },
        processes: { [.init(pid: 2_147_483_000, name: "Synthetic Editor", cpu: 12, memoryBytes: 128 << 20),
                      .init(pid: 2_147_483_001, name: "Synthetic Player", cpu: 4, memoryBytes: 64 << 20)] })
    #endif
}

/// A C string buffer up to its terminating zero.
func text(_ buf: [CChar]) -> String {
    String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

enum Kernel {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let s = text(buf).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    static func value<T: BitwiseCopyable>(_ name: String, as: T.Type) -> T? {
        let p = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { p.deallocate() }
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, p, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return p.load(as: T.self)
    }

    /// "MacBook Pro (14-inch, 2023)" from the device tree, on Apple silicon.
    static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data
        else { return nil }
        let s = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    static func cores() -> [CoreTicks]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
            let info
        else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(count)).map { i in
            let b = i * Int(CPU_STATE_MAX)
            return CoreTicks(
                user: UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)]))
        }
    }

    static func memory() -> SystemSnapshot.Memory? {
        guard let total = value("hw.memsize", as: UInt64.self) else { return nil }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var page: vm_size_t = 0
        host_page_size(mach_host_self(), &page)
        let used = MemoryMath.used(
            anonymous: UInt64(stats.internal_page_count), purgeable: UInt64(stats.purgeable_count),
            wired: UInt64(stats.wire_count), compressed: UInt64(stats.compressor_page_count), pageSize: UInt64(page))
        let swap = value("vm.swapusage", as: xsw_usage.self)
        return SystemSnapshot.Memory(
            used: Int64(min(used, total)), total: Int64(total), swapUsed: Int64(swap?.xsu_used ?? 0),
            swapTotal: Int64(swap?.xsu_total ?? 0),
            pressure: MemoryMath.pressure(level: value("kern.memorystatus_vm_pressure_level", as: Int32.self) ?? 1))
    }
}

public enum MemoryMath {
    /// Activity Monitor's Memory Used: app memory (anonymous pages that
    /// can't simply be dropped), wired and compressed.
    public static func used(anonymous: UInt64, purgeable: UInt64, wired: UInt64, compressed: UInt64, pageSize: UInt64)
        -> UInt64
    {
        ((anonymous > purgeable ? anonymous - purgeable : 0) + wired + compressed) * pageSize
    }

    /// The kernel's pressure level: 1 normal, 2 warning, 4 critical.
    public static func pressure(level: Int32) -> SystemSnapshot.Pressure {
        level >= 4 ? .critical : level >= 2 ? .warning : .normal
    }
}

enum Volumes {
    static func mounted() -> [SystemSnapshot.Volume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeIsInternalKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), let total = v.volumeTotalCapacity, total > 0 else {
                return nil
            }
            let available = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            return SystemSnapshot.Volume(
                name: v.volumeName ?? url.lastPathComponent, mount: url.path, total: Int64(total), available: available,
                isInternal: v.volumeIsInternal ?? false)
        }
    }
}

enum Interfaces {
    static func read() -> [InterfaceReading] {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var counters: [String: (UInt32, UInt32)] = [:]
        var addresses: [String: String] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            let flags = Int32(ifa.ifa_flags)
            guard let addr = ifa.ifa_addr, flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                if let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                    counters[name] = (data.ifi_ibytes, data.ifi_obytes)
                }
            case AF_INET:
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses[name] = text(host)
                }
            default:
                break
            }
        }
        return counters.map { name, c in
            InterfaceReading(name: name, address: addresses[name], received: c.0, sent: c.1)
        }
    }
}

enum IORegistry {
    static func diskCounters() -> DiskCounters? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iter) }
        var read: UInt64 = 0
        var written: UInt64 = 0
        var service = IOIteratorNext(iter)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                written += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        return DiskCounters(read: read, written: written)
    }

    static func battery() -> SystemSnapshot.Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let minutes = d[kIOPSTimeToEmptyKey] as? Int
            var battery = SystemSnapshot.Battery(
                percent: Double(current) / Double(max) * 100, charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                onPower: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                minutesLeft: (minutes ?? -1) > 0 ? minutes : nil, health: d[kIOPSBatteryHealthKey] as? String)
            let smart = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if smart != 0 {
                defer { IOObjectRelease(smart) }
                func int(_ key: String) -> Int? {
                    (IORegistryEntryCreateCFProperty(smart, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                        as? NSNumber)?.intValue
                }
                battery.cycleCount = int("CycleCount")
                if let full = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity"), let design = int("DesignCapacity"),
                    design > 0
                {
                    battery.capacityPercent = min(100, Double(full) / Double(design) * 100)
                }
            }
            return battery
        }
        return nil
    }
}

public enum ProcessList {
    static let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// The busiest processes of every user, through `ps`: reading another
    /// user's process counters directly needs root.
    static func top(limit: Int = 8) -> [SystemSnapshot.Process] {
        guard let out = output("/bin/ps", ["-Aceo", "pid=,pcpu=,rss=,comm="], timeLimit: 5) else { return [] }
        return parse(out, limit: limit)
    }

    /// What a program prints, or nil when it can't start or runs past
    /// `timeLimit` seconds; a stuck one is stopped, so a reading never
    /// hangs the pane.
    static func output(_ executable: String, _ arguments: [String], timeLimit: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        // Decimal points, whatever the user's region.
        p.environment = ["LC_ALL": "C"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return nil }
        // Read while it runs, so a full pipe can't stall it.
        let data = Mutex(Data())
        let read = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: read) {
            let d = out.fileHandleForReading.readDataToEndOfFile()
            data.withLock { $0 = d }
        }
        guard exited.wait(timeout: .now() + timeLimit) == .success else {
            p.terminate()
            if exited.wait(timeout: .now() + 1) != .success { kill(p.processIdentifier, SIGKILL) }
            return nil
        }
        _ = read.wait(timeout: .now() + 1)
        return String(decoding: data.withLock { $0 }, as: UTF8.self)
    }

    /// `pid pcpu rss(KB) name` per line, busiest first. Names may hold spaces.
    public static func parse(_ output: String, limit: Int) -> [SystemSnapshot.Process] {
        let procs: [SystemSnapshot.Process] = output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rss = Int64(parts[2]) else {
                return nil
            }
            return SystemSnapshot.Process(pid: pid, name: String(parts[3]), cpu: cpu, memoryBytes: rss * 1024)
        }
        // The busiest, then the biggest not among them, so either order can be shown.
        let byCPU = procs.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.memoryBytes > $1.memoryBytes }.prefix(limit)
        let shown = Set(byCPU.map(\.pid))
        let byMemory = procs.filter { !shown.contains($0.pid) }.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(limit)
        return Array(byCPU) + Array(byMemory)
    }
}

/// The startup disk's SMART status, as `diskutil` reports it. Outside the
/// App Sandbox only: the sandbox doesn't let a program ask the disk service.
enum DiskHealth {
    static func startup() -> String? {
        guard let out = ProcessList.output("/usr/sbin/diskutil", ["info", "-plist", "/"], timeLimit: 5) else { return nil }
        return parse(out)
    }

    /// "Verified", "Failing" and the like; nil for a disk that doesn't say.
    static func parse(_ plist: String) -> String? {
        guard let d = (try? PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil)) as? [String: Any],
            let status = d["SMARTStatus"] as? String, !status.isEmpty, status != "Not Supported"
        else { return nil }
        return status
    }
}
