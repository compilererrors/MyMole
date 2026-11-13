import Foundation
import PrivilegedKit

// The direct edition supports an approved launchd service, or one-shot
// administrator execution for users who prefer not to enable the service.

#if !APPSTORE
if CommandLine.arguments == [CommandLine.arguments[0], "--serve"] {
    guard geteuid() == 0, let identity = HelperServiceIdentity.current(helper: true) else { exit(77) }
    let service = HelperService(identity: identity)
    let listener = NSXPCListener(machServiceName: identity.serviceID)
    listener.delegate = service
    listener.resume()
    withExtendedLifetime(service) { RunLoop.main.run() }
    exit(0)
}
#endif

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: \(PrivilegedTool.name) <request>\n".utf8))
    exit(64)
}
print(PrivilegedTool.output(PrivilegedTool.handle(argument: CommandLine.arguments[1])))
