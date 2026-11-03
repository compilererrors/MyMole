import Foundation
import PrivilegedKit

// MyMole's privileged tool. macOS starts it as root, once per request, after
// the user enters an administrator's password in its standard prompt; it
// handles the one request given as its argument, prints the reply and exits.
// Nothing is installed and nothing keeps running.

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: \(PrivilegedTool.name) <request>\n".utf8))
    exit(64)
}
print(PrivilegedTool.output(PrivilegedTool.handle(argument: CommandLine.arguments[1])))
