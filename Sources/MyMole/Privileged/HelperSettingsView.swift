#if !APPSTORE
import SwiftUI

struct HelperSettingsView: View {
    @Bindable var helper: HelperServiceController

    private var statusText: String {
        switch helper.status {
        case .enabled: String(localized: "Helper enabled — approved tasks don't need a password each time.")
        case .requiresApproval: String(localized: "Waiting for approval in Login Items & Extensions.")
        case .notRegistered: String(localized: "Helper disabled — macOS asks for administrator approval per task.")
        case .unavailable: String(localized: "The helper isn't available in this copy of MyMole.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(statusText).foregroundStyle(.secondary)
                Spacer(minLength: DS.Space.sm)
                DSInfoButton(title: String(localized: "Administrator access"), detail: String(localized: "The optional helper handles administrator tasks after macOS approval. You still review and confirm removals. App Management and Full Disk Access are separate macOS permissions; enabling the helper doesn't grant them."))
            }
            HStack {
                switch helper.status {
                case .enabled:
                    Button("Disable Helper") { Task { await helper.disable() } }
                case .requiresApproval:
                    Button("Open Login Items & Extensions") { helper.openSettings() }
                    Button("Disable Helper") { Task { await helper.disable() } }
                case .notRegistered:
                    Button("Enable Helper") { helper.enable() }
                case .unavailable:
                    EmptyView()
                }
            }
            .disabled(helper.changing)
            if let problem = helper.problem { DSNotice(.warning, problem) }
        }
        .accessibilityIdentifier("settings.helper")
        .task { helper.refresh() }
    }
}
#endif
