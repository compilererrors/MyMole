import StorageKit
import SwiftUI
import SystemKit

/// Live readings of the Mac (`SystemKit`), taken every 2 seconds while the
/// pane is visible.
struct StatusView: View {
    let app: AppModel

    /// A reading costs a few milliseconds, so the pane can stay close to live
    /// without the monitor itself showing up as load.
    static let interval: Duration = .seconds(2)

    var body: some View {
        VStack(spacing: 0) {
        if let s = app.status {
            DSPaneHeader {
                DSMetric(String(s.health.score), "health · \(s.health.summary)")
            } actions: {
                EmptyView()
            } strip: {
                DSCapsule("Live, every 2 s", tint: Theme.accent, live: true)
                if let m = s.hardware.model { DSCapsule(m, symbol: "laptopcomputer") }
                DSCapsule(s.hardware.osVersion, symbol: "apple.logo")
                if let up = s.uptime { DSCapsule("Up \(SystemSnapshot.uptimeText(up))", symbol: "clock") }
            }
            Divider()
        }
        DSPage(width: .full) {
            if let s = app.status {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: Theme.gap)], spacing: Theme.gap) {
                    cards(s)
                }
                .animation(.default, value: s.cpu?.usage)
            } else {
                DSLoading("Reading your Mac's status…").padding(60)
            }
        }
        }
        .paneToolbar("Live Status", subtitle: meta)
        .task {
            while !Task.isCancelled {
                await app.refreshStatus()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private var meta: String {
        guard let s = app.status else { return "Collecting…" }
        return [s.hardware.model, s.hardware.chip, s.hardware.osVersion, s.uptime.map { "up \(SystemSnapshot.uptimeText($0))" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private func cards(_ s: SystemSnapshot) -> some View {
        StatTile(caption: "Health") {
            Metric(String(s.health.score))
            if s.health.issues.isEmpty {
                Text(s.health.summary).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(s.health.issues, id: \.text) { i in
                    Text(i.text).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let cpu = s.cpu {
            StatTile(caption: "CPU") {
                big(cpu.usage)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(cpu.perCore.enumerated()), id: \.offset) { _, c in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.load(c))
                            .frame(height: max(3, 40 * min(c, 100) / 100))
                    }
                }
                .frame(height: 40, alignment: .bottom)
                if let l = cpu.load {
                    Text(String(format: "load %.2f · %.2f · %.2f", l.one, l.five, l.fifteen))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let p = cpu.performanceCores, let e = cpu.efficiencyCores {
                    Text("\(p) performance · \(e) efficiency cores").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let m = s.memory {
            StatTile(caption: "Memory") {
                big(m.usedPercent)
                UsageBar(fraction: m.usedPercent / 100)
                kv("\(fmt(m.used)) / \(fmt(m.total))", "swap \(fmt(m.swapUsed))")
                if m.pressure != .normal {
                    kv("Pressure", m.pressure == .critical ? "critical" : "high")
                }
            }
        }
        ForEach(s.volumes.filter(\.isInternal).prefix(3)) { v in
            StatTile(caption: v.mount == "/" ? "Startup disk" : "Disk \(v.name)") {
                big(v.usedPercent)
                UsageBar(fraction: v.usedPercent / 100)
                kv("\(fmt(v.used)) / \(fmt(v.total))", v.mount == "/" ? (app.trashBytes.map { $0 > 0 ? "Trash \(fmt($0))" : "" } ?? "") : "")
            }
        }
        if let io = s.disk {
            StatTile(caption: "Disk I/O") {
                kv("Read", rate(io.read))
                kv("Write", rate(io.write))
            }
        }
        if !s.network.isEmpty {
            StatTile(caption: "Network") {
                ForEach(s.network) { n in
                    kv("\(n.name) \(n.address ?? "")", "↓\(rate(n.received)) ↑\(rate(n.sent))")
                }
            }
        }
        if let b = s.battery {
            StatTile(caption: "Battery") {
                big(b.percent)
                kv(b.state, b.minutesLeft.map { "\($0 / 60)h \($0 % 60)m left" } ?? "")
                if let c = b.cycleCount { kv("cycles \(c)", b.capacityPercent.map { "capacity \(Int($0.rounded()))%" } ?? "") }
                if let h = b.health { kv("health", h) }
            }
        }
        if !s.topProcesses.isEmpty {
            StatTile(caption: "Top processes") {
                ForEach(s.topProcesses.prefix(6)) { p in
                    HStack {
                        DSName(p.name, .lead, lines: 2)
                        Spacer()
                        Text("\(Int(p.cpu.rounded()))%").bold().monospacedDigit()
                        Text(fmt(p.memoryBytes)).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    private func big(_ pct: Double) -> some View {
        Metric("\(Int(pct.rounded()))%")
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).bold()
        }
        .font(.caption.monospacedDigit())
    }

    private func fmt(_ n: Int64) -> String { ByteSize.format(n) }
}
