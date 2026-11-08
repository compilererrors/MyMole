import Foundation
import Testing

@testable import StorageKit

/// Simulators and device backups in Deep Clean, in a home folder of the test's own.
@Suite struct CleanDevicesTests {
    private let devices = "Library/Developer/CoreSimulator/Devices"
    private let backups = "Library/Application Support/MobileSync/Backup"

    private func plist(_ dict: [String: Any], at path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0).write(to: URL(fileURLWithPath: path))
    }

    private func simulator(_ box: Sandbox, _ id: String, name: String, runtime: String, state: Int) throws {
        try plist(["name": name, "runtime": runtime, "state": state, "UDID": id], at: box.path + "/\(devices)/\(id)/device.plist")
        try box.file("\(devices)/\(id)/data/Containers/app.bin", bytes: 30_000)
    }

    @Test func aShutDownSimulatorIsOfferedByItsNameAndNeverChosen() throws {
        let box = try Sandbox()
        try simulator(box, "11111111-AAAA-4000-8000-000000000001", name: "Phone 16 Pro", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-2", state: 1)
        try simulator(box, "11111111-AAAA-4000-8000-000000000002", name: "Tablet Air", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-17-5", state: 3)
        try box.file("\(devices)/device_set.plist", bytes: 4_000)
        try box.file("\(devices)/no-description/data/x", bytes: 9_000)

        let found = CleanScanner.scan(home: box.path, workers: 2).filter { $0.category == .devices }
        // Only the one that says it's shut down: not the booted one, the set's index or a folder that says nothing.
        #expect(found.map(\.name) == ["Phone 16 Pro · iOS 18.2"])
        let one = try #require(found.first)
        #expect(one.safety == .review && !one.contentsOnly)
        #expect(one.path.hasSuffix("000000000001"))
        #expect(CleanScanner.isStillCandidate(one.path, home: box.path))

        // Booted since the scan: refused when it would go.
        try plist(["name": "Phone 16 Pro", "runtime": "x", "state": 3], at: one.path + "/device.plist")
        #expect(!CleanScanner.isStillCandidate(one.path, home: box.path))
        #expect(!CleanScanner.isStillCandidate(box.path + "/\(devices)/device_set.plist", home: box.path))
    }

    @Test func aSimulatorIsLeftWhileTheSimulatorRuns() throws {
        let box = try Sandbox()
        let path = box.path + "/\(devices)/11111111-AAAA-4000-8000-000000000001"
        #expect(CleanRules.inUse(path, home: box.path, running: ["Simulator"]))
        #expect(CleanRules.inUse(path, home: box.path, running: nil))
        #expect(!CleanRules.inUse(path, home: box.path, running: ["Finder"]))
    }

    @Test func aDeviceBackupIsOfferedByTheDevicesName() throws {
        let box = try Sandbox()
        try plist(["Device Name": "Test Phone", "Product Name": "Phone 15", "Last Backup Date": Date()], at: box.path + "/\(backups)/00008000-AAAA/Info.plist")
        try box.file("\(backups)/00008000-AAAA/ab/abcdef", bytes: 60_000)
        try box.file("\(backups)/00008000-BBBB/cd/cdef", bytes: 20_000)
        try box.file("\(backups)/stray.txt", bytes: 5_000)

        let found = CleanScanner.scan(home: box.path, workers: 2).filter { $0.category == .devices }
        // A backup without its description keeps its folder's name; a loose file isn't a backup.
        #expect(found.map(\.name) == ["Backup of Test Phone · Phone 15", "00008000-BBBB"])
        #expect(found.allSatisfy { $0.safety == .review })
        #expect(CleanScanner.isStillCandidate(box.path + "/\(backups)/00008000-AAAA", home: box.path))
        #expect(!CleanScanner.isStillCandidate(box.path + "/\(backups)/stray.txt", home: box.path))
    }

    @Test func aSavedResultFromBeforeTitlesStillLoads() throws {
        let old = #"{"path":"/h/Library/Caches/x","bytes":5,"modified":0,"category":"appCaches","safety":0,"reason":"r","contentsOnly":false,"incomplete":false}"#
        let c = try JSONDecoder().decode(CleanCandidate.self, from: Data(old.utf8))
        #expect(c.title == nil && c.name == "x")
    }
}
