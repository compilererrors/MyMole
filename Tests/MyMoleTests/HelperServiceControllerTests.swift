#if !APPSTORE
import Foundation
import PrivilegedKit
import StorageKit
import Synchronization
import Testing

@testable import MyMole

@MainActor @Suite struct HelperServiceControllerTests {
    final class Calls: Sendable {
        let state = Mutex((service: 0, prompt: 0, idle: Optional(true), code: Int32(0)))
    }

    @MainActor final class Fixture {
        let defaults: UserDefaults
        var state = HelperServiceController.Status.notRegistered
        var registeredState = HelperServiceController.Status.enabled
        var choice = HelperServiceController.Choice.enable
        var offers = 0, registrations = 0, removals = 0, settings = 0
        var failRegistration = false
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let calls = Calls()

        init(dir: URL) { defaults = testDefaults(in: dir) }

        lazy var helper = makeHelper()

        func makeHelper() -> HelperServiceController {
            let calls = calls
            return HelperServiceController(backend: .init(status: { [unowned self] in self.state }, register: { [unowned self] in
                self.registrations += 1
                if self.failRegistration { throw HelperServiceController.Failure.registration }
                self.state = self.registeredState
            }, unregister: { [unowned self] in self.removals += 1; self.state = .notRegistered },
                openSettings: { [unowned self] in self.settings += 1 }, choose: { [unowned self] in self.offers += 1; return self.choice },
                perform: { _ in
                    let code = calls.state.withLock { $0.service += 1; return $0.code }
                    return (code, code == 0 ? PrivilegedTool.output(.removal(RemovalReport())) : "")
                }, isIdle: { calls.state.withLock { $0.idle } }), defaults: defaults, now: { [unowned self] in self.clock })
        }

        func client() -> PrivilegedClient {
            let calls = calls
            return PrivilegedClient(helper: helper, toolPath: "/synthetic/MyMole.app/Contents/MacOS/MyMoleHelper", elevate: { _, _, _ in
                calls.state.withLock { $0.prompt += 1 }
                return (0, PrivilegedTool.output(.removal(RemovalReport())))
            })
        }
    }

