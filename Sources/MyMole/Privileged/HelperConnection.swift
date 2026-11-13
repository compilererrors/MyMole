#if !APPSTORE
import Foundation
import PrivilegedKit
import StorageKit

enum HelperConnection {
    static func perform(_ argument: String, identity: HelperServiceIdentity) async -> (code: Int32, output: String) {
        await call(identity: identity, argument: argument, timeout: 30 * 60)
    }

    static func isIdle(identity: HelperServiceIdentity) async -> Bool? {
        let result = await call(identity: identity, argument: nil, timeout: 3)
        guard result.code == 0 else { return nil }
        return result.output == "idle" ? true : result.output == "running" ? false : nil
    }

    private static func call(identity: HelperServiceIdentity, argument: String?, timeout: TimeInterval) async -> (code: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let request = Pending(continuation)
            let connection = NSXPCConnection(machServiceName: identity.serviceID, options: .privileged)
            connection.setCodeSigningRequirement(identity.requirement(helper: true))
            connection.remoteObjectInterface = NSXPCInterface(with: HelperServiceProtocol.self)
            connection.invalidationHandler = { request.finish(code: CommandRunner.stopUnverified, output: "") }
            connection.interruptionHandler = { request.finish(code: CommandRunner.stopUnverified, output: "") }
            request.start(connection, timeout: timeout)
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                request.finish(code: CommandRunner.stopUnverified, output: "")
            }) as? HelperServiceProtocol else {
                request.finish(code: CommandRunner.stopUnverified, output: ""); return
            }
            if let argument {
                proxy.perform(argument) { request.finish(code: 0, output: $0) }
            } else {
                proxy.status { request.finish(code: 0, output: $0) }
            }
        }
    }

    /// XPC errors, invalidation, timeout and reply can race. Resume once and
    /// never retry a destructive request whose outcome is unknown.
    final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(code: Int32, output: String), Never>?
        private var connection: NSXPCConnection?
        private var timer: DispatchSourceTimer?

        init(_ continuation: CheckedContinuation<(code: Int32, output: String), Never>) { self.continuation = continuation }

        func start(_ connection: NSXPCConnection, timeout: TimeInterval) {
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak self] in self?.finish(code: CommandRunner.timedOut, output: "") }
            lock.withLock { self.connection = connection; self.timer = timer }
            timer.resume()
        }

        func finish(code: Int32, output: String) {
            let completion = lock.withLock { () -> (CheckedContinuation<(code: Int32, output: String), Never>, NSXPCConnection?)? in
                guard let continuation else { return nil }
                self.continuation = nil
                timer?.cancel(); timer = nil
                let connection = self.connection
                self.connection = nil
                return (continuation, connection)
            }
            guard let (continuation, connection) = completion else { return }
            connection?.invalidate()
            continuation.resume(returning: (code, output))
        }
    }
}
#endif
