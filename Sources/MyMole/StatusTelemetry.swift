import AppKit
import StorageKit
import SwiftUI
import SystemKit

/// Presentation of an existing reading. Expensive sampling and file access
/// stay with the model; opening details does not start another reading.
struct StatusTelemetry: View {
    enum Action { case cpuProcesses, memoryProcesses, diskMap, emptyTrash, activityMonitor }
    let card: StatusCardID
    let snapshot: SystemSnapshot
    let history: StatusHistory
    var trashBytes: Int64? = nil
    var canEmptyTrash = false
    @Binding var order: StatusView.ProcessOrder
    var action: (Action) -> Void = { _ in }
    var requestQuit: (StatusAppTarget) -> Void = { _ in }
    var processLimit = 8
    var showsProcessMonitorLink = true
    @State private var showingDetails = false
    @State private var selectedInterface: String?
    @Environment(\.palette) private var palette

    var body: some View {
        switch card {
        case .cpu: cpu
        case .memory: memory
        case .storage: storage
        case .diskIO: diskIO
        case .network: network
        case .battery: battery
        case .health: health
        case .processes: processes
        }
    }

    @ViewBuilder private var cpu: some View {
        if let cpu = snapshot.cpu {
            metric(percent(cpu.usage), history: history.cpu)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(cpu.perCore.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 2).fill(Theme.load(value))
                        .frame(height: max(3, 24 * min(max(value, 0), 100) / 100))
                }
            }.frame(height: 24, alignment: .bottom)
                .accessibilityLabel("CPU use by core")
            HStack {
                Text(cpu.perCore.isEmpty ? String(localized: "Core detail unavailable") : String(localized: "\(cpu.perCore.count) cores"))
                    .lineLimit(1)
                Spacer()
                if let load = cpu.load {
                    HStack(spacing: 3) {
                        Text("Load")
                        Text(String(format: "%.2f · %.2f · %.2f", load.one, load.five, load.fifteen))
                    }.help("Load averages over 1, 5 and 15 minutes")
                }
            }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            footer {
                link("Processes", symbol: "list.bullet") { action(.cpuProcesses) }
                    .accessibilityLabel("Show CPU Processes")
            }
        } else { unavailable }
    }

    @ViewBuilder private var memory: some View {
        if let memory = snapshot.memory {
            metric(percent(memory.usedPercent), history: history.memory)
            UsageBar(fraction: memory.usedPercent / 100,
                     tint: memory.pressure == .normal ? palette.accent.color : memory.pressure == .critical ? palette.critical : palette.warning,
                     height: 4)
            fact(String(localized: "Used / total"), "\(fmt(memory.used)) / \(fmt(memory.total))")
            HStack {
                Text("Swap \(fmt(memory.swapUsed))").foregroundStyle(.secondary)
                Spacer()
                Text(pressure(memory.pressure))
                    .fontWeight(memory.pressure == .normal ? .regular : .semibold)
                    .foregroundStyle(memory.pressure == .normal ? palette.secondaryText.color : palette.text.color)
            }.font(.caption.monospacedDigit())
            footer {
                link("Processes", symbol: "list.bullet") { action(.memoryProcesses) }
                    .accessibilityLabel("Show Memory Processes")
            }
        } else { unavailable }
    }

    @ViewBuilder private var storage: some View {
        if let volume = snapshot.startupVolume {
            metric(percent(volume.usedPercent), history: history.disk)
            UsageBar(fraction: volume.usedPercent / 100,
                     tint: volume.usedPercent >= 95 ? palette.critical : volume.usedPercent >= 80 ? palette.warning : palette.accent.color,
                     height: 4)
            fact(String(localized: "Used / total"), "\(fmt(volume.used)) / \(fmt(volume.total))")
            fact(String(localized: "Available"), fmt(volume.available))
            footer { link("Disk Map", symbol: "arrow.up.forward") { action(.diskMap) } }
        } else { unavailable }
    }

    @ViewBuilder private var diskIO: some View {
        if let disk = snapshot.disk {
            rates(first: disk.read, second: disk.write, labels: (String(localized: "Read"), String(localized: "Write")))
            footer { Text("Since the previous reading").font(.caption2).foregroundStyle(.secondary) }
        } else { unavailable }
    }

    @ViewBuilder private var network: some View {
        if let interface = Self.interface(in: snapshot.network, selected: selectedInterface) {
            rates(first: interface.received, second: interface.sent,
                  labels: (String(localized: "Received"), String(localized: "Sent")))
            footer {
                Text(interface.name).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).help(interface.name)
            }
        } else { unavailable }
    }

    @ViewBuilder private var battery: some View {
        if let battery = snapshot.battery {
            metric(percent(battery.percent), history: history.battery)
            footer {
                Text(battery.state).font(.caption).foregroundStyle(.secondary)
                if let minutes = battery.minutesLeft {
                    Text("\(minutes / 60)h \(minutes % 60)m").font(.caption.monospacedDigit())
                }
            }
        } else {
            Text("No battery reading").font(.callout).foregroundStyle(.secondary)
            DSText("macOS hasn't provided battery data. You can hide this card if it isn't useful on this Mac.", .metadata)
        }
    }

    @ViewBuilder private var health: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(snapshot.health.scoreText).font(.system(size: 28, weight: .semibold)).monospacedDigit()
            Text("/ 100").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !snapshot.health.issues.isEmpty {
                Label {
                    Text(snapshot.health.issues.count == 1 ? String(localized: "1 notice") : String(localized: "\(snapshot.health.issues.count) notices"))
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(palette.warning)
                }.font(.caption)
            }
        }
        Text(snapshot.health.issues.first?.text ?? snapshot.health.summary)
            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            .frame(height: 30, alignment: .topLeading)
            .help(snapshot.health.issues.map(\.text).joined(separator: "\n"))
        footer {
            if let up = snapshot.uptime {
                Text("Uptime \(SystemSnapshot.uptimeText(up))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).help(SystemSnapshot.uptimeText(up))
            }
        }
    }

    @ViewBuilder private var processes: some View {
        HStack(spacing: DS.Space.sm) {
            Text("Sort by").font(.caption).foregroundStyle(.secondary)
            Picker("Sort processes by", selection: $order) {
                Text("CPU").tag(StatusView.ProcessOrder.cpu)
                Text("Memory").tag(StatusView.ProcessOrder.memory)
            }.pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            Spacer(minLength: 0)
        }
        HStack {
            Text("Process")
            Spacer(minLength: DS.Space.xs)
            Text("CPU").frame(width: 48, alignment: .trailing)
            Text("Memory").frame(width: 76, alignment: .trailing)
            Color.clear.frame(width: 20, height: 1)
        }.font(.caption2).foregroundStyle(.secondary).padding(.top, DS.Space.xs)
        if snapshot.topProcesses.isEmpty {
            DSText("Process details aren't available for this reading.", .metadata)
            if showsProcessMonitorLink { link("Activity Monitor", symbol: "arrow.up.forward") { action(.activityMonitor) } }
        } else {
            VStack(spacing: 0) {
                ForEach(order.sorted(snapshot.topProcesses).prefix(processLimit)) { process in
                    StatusProcessRow(process: process, emphasis: order, requestQuit: requestQuit)
                }
            }
        }
    }

    private func metric(_ value: String, history: [Double]) -> some View {
        HStack(spacing: DS.Space.md) {
            Text(value).font(.system(size: 28, weight: .semibold)).monospacedDigit()
                .lineLimit(1).frame(minWidth: 86, alignment: .leading)
            Sparkline(values: history).frame(maxWidth: .infinity)
        }.frame(height: 40)
    }

    private func rates(first: Double, second: Double, labels: (String, String)) -> some View {
        HStack(spacing: DS.Space.md) {
            rateValue(first, title: labels.0, symbol: "arrow.down")
            Rectangle().fill(palette.separator.color).frame(width: 1, height: 34)
            rateValue(second, title: labels.1, symbol: "arrow.up")
        }.padding(.top, DS.Space.xs)
    }

    private func rateValue(_ value: Double, title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption2).foregroundStyle(.secondary)
            Text(rate(value)).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8).help(rate(value))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: DS.Space.sm) {
            content()
            Spacer(minLength: 0)
            if card != .diskIO { detailsButton }
        }.padding(.top, DS.Space.xs)
    }

    private var detailsButton: some View {
        Button { showingDetails = true } label: {
            Label("Details", systemImage: "chevron.right").frame(minHeight: 24).contentShape(.rect)
        }
            .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            .allowsWindowActivationEvents()
            .accessibilityLabel("Details for \(card.title)")
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                ViewThatFits(in: .vertical) {
                    details.fixedSize(horizontal: false, vertical: true)
                    ScrollView { details }
                }.frame(width: 340).frame(maxHeight: 380).padding(DS.Space.lg).dialogKeyboard()
            }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(card.title).font(.headline)
            Divider()
            switch card {
            case .cpu:
                if let cpu = snapshot.cpu {
                    fact(String(localized: "Total CPU use"), percent(cpu.usage))
                    if let p = cpu.performanceCores { fact(String(localized: "Performance cores"), p.formatted()) }
                    if let e = cpu.efficiencyCores { fact(String(localized: "Efficiency cores"), e.formatted()) }
                    if let load = cpu.load {
                        fact(String(localized: "Load · 1 minute"), load.one.formatted(.number.precision(.fractionLength(2))))
                        fact(String(localized: "Load · 5 minutes"), load.five.formatted(.number.precision(.fractionLength(2))))
                        fact(String(localized: "Load · 15 minutes"), load.fifteen.formatted(.number.precision(.fractionLength(2))))
                    }
                }
            case .memory:
                if let m = snapshot.memory {
                    fact(String(localized: "Used / total"), "\(fmt(m.used)) / \(fmt(m.total))")
                    fact(String(localized: "Swap"), fmt(m.swapUsed))
                    fact(String(localized: "Swap allocated"), fmt(m.swapTotal))
                    fact(String(localized: "Pressure"), pressure(m.pressure))
                }
            case .storage:
                if let volume = snapshot.startupVolume {
                    fact(String(localized: "Available"), fmt(volume.available))
                    if let health = snapshot.hardware.diskHealth { fact(String(localized: "Disk health (SMART)"), health) }
                    if let trashBytes { fact(String(localized: "Trash"), fmt(trashBytes)) }
                    ForEach(snapshot.volumes.filter { $0.isInternal && $0.mount != "/" }) {
                        fact($0.name, String(localized: "\(fmt($0.available)) free"))
                    }
                    if canEmptyTrash { Button("Empty Trash…", role: .destructive) { action(.emptyTrash) } }
                }
            case .network:
                ForEach(snapshot.network) { item in
                    Text(item.name).font(.subheadline.weight(.semibold))
                    if let address = item.address { Text(address).font(.caption.monospaced()).textSelection(.enabled) }
                    fact(String(localized: "Received"), rate(item.received))
                    fact(String(localized: "Sent"), rate(item.sent))
                    if snapshot.network.count > 1 {
                        Button(Self.interface(in: snapshot.network, selected: selectedInterface)?.id == item.id
                               ? String(localized: "Shown in overview") : String(localized: "Show in overview")) {
                            selectedInterface = item.id
                        }
                        .buttonStyle(.link).font(.caption)
                        .disabled(Self.interface(in: snapshot.network, selected: selectedInterface)?.id == item.id)
                    }
                    if item.id != snapshot.network.last?.id { Divider() }
                }
            case .battery:
                if let b = snapshot.battery {
                    fact(String(localized: "Power"), b.state)
                    if let cycles = b.cycleCount { fact(String(localized: "Cycles"), cycles.formatted()) }
                    if let capacity = b.capacityPercent { fact(String(localized: "Capacity"), percent(capacity)) }
                    if let health = b.health { fact(String(localized: "Health"), health) }
                }
            case .health:
                Text(snapshot.health.summary).font(.subheadline)
                ForEach(snapshot.health.issues, id: \.text) { Text($0.text).font(.caption) }
                if let up = snapshot.uptime { fact(String(localized: "Uptime"), SystemSnapshot.uptimeText(up)) }
            case .diskIO:
                if let disk = snapshot.disk {
                    fact(String(localized: "Read"), rate(disk.read))
                    fact(String(localized: "Write"), rate(disk.write))
                    DSText("Transfer rates since the previous reading.", .metadata)
                }
            case .processes: EmptyView()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unavailable: some View { DSText("No reading available right now.", .metadata) }
    private func percent(_ value: Double) -> String {
        value.isFinite ? value.formatted(.number.precision(.fractionLength(0))) + "%" : "—"
    }
    private func rate(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }
        return value == 0 ? String(localized: "0 B/s") : ByteSize.format(Int64(value)) + "/s"
    }
    /// A VPN can expose the same traffic on several interfaces. Display
    /// one named interface, never an inflated sum of overlapping counters.
    nonisolated static func interface(in interfaces: [SystemSnapshot.Interface], selected: String?) -> SystemSnapshot.Interface? {
        interfaces.first { $0.id == selected } ?? interfaces.first { $0.name == "en0" } ?? interfaces.min { $0.name < $1.name }
    }
    private func fmt(_ value: Int64) -> String { ByteSize.format(value) }
    private func pressure(_ value: SystemSnapshot.Pressure) -> String {
        switch value {
        case .normal: String(localized: "Normal pressure")
        case .warning: String(localized: "High pressure")
        case .critical: String(localized: "Critical pressure")
        }
    }
    private func fact(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: DS.Space.sm)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }.font(.caption)
    }
    private func link(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(minHeight: 24).contentShape(.rect)
        }
            .buttonStyle(.borderless).font(.caption).foregroundStyle(palette.accentText.color)
            .allowsWindowActivationEvents()
    }
}

