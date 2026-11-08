import AppKit
import StorageKit
import SwiftUI
import SystemKit

/// Live readings stay inside fixed card geometry. Only explicit layout edits
/// and window resizing change the position or size of a card.
struct StatusView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette
    @AppStorage("status.processOrder") private var order: ProcessOrder = .cpu
    @AppStorage(StatusLayout.key) private var savedLayout = ""
    @State private var customizing = false
    @State private var confirmingQuit = false
    @State private var quitTarget: StatusAppTarget?
    @State private var actionProblem: String?
    @State private var scrollRequest = 0
    let app: AppModel

    static let interval: Duration = .seconds(2)
    private var layout: StatusLayout { StatusLayout.read(savedLayout) }
    private var layoutBinding: Binding<StatusLayout> {
        Binding(get: { layout }, set: { savedLayout = $0.saved })
    }

    var body: some View {
        VStack(spacing: 0) {
            DSPaneHeader {
                DSMetric(app.status?.health.scoreText ?? "—", "system health")
            } actions: {
                EmptyView()
            } strip: {
                DSCapsule("Live, every 2 s", tint: palette.accentText.color, live: true)
                if let date = app.status?.date {
                    DSStatusFact("Read at \(date.formatted(date: .omitted, time: .standard))", symbol: "clock")
                }
            } detail: {
                if let actionProblem {
                    DSNotice(.warning, actionProblem) {
                        Button("Dismiss") { self.actionProblem = nil }
                    }
                }
            }
            Divider()
            ScrollViewReader { proxy in
                DSPage {
                    if layout.visible.isEmpty {
                        ContentUnavailableView {
                            Label("No Cards Visible", systemImage: "rectangle.grid.2x2")
                        } description: {
                            Text("Choose which readings to show, or restore the default layout.")
                        } actions: {
                            Button("Customize Live Status…") { customizing = true }
                            Button("Restore Default Layout") { savedLayout = StatusLayout().saved }
                        }
                    } else if let snapshot = app.status {
                        StatusGrid(sizes: layout.visible.map(\.size), spacing: DS.Space.md) {
                            ForEach(layout.visible) { card in
                                StatusCard(card: card.id) {
                                    cardContent(card.id, snapshot)
                                } actions: {
                                    cardActions(card)
                                }
                                .id(card.id)
                            }
                        }
                    } else {
                        DSLoading("Reading your Mac's status…").padding(DS.Space.xl * 2)
                    }
                }
                .task(id: scrollRequest) {
                    guard scrollRequest > 0 else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    withAnimation(reduceMotion ? nil : Motion.snappy) {
                        proxy.scrollTo(StatusCardID.processes, anchor: .top)
                    }
                }
            }
        }
        .paneToolbar("Live Status", subtitle: "\(meta)") {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    StatusActions.openActivityMonitor()
                } label: {
                    Label("Activity Monitor", systemImage: "waveform.path.ecg")
                }.help("Open Activity Monitor")
                Button {
                    customizing = true
                } label: {
                    Label("Customize Live Status…", systemImage: "slider.horizontal.3")
                }.help("Show, hide, resize and reorder cards")
            }
        }
        .sheet(isPresented: $customizing) { StatusLayoutEditor(layout: layoutBinding) }
        .actionConfirmation(
            String(localized: "Quit \(quitTarget?.name ?? "")?"), isPresented: $confirmingQuit,
            button: String(localized: "Quit App"),
            message: String(
                localized:
                    "The app is asked to quit normally, so it can save its work or ask you first. A changed or restarted process is left alone."
            )
        ) {
            if let target = quitTarget, !target.quit() {
                actionProblem = String(
                    localized: "The app changed, already quit, or couldn't accept the request. No other process was asked to quit.")
            }
            quitTarget = nil
        }
        .task {
            while !Task.isCancelled {
                await app.refreshStatus()
                try? await Task.sleep(for: AppModel.paced(Self.interval))
            }
        }
    }

    private var meta: String {
        guard let s = app.status else { return String(localized: "Collecting…") }
        return [s.hardware.model, s.hardware.chip, s.hardware.osVersion].compactMap { $0 }.joined(separator: " · ")
    }

    private func change(_ edit: (inout StatusLayout) -> Void) {
        var changed = layout
        edit(&changed)
        savedLayout = changed.saved
    }

    private func showProcesses(_ order: ProcessOrder) {
        self.order = order
        change { $0.setVisible(true, for: .processes) }
        scrollRequest += 1
    }

    @ViewBuilder private func cardActions(_ card: StatusLayout.Card) -> some View {
        switch card.id {
        case .health, .cpu, .memory, .processes:
            Button("Open Activity Monitor") { StatusActions.openActivityMonitor() }
        case .storage, .diskIO:
            Button("Open Disk Map") { app.pane = .diskMap }
        case .network, .battery:
            Button("Open System Settings") { StatusActions.openSystemSettings() }
        }
        if card.id == .cpu || card.id == .memory {
            Button("Show Top Processes") { showProcesses(card.id == .cpu ? .cpu : .memory) }
        }
        Divider()
        Picker("Card Size", selection: Binding(get: { card.size }, set: { value in change { $0.setSize(value, for: card.id) } })) {
            ForEach(StatusCardSize.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.inline)
        Button("Move Earlier") { change { $0.move(card.id, by: -1, visibleOnly: true) } }
            .disabled(layout.visible.first?.id == card.id)
        Button("Move Later") { change { $0.move(card.id, by: 1, visibleOnly: true) } }
            .disabled(layout.visible.last?.id == card.id)
        Button("Hide Card") { change { $0.setVisible(false, for: card.id) } }
        Button("Customize Live Status…") { customizing = true }
    }

    @ViewBuilder private func cardContent(_ card: StatusCardID, _ s: SystemSnapshot) -> some View {
        switch card {
        case .health:
            Metric(s.health.scoreText)
            if s.health.issues.isEmpty {
                DSText(s.health.summary, .metadata)
            } else {
                ForEach(s.health.issues, id: \.text) { DSText($0.text, .metadata) }
            }
            if let up = s.uptime { kv(String(localized: "Uptime"), SystemSnapshot.uptimeText(up)) }
        case .cpu:
            if let cpu = s.cpu {
                big(cpu.usage)
                Sparkline(values: app.statusHistory.cpu)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(cpu.perCore.enumerated()), id: \.offset) { _, value in
                        RoundedRectangle(cornerRadius: 2).fill(Theme.load(value))
                            .frame(height: max(3, 40 * min(value, 100) / 100))
                    }
                }.frame(height: 40, alignment: .bottom)
                if let load = cpu.load {
                    Text(String(format: "load %.2f · %.2f · %.2f", load.one, load.five, load.fifteen))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let p = cpu.performanceCores, let e = cpu.efficiencyCores {
                    DSText("\(p) performance · \(e) efficiency cores", .metadata)
                }
                Button("Show CPU Processes") { showProcesses(.cpu) }.buttonStyle(.link)
            } else {
                unavailable
            }
        case .memory:
            if let memory = s.memory {
                big(memory.usedPercent)
                Sparkline(values: app.statusHistory.memory)
                UsageBar(fraction: memory.usedPercent / 100)
                kv(String(localized: "Used / total"), "\(fmt(memory.used)) / \(fmt(memory.total))")
                kv(String(localized: "Swap"), fmt(memory.swapUsed))
                kv(
                    String(localized: "Pressure"),
                    memory.pressure == .normal
                        ? String(localized: "Normal")
                        : memory.pressure == .critical ? String(localized: "Critical") : String(localized: "High"))
                Button("Show Memory Processes") { showProcesses(.memory) }.buttonStyle(.link)
            } else {
                unavailable
            }
        case .storage:
            if let volume = s.startupVolume {
                big(volume.usedPercent)
                UsageBar(fraction: volume.usedPercent / 100)
                kv(String(localized: "Used / total"), "\(fmt(volume.used)) / \(fmt(volume.total))")
                if let health = s.hardware.diskHealth { kv(String(localized: "Disk health (SMART)"), health) }
                if let bytes = app.trash.bytes { kv(String(localized: "Trash"), fmt(bytes)) }
                Button("Open Disk Map") { app.pane = .diskMap }.buttonStyle(.link)
                if app.trash.canEmpty {
                    Button("Empty Trash…") { Task { await app.trash.askToEmpty() } }.buttonStyle(.link)
                }
                ForEach(s.volumes.filter { $0.isInternal && $0.mount != "/" }.prefix(2)) {
                    kv($0.name, String(localized: "\(fmt($0.available)) free"))
                }
            } else {
                unavailable
            }
        case .diskIO:
            if let disk = s.disk {
                kv(String(localized: "Read"), rate(disk.read))
                kv(String(localized: "Write"), rate(disk.write))
                DSText("Transfer rates since the previous reading.", .metadata)
            } else {
                unavailable
            }
        case .network:
            if s.network.isEmpty { unavailable }
            ForEach(s.network) { network in
                DSText(network.name, .heading)
                if let address = network.address { Text(address).font(.caption.monospaced()).textSelection(.enabled) }
                kv(String(localized: "Received"), rate(network.received))
                kv(String(localized: "Sent"), rate(network.sent))
            }
        case .battery:
            if let battery = s.battery {
                big(battery.percent)
                Sparkline(values: app.statusHistory.battery)
                kv(String(localized: "Power"), battery.state)
                if let minutes = battery.minutesLeft {
                    kv(String(localized: "Estimated time left"), String(localized: "\(minutes / 60)h \(minutes % 60)m"))
                }
                if let count = battery.cycleCount { kv(String(localized: "Cycles"), count.formatted()) }
                if let capacity = battery.capacityPercent { kv(String(localized: "Capacity"), "\(Int(capacity.rounded()))%") }
                if let health = battery.health { kv(String(localized: "Health"), health) }
            } else {
                DSText("macOS hasn't provided battery data. You can hide this card if it isn't useful on this Mac.", .metadata)
            }
        case .processes:
            if s.topProcesses.isEmpty {
                DSText("Process details aren't available for this reading.", .metadata)
                Button("Open Activity Monitor") { StatusActions.openActivityMonitor() }.buttonStyle(.link)
            } else {
                DSControlField("Sort processes by") {
                    Picker("Order", selection: $order) {
                        Text("CPU").tag(ProcessOrder.cpu)
                        Text("Memory").tag(ProcessOrder.memory)
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
                }
                HStack {
                    Text("Process")
                    Spacer(minLength: DS.Space.xs)
                    Text("CPU").frame(width: 44, alignment: .trailing)
                    Text("Memory").frame(width: 70, alignment: .trailing)
                    Color.clear.frame(width: 20, height: 1)
                }.font(.caption2).foregroundStyle(.secondary)
                ForEach(order.sorted(s.topProcesses).prefix(8)) { process in
                    ProcessRow(process: process, emphasis: order) { target in
                        guard target.matches(StatusAppTarget.capture(target.pid)) else {
                            actionProblem = String(localized: "That app changed or already quit. Refresh the reading before trying again.")
                            return
                        }
                        quitTarget = target
                        confirmingQuit = true
                    }
                }
            }
        }
    }

    private var unavailable: some View { DSText("No reading available right now.", .metadata) }
    private func rate(_ value: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + "/s" }
    private func big(_ value: Double) -> some View { Metric("\(Int(value.rounded()))%").lineLimit(1) }
    private func fmt(_ value: Int64) -> String { ByteSize.format(value) }
    private func kv(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: DS.Space.sm)
            Text(value).bold().multilineTextAlignment(.trailing)
        }.font(.caption.monospacedDigit())
    }

    enum ProcessOrder: String, CaseIterable {
        case cpu, memory
        func sorted(_ processes: [SystemSnapshot.Process]) -> [SystemSnapshot.Process] {
            switch self {
            case .cpu: processes.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.memoryBytes > $1.memoryBytes }
            case .memory: processes.sorted { $0.memoryBytes != $1.memoryBytes ? $0.memoryBytes > $1.memoryBytes : $0.cpu > $1.cpu }
            }
        }
    }
}

