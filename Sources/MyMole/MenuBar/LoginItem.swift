import AppKit
import CoreServices
import ServiceManagement

/// Opening MyMole at login. macOS keeps the switch, and the user can also
/// turn it off in System Settings → Login Items, so the state is read from
/// macOS every time and never kept in MyMole's own settings.
enum LoginItem {
    enum State: Equatable {
        case on, off
        /// Registered, but the user has to allow it in System Settings.
        case needsApproval
        /// Not an app bundle (a test run, `swift run`): there's nothing to register.
        case unavailable
    }

    static var isAvailable: Bool { Notifier.isAvailable }

    static var state: State { isAvailable ? state(for: SMAppService.mainApp.status) : .unavailable }

    static func state(for status: SMAppService.Status) -> State {
        switch status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notRegistered, .notFound: .off
        @unknown default: .off
        }
    }

    /// Turns it on or off; returns why it couldn't, or nil.
    static func set(_ on: Bool) -> String? {
        guard isAvailable else { return String(localized: "Only the MyMole app can open at login.") }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Whether macOS opened MyMole as a login item. The launch event says
    /// so, and it's only there while the app finishes launching.
    @MainActor static func wasOpenedAtLogin() -> Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Opened at login with the menu bar item on, MyMole starts there: no
    /// window, no Dock icon, no scans. Without the item it has nowhere else
    /// to be, so its window opens as usual.
    static func startsInMenuBar(openedAtLogin: Bool, menuBar: Bool) -> Bool { openedAtLogin && menuBar }
}
