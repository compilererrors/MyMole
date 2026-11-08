import Foundation
import Observation
import SwiftUI

enum ConfirmationAction: String, CaseIterable, Identifiable {
    case deepClean, installers, projects, duplicates, orphans, uninstall, reset, savedResults
    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepClean: String(localized: "Deep Clean")
        case .installers: String(localized: "Installers")
        case .projects: String(localized: "Projects")
        case .duplicates: String(localized: "Identical duplicates")
        case .orphans: String(localized: "Left by removed apps")
        case .uninstall: String(localized: "App uninstallation to the Trash")
        case .reset: String(localized: "Reset app data to the Trash")
        case .savedResults: String(localized: "Clear saved scan results")
        }
    }
}

/// Skipping a repeated question never changes file selection or removal rules.
@MainActor @Observable
final class ConfirmationSettings {
    static let shared = ConfirmationSettings()
    static let key = "confirmations.skipped.v1"
    private let defaults: UserDefaults
    private(set) var skipped: Set<ConfirmationAction>
    var notice: ConfirmationAction?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        skipped = Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap(ConfirmationAction.init(rawValue:)))
    }

    func asks(_ action: ConfirmationAction?, always: Bool = false) -> Bool {
        always || (action.map { !skipped.contains($0) } ?? true)
    }

    func setAsking(_ asks: Bool, for action: ConfirmationAction) {
        if asks { skipped.remove(action) } else { skipped.insert(action) }
        defaults.set(skipped.map(\.rawValue).sorted(), forKey: Self.key)
    }

    func restore() {
        skipped = []
        defaults.removeObject(forKey: Self.key)
        notice = nil
    }
}

private struct ActionConfirmation: ViewModifier {
    let title: String
    @Binding var requested: Bool
    let action: ConfirmationAction?
    let always: Bool
    let button: String
    let message: String
    let perform: () -> Void
    @State private var settings = ConfirmationSettings.shared

    private var asks: Bool { settings.asks(action, always: always) }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(title, isPresented: Binding(
                get: { requested && asks }, set: { requested = $0 }
            ), titleVisibility: .visible) {
                Button(button, role: .destructive) { run(skip: false) }
                if action != nil, !always {
                    Button(String(localized: "\(button) and Don't Ask Again"), role: .destructive) { run(skip: true) }
                }
                Button("Cancel", role: .cancel) { requested = false }
            } message: {
                Text(message + (action != nil && !always
                     ? "\n\n" + String(localized: "Don't Ask Again applies only to this action. Turn the question on again in Settings → Confirmations.") : ""))
            }
            .onChange(of: requested, initial: true) { _, asked in
                if asked, !asks { run(skip: false) }
            }
    }

    private func run(skip: Bool) {
        requested = false
        if skip, let action {
            settings.setAsking(false, for: action)
            settings.notice = action
        }
        perform()
    }
}

extension View {
    func actionConfirmation(
        _ title: String, isPresented: Binding<Bool>, action: ConfirmationAction? = nil,
        always: Bool = false, button: String = String(localized: "Move to Trash"), message: String,
        perform: @escaping () -> Void
    ) -> some View {
        modifier(ActionConfirmation(title: title, requested: isPresented, action: action,
                                    always: always, button: button, message: message, perform: perform))
    }
}

/// Global feedback survives the sheet that just accepted the user's choice.
struct ConfirmationToast: View {
    @State private var settings = ConfirmationSettings.shared
    let openSettings: () -> Void

    var body: some View {
        if let action = settings.notice {
            HStack(spacing: DS.Space.md) {
                Image(systemName: "checkmark.circle")
                Text("Confirmation turned off for \(action.title). Turn it on again in Settings → Confirmations.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Settings") { settings.notice = nil; openSettings() }
                Button { settings.notice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
            .padding(DS.Space.md)
            .frame(maxWidth: 680)
            .background(.regularMaterial, in: .rect(cornerRadius: DS.Radius.card))
            .shadow(radius: 8, y: 2)
            .padding(DS.Space.lg)
            .task(id: action) {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled, settings.notice == action { settings.notice = nil }
            }
        }
    }
}

struct ConfirmationsSection: View {
    @State private var settings = ConfirmationSettings.shared

    var body: some View {
        DSSection("Confirmations", footer: "Turning a question off applies only to that action. Your choices, Keep rules and all file checks still apply. Permanent deletion, emptying the Trash, system maintenance, startup changes, similar-photo removal and uninstalling MyMole always ask.") {
            ForEach(ConfirmationAction.allCases) { action in
                Toggle(isOn: Binding(get: { settings.asks(action) }, set: { settings.setAsking($0, for: action) })) {
                    Text(action.title)
                    Text(settings.asks(action) ? "Ask before making this change" : "Question turned off; turn this on to ask again")
                        .foregroundStyle(.secondary)
                }
            }
            Button("Restore All Confirmations") { settings.restore() }
                .disabled(settings.skipped.isEmpty)
        }
    }
}