/// The last few minutes of a 0–100 reading as a line; nothing until there
/// are two readings to join.
struct Sparkline: View {
    let values: [Double]
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                Path { p in
                    let step = geo.size.width / CGFloat(StatusHistory.kept - 1)
                    let start = geo.size.width - step * CGFloat(values.count - 1)
                    for (i, v) in values.enumerated() {
                        let pt = CGPoint(x: start + step * CGFloat(i), y: geo.size.height * (1 - CGFloat(min(max(v, 0), 100)) / 100))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(palette.accent.color, lineWidth: 1.5)
            }
        }
        .frame(height: 24)
        .accessibilityLabel("The last few minutes")
        .accessibilityValue(values.last.map { "\(Int($0.rounded())) percent now" } ?? "")
    }
}

/// A menu captures the app identity once, not from a freshly reused PID at confirmation.
private struct ProcessRow: View {
    let process: SystemSnapshot.Process
    let emphasis: StatusView.ProcessOrder
    let requestQuit: (StatusAppTarget) -> Void
    @State private var target: StatusAppTarget?

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            DSName(process.name, .lead, lines: 2)
            Spacer(minLength: DS.Space.xs)
            Text("\(Int(process.cpu.rounded()))%").fontWeight(emphasis == .cpu ? .bold : .regular)
                .monospacedDigit().frame(width: 44, alignment: .trailing)
            Text(ByteSize.format(process.memoryBytes)).fontWeight(emphasis == .memory ? .bold : .regular)
                .foregroundStyle(emphasis == .memory ? .primary : .secondary).monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden).menuStyle(.borderlessButton).frame(width: 20)
            .accessibilityLabel("Actions for \(process.name)")
        }
        .font(.caption)
        .contentShape(.rect)
        .help("\(process.name) · process \(process.pid)")
        .contextMenu { actions }
        .task(id: "\(process.pid):\(process.name)") { target = StatusAppTarget.capture(process.pid) }
    }

    @ViewBuilder private var actions: some View {
        Button("Open Activity Monitor") { StatusActions.openActivityMonitor() }
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(process.name, forType: .string)
        }
        if let target {
            Divider()
            Button("Quit \(target.name)…") { requestQuit(target) }
        }
    }
}
