import AppKit
import StorageKit
import SwiftUI

extension ProjectsModel {
    enum RuleChange: Equatable {
        case whitelist([String], project: String)
        case blacklist([String], project: String)
        case whitelistName(String)
        case blacklistName(String)

        var whitelist: Bool {
            switch self { case .whitelist, .whitelistName: true; default: false }
        }
        var confirmation: ConfirmationAction { whitelist ? .projectWhitelist : .projectBlacklist }
        var explanation: String {
            switch self {
            case .whitelistName:
                String(localized: "These names are excluded inside Projects, including their contents. To protect a folder from Trash moves in other views too, whitelist its specific path.")
            case .whitelist:
                String(localized: "These items and everything inside them stay, even when a parent is chosen for cleanup. Path rules also protect moves to the Trash in other views.")
            case .blacklist, .blacklistName:
                String(localized: "This adds a cleanup suggestion on future scans. Nothing is removed now. Source control, protected locations and whitelist rules still take priority.")
            }
        }
        var title: String { whitelist ? String(localized: "Whitelist — exclude from cleanup") : String(localized: "Blacklist — suggest for cleanup") }
        var scope: String {
            switch self {
            case .whitelist(let paths, _), .blacklist(let paths, _): paths.map(Breakable.path).joined(separator: "\n")
            case .whitelistName(let name), .blacklistName(let name): String(localized: "Every folder named “\(name)” in your projects")
            }
        }
    }

    func requestRule(_ change: RuleChange) {
        guard pendingRule == nil else { return }
        if ruleConfirmations.asks(change.confirmation) { pendingRule = change }
        else { applyRule(change) }
    }

    func confirmRule(_ change: RuleChange, remind: Bool) {
        guard pendingRule == change else { return }
        pendingRule = nil
        if !remind { ruleConfirmations.setAsking(false, for: change.confirmation) }
        applyRule(change)
    }

    private func applyRule(_ change: RuleChange) {
        switch change {
        case .whitelist(let paths, let project): keep(paths, in: project)
        case .blacklist(let paths, let project): clean(paths, in: project)
        case .whitelistName(let name): keepEverywhere(named: name)
        case .blacklistName(let name): cleanEverywhere(named: name)
        }
    }

    func pinFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Pin")
        panel.message = String(localized: "Pin folders for quick access. Pinning doesn't change what can be cleaned.")
        guard panel.runModal() == .OK else { return }
        pins.set(panel.urls.map(\.path), pinned: true)
    }
}

/// An explicit decision stays visible until accepted or cancelled. It never
/// starts a cleanup, and it has separate reminder settings for each rule kind.
struct ProjectRuleConfirmation: View {
    let model: ProjectsModel
    let change: ProjectsModel.RuleChange

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Label(change.title, systemImage: change.whitelist ? "checkmark.shield" : "trash")
                .font(.headline)
            Text(change.explanation)
                .fixedSize(horizontal: false, vertical: true)
            Text(change.scope).font(.caption).foregroundStyle(.secondary)
                .lineLimit(4).help(change.scope)
            DSActionGroup {
                Text("Change reminders in Settings → Confirmations.").font(.caption).foregroundStyle(.secondary)
            } trailing: {
                Button("Cancel", role: .cancel) { model.pendingRule = nil }
                    .keyboardShortcut(.cancelAction)
                Button("OK, Don't Remind Me") { model.confirmRule(change, remind: false) }
                Button("OK") { model.confirmRule(change, remind: true) }
                    .keyboardShortcut(.defaultAction)
                    .primaryAction()
            }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: 600, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: DS.Radius.card))
        .shadow(radius: 8, y: 2)
        .padding(DS.Space.lg)
        .accessibilityIdentifier("projects.rule.confirmation")
    }
}
