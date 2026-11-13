#if !APPSTORE
import AppKit
import Foundation
import PrivilegedKit
import ServiceManagement

@MainActor @Observable
final class HelperServiceController {
    enum Status: Equatable { case notRegistered, requiresApproval, enabled, unavailable }
    enum Choice { case enable, later, never }
    enum Failure: LocalizedError {
        case approval, registration
        var errorDescription: String? {
            switch self {
            case .approval: String(localized: "Approve MyMole's helper in System Settings → General → Login Items & Extensions, then try the action again.")
            case .registration: String(localized: "MyMole couldn't change the helper registration. Keep the signed app in Applications and try again in Settings → System Tasks.")
            }
        }
    }

    struct Backend {
        var status: () -> Status
        var register: () throws -> Void
        var unregister: () async throws -> Void
        var openSettings: () -> Void
        var choose: () async -> Choice
        var perform: @Sendable (String) async -> (code: Int32, output: String)
        var isIdle: @Sendable () async -> Bool?
    }

    private(set) var status: Status = .notRegistered
    private(set) var changing = false
    private(set) var problem: String?
    private let backend: Backend
    private let defaults: UserDefaults
    private let now: () -> Date
    static let neverKey = "helper.neverOffer"
    static let remindKey = "helper.remindAfter"

    init(backend: Backend, defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.backend = backend; self.defaults = defaults; self.now = now
        refresh()
    }

    func refresh() { status = backend.status() }
    func openSettings() { backend.openSettings() }

    func enable() {
        guard !changing else { return }
        changing = true
        defer { changing = false; refresh() }
        problem = nil
        do {
            try backend.register()
            defaults.removeObject(forKey: Self.neverKey)
            defaults.removeObject(forKey: Self.remindKey)
            refresh()
            if status == .requiresApproval { backend.openSettings() }
        } catch { problem = Failure.registration.localizedDescription }
    }

    func disable() async {
        guard !changing else { return }
        changing = true
        defer { changing = false; refresh() }
        problem = nil
        do {
            try await backend.unregister()
            defaults.set(true, forKey: Self.neverKey)
        } catch { problem = Failure.registration.localizedDescription }
    }

    /// Called only when an already-confirmed action actually needs root.
    /// Declining keeps the existing, explicitly explained per-action prompt.
    func prepare() async throws -> Bool {
        refresh()
        if status == .enabled { return true }
        if status == .requiresApproval { throw Failure.approval }
        if status == .unavailable { return false }
        if defaults.bool(forKey: Self.neverKey) { return false }
        if let date = defaults.object(forKey: Self.remindKey) as? Date, date > now() { return false }
        switch await backend.choose() {
        case .later:
            defaults.set(now().addingTimeInterval(7 * 24 * 60 * 60), forKey: Self.remindKey)
            return false
        case .never:
            defaults.set(true, forKey: Self.neverKey)
            return false
        case .enable:
            enable()
            guard problem == nil else { throw Failure.registration }
            guard status == .enabled else { throw Failure.approval }
            return true
        }
    }

    func perform(_ argument: String) async -> (code: Int32, output: String) { await backend.perform(argument) }
    func isIdle() async -> Bool? { await backend.isIdle() }

    static func live() -> HelperServiceController? {
        #if SMOKE
        return nil
        #else
        guard let identity = HelperServiceIdentity.current(helper: false),
              Bundle.main.bundleIdentifier == identity.appID,
              FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/Contents/Library/LaunchDaemons/" + identity.plistName)
        else { return nil }
        let service = SMAppService.daemon(plistName: identity.plistName)
        return Self(backend: Backend(status: {
            switch service.status {
            case .enabled: .enabled
            case .requiresApproval: .requiresApproval
            case .notRegistered: .notRegistered
            default: .unavailable
            }
        }, register: { try service.register() }, unregister: { try await service.unregister() },
            openSettings: { SMAppService.openSystemSettingsLoginItems() }, choose: offer,
            perform: { await HelperConnection.perform($0, identity: identity) },
            isIdle: { await HelperConnection.isIdle(identity: identity) }), defaults: .standard)
        #endif
    }

    private static func offer() async -> Choice {
        let alert = NSAlert()
        alert.messageText = String(localized: "Enable MyMole's helper?")
        alert.informativeText = String(localized: "The helper handles approved app moves and system tasks without asking for an administrator password for every action. macOS asks you to approve it once. You still choose and confirm what MyMole removes. You can disable it in Settings → System Tasks.\n\nWithout the helper, this action continues with macOS's administrator prompt.")
        alert.addButton(withTitle: String(localized: "Enable Helper"))
        alert.addButton(withTitle: String(localized: "Remind Me Later"))
        alert.addButton(withTitle: String(localized: "No Thanks"))
        alert.buttons[1].keyEquivalent = "\u{1b}"
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn: return .enable
        case .alertThirdButtonReturn: return .never
        default: return .later
        }
    }
}
#endif