/// Stable single-line rows; a changed process name cannot move its neighbours.
private struct StatusProcessRow: View {
    let process: SystemSnapshot.Process
    let emphasis: StatusView.ProcessOrder
    let requestQuit: (StatusAppTarget) -> Void
    @State private var target: StatusAppTarget?

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Text(process.name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: DS.Space.xs)
            Text("\(Int(process.cpu.rounded()))%").fontWeight(emphasis == .cpu ? .semibold : .regular)
                .monospacedDigit().frame(width: 48, alignment: .trailing)
            Text(ByteSize.format(process.memoryBytes)).fontWeight(emphasis == .memory ? .semibold : .regular)
                .foregroundStyle(emphasis == .memory ? .primary : .secondary).monospacedDigit()
                .frame(width: 76, alignment: .trailing)
            Menu { actions } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden).menuStyle(.borderlessButton).frame(width: 20)
                .accessibilityLabel("Actions for \(process.name)")
        }.font(.caption).frame(height: 22)
            .contentShape(.rect).help("\(process.name) · process \(process.pid)")
            .contextMenu { actions }
            .task(id: "\(process.pid):\(process.name)") { target = process.pid > 0 ? StatusAppTarget.capture(process.pid) : nil }
    }

    @ViewBuilder private var actions: some View {
        Button("Open Activity Monitor") { StatusActions.openActivityMonitor() }
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(process.name, forType: .string)
        }
        Button("Copy Process ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(process.pid), forType: .string)
        }
        if let target {
            Divider()
            Menu("Application") { FileMenuItems(paths: [target.bundle.path], canOpen: false) }
        }
        if let target { Divider(); Button("Quit \(target.name)…") { requestQuit(target) } }
    }
}
