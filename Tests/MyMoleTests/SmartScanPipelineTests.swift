import Foundation
import StorageKit
import Testing

@testable import MyMole

@MainActor @Suite struct SmartScanPipelineTests {
    @Test(arguments: [false, true])
    func scanIncludesRealDuplicateSearchAfterCleanupWalks(together: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "smart-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["Documents", "Downloads"] {
            let url = root.appending(path: folder + "/example.bin")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 3, count: 40_000).write(to: url)
        }
        let model = DuplicatesModel(home: root.path, roots: [root.appending(path: "Documents").path, root.appending(path: "Downloads").path], minimum: 1,
                                    logURL: root.appending(path: "history.json"), trash: testBin(root), scanBudget: ScanBudget(slots: 1))
        model.protections = UserProtections(root: root.appending(path: "protections"))
        var events: [String] = []
        var jobs: [Pane: SmartScanPipeline.Job] = [:]
        for pane in SmartScanPipeline.modules(system: true) {
            jobs[pane] = .init(start: { events.append("start-" + pane.rawValue) }, wait: { events.append("end-" + pane.rawValue) })
        }
        jobs[.duplicates] = .init(start: {
            #expect(events.contains("end-installer") && events.contains("end-clean"))
            events.append("start-duplicates")
            model.scan()
        }, wait: { await model.scanJob?.value })
        await SmartScanPipeline(jobs: jobs).run(together: together, allowed: { true })
        #expect(Array(events.prefix(2)) == ["start-optimize", "start-uninstall"])
        #expect(events.filter { $0 == "start-duplicates" }.count == 1)
        #expect(model.groups.count == 1 && model.groups.first?.files.count == 2)
        #expect(model.scannedAt != nil && !model.scanning && model.chosen.isEmpty)
        #expect(SmartScanPipeline.modules(system: false).contains(.duplicates))
        #expect(!SmartScanPipeline.modules(system: false).contains(.systemClean))
    }

    @Test func accessRevokedBetweenStagesPreventsTheDuplicateWalk() async {
        var allowed = true
        var ranDuplicates = false
        let pipeline = SmartScanPipeline(jobs: [
            .clean: .init(start: {}, wait: { allowed = false }),
            .duplicates: .init(start: { ranDuplicates = true }, wait: {}),
        ])
        await pipeline.run(together: true, allowed: { allowed })
        #expect(!ranDuplicates)
    }
}
