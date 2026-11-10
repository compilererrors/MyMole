import SwiftUI

/// Reads the existing live sample; opening this view starts no extra sampler.
struct StatusProcessesSheet: View {
    let app: AppModel
    @Binding var order: StatusView.ProcessOrder
    @Environment(\.dismiss) private var dismiss
    @State private var quitTarget: StatusAppTarget?
    @State private var confirmingQuit = false
    @State private var problem: String?
    @State private var viewportHeight: CGFloat

    init(app: AppModel, order: Binding<StatusView.ProcessOrder>) {
        self.app = app
        _order = order
        _viewportHeight = State(initialValue: min(360, max(132, CGFloat(app.status?.topProcesses.count ?? 0) * 22 + 64)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("Processes").font(.title2.bold())
            DSText("Processes from the latest system reading, sorted by CPU or memory. Updates while Live Status is open.", .metadata)
            if let problem { DSNotice(.warning, problem) }
            ScrollView {
                if let snapshot = app.status {
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        StatusTelemetry(card: .processes, snapshot: snapshot, history: app.statusHistory, order: $order,
                            action: { action in
                                if case .activityMonitor = action { StatusActions.openActivityMonitor() }
                            }, requestQuit: { target in
                                guard target.matches(StatusAppTarget.capture(target.pid)) else {
                                    problem = String(localized: "That app changed or already quit. Refresh the reading before trying again.")
                                    return
                                }
                                quitTarget = target
                                confirmingQuit = true
                            }, processLimit: .max, showsProcessMonitorLink: false)
                    }
                } else { DSLoading("Reading your Mac's status…") }
            }
            .frame(height: viewportHeight)
            Divider()
            DSActionGroup {
                Button("Open Activity Monitor") { StatusActions.openActivityMonitor() }
            } trailing: {
                Button("Done") { dismiss() }.primaryAction().keyboardShortcut(.cancelAction)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.reviewWidth)
        .dialogControls()
        .dialogKeyboard()
        .accessibilityIdentifier("status.processes.review")
        .actionConfirmation(
            String(localized: "Quit \(quitTarget?.name ?? "")?"), isPresented: $confirmingQuit,
            button: String(localized: "Quit App"),
            message: String(localized: "The app is asked to quit normally, so it can save its work or ask you first. A changed or restarted process is left alone.")
        ) {
            if let target = quitTarget, !target.quit() {
                problem = String(localized: "The app changed, already quit, or couldn't accept the request. No other process was asked to quit.")
            }
            quitTarget = nil
        }
    }
}
