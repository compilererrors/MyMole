import ServiceManagement
import Testing

@testable import MyMole

@Suite struct LoginItemTests {
    @Test func theSwitchShowsWhatMacOSSays() {
        #expect(LoginItem.state(for: .enabled) == .on)
        #expect(LoginItem.state(for: .notRegistered) == .off)
        #expect(LoginItem.state(for: .notFound) == .off)
        #expect(LoginItem.state(for: .requiresApproval) == .needsApproval)
    }

    @Test func outsideAnAppBundleNothingIsRegistered() {
        #expect(!LoginItem.isAvailable && LoginItem.state == .unavailable)
        #expect(LoginItem.set(true) != nil)
        #expect(LoginItem.state == .unavailable)
    }

    @Test func itStartsInTheMenuBarOnlyWhenOpenedAtLoginWithTheItemOn() {
        #expect(LoginItem.startsInMenuBar(openedAtLogin: true, menuBar: true))
        // Without the menu bar item it has nowhere else to be: the window opens.
        #expect(!LoginItem.startsInMenuBar(openedAtLogin: true, menuBar: false))
        #expect(!LoginItem.startsInMenuBar(openedAtLogin: false, menuBar: true))
    }
}
