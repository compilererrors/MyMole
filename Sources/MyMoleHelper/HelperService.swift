#if !APPSTORE
import Foundation
import PrivilegedKit
import SystemConfiguration

/// launchd starts this service on demand after SMAppService approval.
/// Every operation still passes the existing root-side validation and lock.
final class HelperService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let identity: HelperServiceIdentity

    init(identity: HelperServiceIdentity) { self.identity = identity }

    static func consoleUID() -> uid_t? {
        var uid: uid_t = 0, gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid), name as String != "loginwindow" else { return nil }
        return uid
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard HelperServiceIdentity.acceptsUser(connection.effectiveUserIdentifier, consoleUID: Self.consoleUID()) else { return false }
        connection.setCodeSigningRequirement(identity.requirement(helper: false))
        connection.exportedInterface = NSXPCInterface(with: HelperServiceProtocol.self)
        connection.exportedObject = Endpoint(uid: connection.effectiveUserIdentifier)
        connection.resume()
        return true
    }

    final class Endpoint: NSObject, HelperServiceProtocol, @unchecked Sendable {
        private let uid: uid_t
        // ApplicationTrash temporarily changes euid, so ALL requests from ALL
        // connections share one worker. No filesystem work runs on XPC threads.
        private static let worker = DispatchQueue(label: "MyMoleHelper.requests")
        private static let gate = NSLock()
        nonisolated(unsafe) private static var running = false

        init(uid: uid_t) { self.uid = uid }

        func perform(_ argument: String, reply: @escaping (String) -> Void) {
            guard HelperServiceIdentity.acceptsRequest(argument, uid: uid),
                  HelperServiceIdentity.acceptsUser(uid, consoleUID: HelperService.consoleUID()) else {
                reply(PrivilegedTool.output(.refused("The request or active user could not be verified."))); return
            }
            let acquired = Self.gate.withLock {
                guard !Self.running else { return false }
                Self.running = true
                return true
            }
            guard acquired else {
                reply(PrivilegedTool.output(.refused("Another MyMole system task is still running, so nothing was changed."))); return
            }
            let response = Response(reply)
            Self.worker.async { [uid] in
                let result: PrivilegedReply
                if HelperServiceIdentity.acceptsUser(uid, consoleUID: HelperService.consoleUID()) {
                    result = PrivilegedTool.handle(argument: argument)
                } else {
                    result = .refused("The active user changed before the task started.")
                }
                Self.gate.withLock { Self.running = false }
                response.send(PrivilegedTool.output(result))
            }
        }

        func status(reply: @escaping (String) -> Void) {
            guard HelperServiceIdentity.acceptsUser(uid, consoleUID: HelperService.consoleUID()) else { reply("unknown"); return }
            let idle = Self.gate.withLock { !Self.running && PrivilegedTool.isIdle() }
            reply(idle ? "idle" : "running")
        }
    }

    private final class Response: @unchecked Sendable {
        let send: (String) -> Void
        init(_ send: @escaping (String) -> Void) { self.send = send }
    }
}
#endif
