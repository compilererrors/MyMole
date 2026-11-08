import Foundation
import Testing

@testable import StorageKit

/// The disk beyond the map, read with a runner of the test's own.
@Suite struct DiskSpaceTests {
    @Test func readsTheVolumeAndItsSnapshots() throws {
        let box = try Sandbox()
        let runner = CommandRunner(
            run: { exe, args in
                #expect(exe == DiskSpace.tmutil && args.first == "listlocalsnapshots")
                return (0, "Snapshots for disk /:\ncom.apple.TimeMachine.2026-11-06-010203.local\ncom.apple.TimeMachine.2026-11-06-020304.local\n")
            },
            exists: { _ in true })
        let space = try #require(DiskSpace.read(volumeOf: box.path, runner: runner))
        #expect(space.total > 0 && space.used > 0 && space.used <= space.total && space.purgeable >= 0)
        #expect(space.snapshots == ["com.apple.TimeMachine.2026-11-06-010203.local", "com.apple.TimeMachine.2026-11-06-020304.local"])
    }

    @Test func snapshotsThatCantBeListedAreUnknownNotNone() throws {
        let box = try Sandbox()
        let failing = CommandRunner(run: { _, _ in (1, "") }, exists: { _ in true })
        #expect(DiskSpace.read(volumeOf: box.path, runner: failing)?.snapshots == nil)
        let missing = CommandRunner(run: { _, _ in (0, "") }, exists: { _ in false })
        #expect(DiskSpace.read(volumeOf: box.path, runner: missing)?.snapshots == nil)
    }

    @Test func whatsOutsideTheMapIsNeverNegative() {
        let space = DiskSpace(total: 1_000, used: 600, purgeable: 50, snapshots: [])
        #expect(space.outside(mapped: 400) == 200)
        #expect(space.outside(mapped: 900) == 0)
    }
}
