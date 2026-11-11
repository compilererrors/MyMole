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
    @State private var showingProcesses = false
    @State private var editingLayout = false
    @State private var dragSession = UUID()
    @State private var dropTarget: StatusCardID?
    @State private var endTargeted = false
    @State private var gridWidth: CGFloat = 900
    @State private var lastHidden: StatusCardID?
    let app: AppModel

    static let interval: Duration = .seconds(2)
    private var layout: StatusLayout { StatusLayout.read(savedLayout) }
    private var layoutBinding: Binding<StatusLayout> {
        // Swift 6.3 can crash when converting the actor-isolated method reference.
        Binding(get: { layout }, set: { value in apply(value) })
    }

    var body: some View {
        VStack(spacing: 0) {
            StatusOverviewStrip(date: app.status?.date, score: app.status?.health.scoreText,
                                healthSummary: app.status?.health.summary,
                                needsAttention: app.status?.health.issues.isEmpty == false)
            if editingLayout || !layout.hidden.isEmpty { layoutControls }
            if let actionProblem {
                DSNotice(.warning, actionProblem) {
                    Button("Dismiss") { self.actionProblem = nil }
                }
                .padding(.horizontal, DS.Space.page)
                .padding(.bottom, DS.Space.sm)
            }
            Divider()
            Group {
                DSPage {
                    if layout.visible.isEmpty {
                        ContentUnavailableView {
                            Label("No Cards Visible", systemImage: "rectangle.grid.2x2")
                        } description: {
                            Text("Your cards are hidden. Show them again without changing their saved sizes or order.")
                        } actions: {
                            Button("Customize Live Status…") { customizing = true }
                            Button("Show All Cards") { change { $0.showAll() } }
                        }
                    } else if let snapshot = app.status {
                        StatusGridView(cards: layout.visible, compactDensity: Density.current == .compact, editing: editingLayout, spacing: DS.Space.md) { card in
                                StatusCard(card: card.id, editing: editingLayout, size: card.size,
                                           canResize: StatusGrid.columnCount(width: gridWidth, spacing: DS.Space.md) > 1,
                                           drag: StatusCardDrag(card: card.id, session: dragSession),
                                           onResize: { size in change { $0.setSize(size, for: card.id) } },
                                           onMove: { offset in change { $0.move(card.id, by: offset, visibleOnly: true) } }) {
                                    StatusTelemetry(card: card.id, snapshot: snapshot, history: app.statusHistory,
                                                    trashBytes: app.trash.bytes, canEmptyTrash: app.trash.canEmpty,
                                                    order: $order, action: perform) { target in
                                        guard target.matches(StatusAppTarget.capture(target.pid)) else {
                                            actionProblem = String(localized: "That app changed or already quit. Refresh the reading before trying again.")
                                            return
                                        }
                                        quitTarget = target
                                        confirmingQuit = true
                                    }
                                } actions: {
                                    cardActions(card)
                                }
                                .id(card.id)
                                .overlay {
                                    if editingLayout, dropTarget == card.id {
                                        RoundedRectangle(cornerRadius: DS.Radius.card)
                                            .stroke(palette.accentText.color, lineWidth: 2)
                                            .overlay(alignment: .top) {
                                                Text("Place before \(card.id.title)").font(.caption.weight(.medium))
                                                    .padding(DS.Space.xs).background(.regularMaterial, in: .capsule)
                                            }
                                            .allowsHitTesting(false)
                                    }
                                }
                                .contentShape(Rectangle())
                                .modifier(StatusCardDropTarget(enabled: editingLayout, accept: { items in
                                    accept(items, before: card.id)
                                }, targeted: { targeted in
                                    if targeted { dropTarget = card.id }
                                    else if dropTarget == card.id { dropTarget = nil }
                                }))
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                        if editingLayout { endDropTarget }
                    } else {
                        DSLoading("Reading your Mac's status…").padding(DS.Space.xl * 2)
                    }
                }
            }
        }
        .paneToolbar("Live Status", subtitle: "\(meta)") {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    editingLayout.toggle()
                } label: {
                    Label(editingLayout ? String(localized: "Done Arranging") : String(localized: "Edit Layout"),
                          systemImage: editingLayout ? "checkmark" : "rectangle.3.group")
                }
                .help("Move and resize cards directly in the grid")
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
        .sheet(isPresented: $showingProcesses) { StatusProcessesSheet(app: app, order: $order) }
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
        apply(changed)
    }

    private func apply(_ changed: StatusLayout) {
        let previous = layout
        guard previous != changed else { return }
        let newlyHidden = previous.visible.filter { before in changed.hidden.contains { $0.id == before.id } }
        if let id = newlyHidden.last?.id { lastHidden = id }
        if let lastHidden, changed.visible.contains(where: { $0.id == lastHidden }) { self.lastHidden = nil }
        withAnimation(reduceMotion ? nil : Motion.snappy) { savedLayout = changed.saved }
    }

    private func accept(_ items: [StatusCardDrag], before target: StatusCardID?) -> Bool {
        guard editingLayout, items.count == 1, let item = items.first,
              item.canMove(in: layout, session: dragSession, before: target) else { return false }
        change { $0.move(item.card, before: target) }
        dropTarget = nil
        return true
    }

    private var layoutControls: some View {
        DSActionGroup {
            if editingLayout {
                Text("Drag a handle to move a card. Drag its corner sideways to resize. Cards fill each row and share its height.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let id = lastHidden, layout.hidden.contains(where: { $0.id == id }) {
                HStack(spacing: DS.Space.sm) {
                    Text("\(id.title) hidden").font(.caption).foregroundStyle(.secondary)
                    Button("Undo Hide") { change { $0.setVisible(true, for: id) } }
                }
            }
        } trailing: {
            if !layout.hidden.isEmpty {
                Menu {
                    ForEach(layout.hidden) { card in
                        Button { change { $0.setVisible(true, for: card.id) } } label: {
                            Label("Show \(card.id.title)", systemImage: card.id.symbol)
                        }
                    }
                    Divider()
                    Button("Show All Cards") { change { $0.showAll() } }
                } label: {
                    Label("\(layout.hidden.count) hidden", systemImage: "eye.slash")
                }
                .fixedSize()
                .accessibilityLabel("Show hidden cards (\(layout.hidden.count))")
                .help("Show one hidden card or bring them all back")
            }
        }
        .frame(maxWidth: DS.Size.pageMaxWidth, alignment: .leading)
        .padding(.horizontal, DS.Space.page)
        .padding(.bottom, DS.Space.md)
        .frame(maxWidth: .infinity)
    }

    private var endDropTarget: some View {
        Label("Drop here to move to the end", systemImage: "arrow.down.to.line")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(palette.accent.color.opacity(endTargeted ? 0.15 : 0.04), in: .rect(cornerRadius: DS.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                .strokeBorder(palette.accentText.color.opacity(endTargeted ? 0.8 : 0.25), style: StrokeStyle(lineWidth: 1, dash: [4])))
            .dropDestination(for: StatusCardDrag.self) { items, _ in accept(items, before: nil) }
                isTargeted: { endTargeted = $0 }
    }

    private func showProcesses(_ order: ProcessOrder) {
        self.order = order
        showingProcesses = true
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

    private func perform(_ action: StatusTelemetry.Action) {
        switch action {
        case .cpuProcesses: showProcesses(.cpu)
        case .memoryProcesses: showProcesses(.memory)
        case .diskMap: app.pane = .diskMap
        case .emptyTrash: Task { await app.trash.askToEmpty() }
        case .activityMonitor: StatusActions.openActivityMonitor()
        }
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

/// A compact fixed-scale trace. An empty history stays empty rather than
/// inventing readings to fill the chart.
struct Sparkline: View {
    let values: [Double]
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack {
                    Divider().opacity(0.35)
                    Spacer(minLength: 0)
                    Divider().opacity(0.35)
                }
                if values.count > 1 {
                    let line = Path { p in
                        let step = geo.size.width / CGFloat(StatusHistory.kept - 1)
                        let start = geo.size.width - step * CGFloat(values.count - 1)
                        for (i, v) in values.enumerated() {
                            let pt = CGPoint(x: start + step * CGFloat(i), y: geo.size.height * (1 - CGFloat(min(max(v, 0), 100)) / 100))
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                    let area = Path { p in
                        p.addPath(line)
                        p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                        let start = geo.size.width - geo.size.width / CGFloat(StatusHistory.kept - 1) * CGFloat(values.count - 1)
                        p.addLine(to: CGPoint(x: start, y: geo.size.height))
                        p.closeSubpath()
                    }
                    area.fill(LinearGradient(colors: [palette.accent.color.opacity(0.18), palette.accent.color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    line.stroke(palette.accentText.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(height: 32)
        .accessibilityLabel("The last few minutes")
        .accessibilityValue(values.last.map { "\(Int($0.rounded())) percent now" } ?? "")
    }
}

/// Live Status already has a dedicated Health card; a second large score
/// above the cards adds space without adding information.
struct StatusOverviewStrip: View {
    let date: Date?
    var score: String? = nil
    var healthSummary: String? = nil
    var needsAttention = false
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Text("System overview").font(.headline)
            Spacer(minLength: DS.Space.md)
            if let score {
                Label {
                    Text("Health \(score)").foregroundStyle(needsAttention ? palette.text.color : palette.secondaryText.color)
                } icon: {
                    if needsAttention { Image(systemName: "exclamationmark.triangle").foregroundStyle(palette.warning) }
                }.font(.caption.monospacedDigit())
                    .help(healthSummary ?? "")
            }
            DSCapsule("Live, every 2 s", tint: palette.accentText.color, live: true)
            if let date {
                Text("Read at \(date.formatted(date: .omitted, time: .standard))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: DS.Size.pageMaxWidth)
        .padding(.horizontal, DS.Space.page)
        .padding(.vertical, DS.Space.md)
        .frame(maxWidth: .infinity)
    }
}
