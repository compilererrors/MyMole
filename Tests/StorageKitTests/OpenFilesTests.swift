import Foundation
import Testing

@testable import StorageKit

/// Which programs have a file open, on a file of the test's own.
@Suite struct OpenFilesTests {
    @Test func aFileHeldByAnOwnedProcessIsSeenAndOneNobodyHoldsIsnt() throws {
        let box = try Sandbox()
        try box.file("disk.img", bytes: 4_000)
        try box.file("idle.img", bytes: 4_000)
        // Other suites continually open and close descriptors in the test
        // runner. Give this probe an owned process with a stable descriptor
        // list, as an app holding a disk image would have. EOF ends it.
        let holder = Process()
        let input = Pipe(), output = Pipe()
        holder.executableURL = URL(fileURLWithPath: "/bin/sh")
        holder.arguments = ["-c", "exec 3< \"$1\"; printf ready; read line || :", "probe", box.path + "/disk.img"]
        holder.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        holder.standardInput = input
        holder.standardOutput = output
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        defer {
            try? input.fileHandleForWriting.close()
            holder.waitUntilExit()
        }
        #expect(output.fileHandleForReading.readData(ofLength: 5) == Data("ready".utf8))
        #expect(OpenFiles.users(of: box.path + "/disk.img", excluding: 0)?.isEmpty == false)
        #expect(OpenFiles.users(of: box.path + "/disk.img")?.isEmpty == false)
        #expect(OpenFiles.users(of: box.path + "/disk.img", excluding: holder.processIdentifier) == [])
        #expect(OpenFiles.users(of: box.path + "/idle.img", excluding: 0) == [])
    }
}
