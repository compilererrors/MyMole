import Foundation
import Synchronization
import Testing

@testable import StorageKit

@Suite struct AppListingPipelineTests {
    @Test func metadataArrivesBeforeAnyRecursiveMeasurement() throws {
        let box = try Sandbox()
        try makeApp(box, "Applications/Canvas.app", id: "org.example.Canvas", name: "Canvas")
        try makeApp(box, "Applications/Tiny.app", id: "org.example.Tiny", name: "Tiny")
        let progress = ScanProgress()
        let first = Mutex<AppListingStep?>(nil)
        let listing = AppFinder.list(in: [box.path + "/Applications"], progress: progress, workers: 2) { step in
            if step.measured == 0 {
                #expect(progress.files == 0)
                first.withLock { $0 = step }
            }
        }
        let metadata = try #require(first.withLock { $0 })
        #expect(metadata.apps.map(\.name) == ["Canvas", "Tiny"])
        #expect(metadata.apps.allSatisfy { $0.sizePending && $0.bytes == 0 && $0.version == "1.2" })
        #expect(listing.isComplete)
        #expect(listing.apps.allSatisfy { !$0.sizePending && $0.bytes > 0 })
    }

    @Test func stoppingAfterMetadataDoesNotWalkBundlesOrReplaceSavedSizes() throws {
        let box = try Sandbox()
        try makeApp(box, "Applications/Canvas.app", id: "org.example.Canvas")
        let folders = [box.path + "/Applications"]
        let base = box.url.appending(path: "saved")
        let earlier = AppFinder.list(in: folders)
        AppStore.save(earlier, folders: folders, base: base)
        let progress = ScanProgress()
        let stopped = AppFinder.list(in: folders, progress: progress) { _ in progress.cancel() }
        #expect(stopped.cancelled && !stopped.isComplete)
        #expect(stopped.apps.allSatisfy { $0.sizePending })
        #expect(progress.files == 0 && progress.folders == 0)
        AppStore.save(stopped, folders: folders, base: base)
        #expect(AppStore.load(folders: folders, base: base)?.apps == earlier.apps)
        // The cancellation token also reaches a walk inside a single app.
        let app = try #require(AppFinder.read(box.path + "/Applications/Canvas.app", progress: progress))
        #expect(app.incomplete && progress.files == 0)
    }

    @Test func anOlderSavedBundleDecodesWithoutPendingSizeState() throws {
        let data = Data(#"{"path":"/synthetic/Canvas.app","name":"Canvas","bundleID":"org.example.Canvas","version":"1","bytes":123,"fromAppStore":false,"incomplete":false}"#.utf8)
        let app = try JSONDecoder().decode(AppBundle.self, from: data)
        #expect(!app.sizePending && app.bytes == 123)
        #expect(try JSONDecoder().decode(AppBundle.self, from: JSONEncoder().encode(app)) == app)
    }

    @Test func duplicateSearchRootsDoNotDuplicateApps() throws {
        let box = try Sandbox()
        try makeApp(box, "Applications/Canvas.app", id: "org.example.Canvas")
        let folder = box.path + "/Applications"
        #expect(AppFinder.list(in: [folder, folder]).apps.count == 1)
    }
}
