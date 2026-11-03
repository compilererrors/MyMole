import PrivilegedKit
import SwiftUI

/// The Optimize pane: MyMole's maintenance tasks, each with what it does in
/// plain words. Check shows what a run would do without changing anything;
/// Optimize Now runs the tasks that are on. Tasks that need root run in the
/// privileged tool, after macOS asks for an administrator's password.
struct OptimizeView: View {
    @Bindable var model: MaintenanceModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DSPage(width: .full) {
                ForEach(MaintenanceTask.Group.allCases.filter { g in model.offered.contains { $0.group == g } }, id: \.self) { group in
                    DSSection(group.rawValue) {
                        ForEach(model.offered.filter { $0.group == group }) { row($0) }
                    }
                }
            }
            DSActionBar {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    DSText("\(model.runnable.count) of \(model.offered.count) tasks on", .lead)
                    Label("Settings files and window states go to the Trash; the rest refreshes in place.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            } trailing: {
                Button("Optimize Now") { confirm = true }
                    .primaryAction()
                    .disabled(model.phase != .idle || model.runnable.isEmpty)
            }
        }
        .paneToolbar("Optimize", subtitle: "Refresh caches and databases macOS keeps") {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.check()
                } label: {
                    Label("Check", systemImage: "checklist")
                }
                .help("See what a run would do; nothing is changed")
                .disabled(model.phase != .idle)
            }
        }
        .confirmationDialog("Run \(model.runnable.count) maintenance task\(model.runnable.count == 1 ? "" : "s")?", isPresented: $confirm) {
            Button("Optimize Now") { model.run() }
        } message: {
            Text(model.runnable.map(\.title).joined(separator: ", "))
        }
        .onAppear {
            // A check only reads, so it runs each time the pane opens.
            model.check()
        }
    }

    private var header: some View {
        DSPaneHeader {
            DSMetric("\(model.willChange)", "of the tasks that are on would change something")
        } actions: {
            EmptyView()
        } strip: {
            switch model.phase {
            case .checking:
                DSRunningCapsule(text: "Checking \(model.current?.title ?? "")", since: nil)
            case .running:
                DSRunningCapsule(text: "Running \(model.current?.title ?? "")", since: nil)
            case .idle:
                if let at = model.lastRun {
                    DSCapsule("Ran \(at.formatted(.relative(presentation: .named)))", symbol: "checkmark", tint: .green)
                } else if let at = model.checkedAt {
                    DSCapsule("Checked \(at.formatted(.relative(presentation: .named)))", symbol: "checkmark")
                }
            }
            if model.privileged.isAvailable {
                DSCapsule("Administrator tasks ask for a password", symbol: "lock.shield")
            } else {
                DSCapsule("App Store edition: tasks on your own files", symbol: "lock.shield")
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ t: MaintenanceTask) -> some View {
        DSRow(title: t.title) {
            DSIcon(symbol: t.symbol)
        } detail: {
            DSText(t.explanation, .metadata)
            if let r = model.reports[t] {
                Label(statusText(r), systemImage: statusSymbol(r.status))
                    .font(.caption)
                    .foregroundStyle(statusColor(r.status))
            }
        } trailing: {
            HStack(spacing: DS.Space.sm) {
                if model.current == t { PulseDot() }
                if t.needsRoot { DSBadge("Administrator", tint: .orange) }
                Toggle("", isOn: Binding(get: { model.isOn(t) }, set: { model.setOn(t, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(model.phase != .idle)
            }
        }
    }

    private func statusText(_ r: TaskReport) -> String {
        let base: String =
            switch r.status {
            case .willRun: "Would run"
            case .nothingToDo: "Nothing to do"
            case .done: "Done"
            case .failed: "Failed"
            case .unavailable: "Not available"
            case .needsHelper: "Needs administrator rights"
            }
        return r.detail.isEmpty ? base : "\(base) · \(r.detail)"
    }

    private func statusSymbol(_ s: TaskReport.Status) -> String {
        switch s {
        case .willRun: "arrow.triangle.2.circlepath"
        case .nothingToDo, .done: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .unavailable: "minus.circle"
        case .needsHelper: "lock"
        }
    }

    private func statusColor(_ s: TaskReport.Status) -> Color {
        switch s {
        case .willRun: Theme.accent
        case .nothingToDo, .done: .green
        case .failed: .red
        case .unavailable, .needsHelper: .secondary
        }
    }
}
