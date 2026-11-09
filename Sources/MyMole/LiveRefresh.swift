import AppKit
import StorageKit
import SwiftUI

/// One visible owner's reads, serialized across events, timer ticks and reappearance.
/// Events during a read collapse to one pending read; cancellation cannot restart it.
@MainActor final class LiveRefresh {
    private var session: UUID?
    private var continuation: AsyncStream<Void>.Continuation?
    private var worker: Task<Void, Never>?
    private var enabled = true

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled { request() }
    }

    func request() {
        if enabled { continuation?.yield(()) }
    }

    func observe(every interval: Duration, update: @escaping @MainActor () async -> Void) async {
        guard !Task.isCancelled else { return }
        let previous = worker
        previous?.cancel()
        let id = UUID()
        let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        session = id
        continuation = events.continuation
        request()
        let job = Task { [self] in
            // A cancelled, noninterruptible filesystem read may still be finishing.
            await previous?.value
            var timer: Task<Void, Never>?
            defer { timer?.cancel(); events.continuation.finish() }
            for await _ in events.stream {
                guard !Task.isCancelled, session == id else { return }
                timer?.cancel()
                guard enabled else { continue }
                await update()
                guard !Task.isCancelled, session == id, enabled else { continue }
                timer = Task { [weak self] in
                    do { try await Task.sleep(for: interval) } catch { return }
                    guard !Task.isCancelled, let self, self.session == id else { return }
                    self.request()
                }
            }
        }
        worker = job
        await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
        if session == id {
            continuation = nil
            session = nil
            worker = nil
        }
    }
}

struct LiveRefreshEvents: OptionSet {
    let rawValue: Int
    static let applications = Self(rawValue: 1 << 0)
    static let volumes = Self(rawValue: 1 << 1)
    static let protections = Self(rawValue: 1 << 2)
}

private struct LiveRefreshModifier: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @State private var refresh = LiveRefresh()
    let interval: Duration
    let events: LiveRefreshEvents
    let update: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content
            .task {
                await refresh.observe(every: interval) {
                    guard NSApp.isActive, !NSApp.isHidden, NSApp.windows.contains(where: {
                        $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
                    }) else { return }
                    await update()
                }
            }
            .onChange(of: phase, initial: true) { _, phase in refresh.setEnabled(phase == .active) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refresh.setEnabled(true)
                refresh.request()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in refresh.setEnabled(false) }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in refresh.request() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in refresh.request() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in refresh.request() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
                if events.contains(.applications) { refresh.request() }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
                if events.contains(.applications) { refresh.request() }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
                if events.contains(.volumes) { refresh.request() }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
                if events.contains(.volumes) { refresh.request() }
            }
            .onReceive(NotificationCenter.default.publisher(for: KeepChanges.name)) { _ in
                if events.contains(.protections) { refresh.request() }
            }
    }
}

extension View {
    func liveRefresh(every interval: Duration = .seconds(1), events: LiveRefreshEvents = .applications,
                     update: @escaping @MainActor () async -> Void) -> some View {
        modifier(LiveRefreshModifier(interval: interval, events: events, update: update))
    }
}