    func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "helper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(Fixture(dir: dir))
    }

    @Test func anEnabledHelperAvoidsBothSetupAndAdministratorPrompts() async throws {
        try await withFixture { f in
            f.state = .enabled
            let client = f.client()
            _ = try await client.removeSystem(["/synthetic/Cache"])
            _ = try await client.removeSystem(["/synthetic/Cache"])
            #expect(f.offers == 0 && f.registrations == 0)
            #expect(f.calls.state.withLock { $0.service == 2 && $0.prompt == 0 })
        }
    }

    @Test func enablingIsExplicitAndUsesTheServiceOnlyAfterApproval() async throws {
        try await withFixture { f in
            f.registeredState = .requiresApproval
            let client = f.client()
            await #expect(throws: HelperServiceController.Failure.self) { try await client.removeSystem(["/synthetic/Cache"]) }
            #expect(f.offers == 1 && f.registrations == 1 && f.settings == 1)
            #expect(f.calls.state.withLock { $0.service == 0 && $0.prompt == 0 })
            #expect(!client.busy)
            // Returning from System Settings never repeats a destructive action.
            f.state = .enabled
            f.helper.refresh()
            #expect(f.calls.state.withLock { $0.service == 0 })
            _ = try await client.removeSystem(["/synthetic/Cache"])
            #expect(f.calls.state.withLock { $0.service == 1 && $0.prompt == 0 })
        }
    }

    @Test func approvedRegistrationCanProceedWithoutALegacyPrompt() async throws {
        try await withFixture { f in
            _ = try await f.client().removeSystem(["/synthetic/Cache"])
            #expect(f.offers == 1 && f.registrations == 1 && f.settings == 0)
            #expect(f.calls.state.withLock { $0.service == 1 && $0.prompt == 0 })
        }
    }

    @Test func remindLaterDefersOnlyTheOfferForSevenDays() async throws {
        try await withFixture { f in
            f.choice = .later
            let client = f.client()
            for _ in 0..<2 { _ = try await client.removeSystem(["/synthetic/Cache"]) }
            #expect(f.offers == 1 && f.registrations == 0)
            #expect(f.calls.state.withLock { $0.service == 0 && $0.prompt == 2 })
            f.clock.addTimeInterval(8 * 24 * 60 * 60)
            _ = try await client.removeSystem(["/synthetic/Cache"])
            #expect(f.offers == 2)
        }
    }

    @Test func noThanksPersistsAndSettingsCanEnableItLater() async throws {
        try await withFixture { f in
            f.choice = .never
            let usesService = try await f.helper.prepare()
            #expect(!usesService)
            let restarted = f.makeHelper()
            let restartedUsesService = try await restarted.prepare()
            #expect(!restartedUsesService)
            #expect(f.offers == 1 && f.registrations == 0)
            restarted.enable()
            let enabledUsesService = try await restarted.prepare()
            #expect(enabledUsesService)
            #expect(f.registrations == 1 && f.offers == 1)
        }
    }

    @Test func failedRegistrationNeverFallsBackToAnUnexpectedPasswordPrompt() async throws {
        try await withFixture { f in
            f.failRegistration = true
            await #expect(throws: HelperServiceController.Failure.self) { try await f.client().removeSystem(["/synthetic/Cache"]) }
            #expect(f.helper.problem != nil)
            #expect(f.calls.state.withLock { $0.service == 0 && $0.prompt == 0 })
        }
    }

    @Test func interruptedServiceRequestsAreNeverRetriedThroughThePrompt() async throws {
        try await withFixture { f in
            f.state = .enabled
            f.calls.state.withLock { $0.code = CommandRunner.stopUnverified; $0.idle = false }
            let client = f.client()
            await #expect(throws: PrivilegedClient.Failure.outcomeUnknown) { try await client.removeSystem(["/synthetic/Cache"]) }
            await #expect(throws: PrivilegedClient.Failure.outcomeUnknown) { try await client.removeSystem(["/synthetic/Cache"]) }
            #expect(f.calls.state.withLock { $0.service == 1 && $0.prompt == 0 })
            f.calls.state.withLock { $0.idle = nil }
            await client.recheckOutcome()
            #expect(client.outcomeUnknown)
            f.calls.state.withLock { $0.idle = true; $0.code = 0 }
            await client.recheckOutcome()
            #expect(!client.outcomeUnknown)
            _ = try await client.removeSystem(["/synthetic/Cache"])
            #expect(f.calls.state.withLock { $0.service == 2 && $0.prompt == 0 })
        }
    }

    @Test func disablingUnregistersAndKeepsTheOfferDismissed() async throws {
        try await withFixture { f in
            f.state = .enabled
            await f.helper.disable()
            #expect(f.removals == 1 && f.helper.status == .notRegistered)
            let usesService = try await f.helper.prepare()
            #expect(!usesService)
            #expect(f.offers == 0)
        }
    }

    @Test func anUnavailableServiceNeverOffersRegistration() async throws {
        try await withFixture { f in
            f.state = .unavailable
            let usesService = try await f.helper.prepare()
            #expect(!usesService)
            #expect(f.offers == 0 && f.registrations == 0)
        }
    }

    @Test func racingRepliesErrorsAndTimeoutsCompleteExactlyOnce() async {
        let result: (code: Int32, output: String) = await withCheckedContinuation { continuation in
            let pending = HelperConnection.Pending(continuation)
            DispatchQueue.concurrentPerform(iterations: 100) { index in
                pending.finish(code: Int32(index), output: String(index))
            }
        }
        #expect(result.output == String(result.code))
        #expect((0..<100).contains(result.code))
    }
}
#endif
