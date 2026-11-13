import Foundation
import Testing

@testable import MyMole

@MainActor @Suite struct ConfirmationSettingsTests {
    @Test func separateRuleAndCleanupControlsPreserveEachOthersPreferences() {
        let root = FileManager.default.temporaryDirectory.appending(path: "confirmations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = testDefaults(in: root)
        let cleanup = ConfirmationSettings(defaults: defaults)
        let rules = ConfirmationSettings(defaults: defaults)
        cleanup.setAsking(false, for: .projects)
        rules.setAsking(false, for: .projectWhitelist)
        #expect(!cleanup.asks(.projects) && !cleanup.asks(.projectWhitelist))
        #expect(!rules.asks(.projects) && !rules.asks(.projectWhitelist))
        rules.setAsking(true, for: .projectWhitelist)
        #expect(!cleanup.asks(.projects) && cleanup.asks(.projectWhitelist))
    }
    @Test func skippingAQuestionIsScopedPersistentAndRestorable() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "confirmations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = testDefaults(in: root)
        let settings = ConfirmationSettings(defaults: defaults)
        #expect(ConfirmationAction.allCases.allSatisfy { settings.asks($0) })
        settings.setAsking(false, for: .installers)
        #expect(!settings.asks(.installers))
        #expect(settings.asks(.projects))
        let restored = ConfirmationSettings(defaults: defaults)
        #expect(!restored.asks(.installers))
        restored.setAsking(true, for: .installers)
        #expect(restored.asks(.installers))
        restored.setAsking(false, for: .duplicates)
        restored.restore()
        #expect(restored.skipped.isEmpty)
        #expect(ConfirmationSettings(defaults: defaults).skipped.isEmpty)
    }

    @Test func irreversibleAndSelfRemovalQuestionsCannotBeSkipped() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "confirmations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = testDefaults(in: root)
        defaults.set(ConfirmationAction.allCases.map(\.rawValue) + ["emptyTrash", "selfRemoval", "unknown"], forKey: ConfirmationSettings.key)
        let settings = ConfirmationSettings(defaults: defaults)
        #expect(settings.asks(nil))
        // App uninstallation with a system-wide deletion still asks.
        #expect(settings.asks(.uninstall, always: true))
        #expect(!settings.asks(.uninstall))
        #expect(settings.skipped.count == ConfirmationAction.allCases.count)
    }
}
