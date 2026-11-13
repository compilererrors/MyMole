import Foundation
@testable import StorageKit
import SwiftUI

@testable import MyMole

@MainActor func syntheticDiskRenderingModel(in directory: URL) async throws -> StorageModel {
    let root = Folder(name: "Synthetic disk", parent: nil, rootPath: "/synthetic/disk")
    root.subfolders = (0..<12).map { branch in
        let folder = Folder(name: "Synthetic folder \(branch)", parent: root)
        folder.listedFiles = (0..<80).map { index in
            FileItem(name: "Generated sample \(index).bin", size: Int64((branch + 1) * (index + 1)) * 1_048_576,
                     modified: .distantPast, kind: .other)
        }
        folder.ownBytes[.other] = folder.listedFiles.reduce(0) { $0 + $1.size }
        folder.finish()
        return folder
    }
    root.finish()
    let export = directory.appending(path: "synthetic.mymolescan")
    try ScanExport(of: root).data().write(to: export)
    let model = StorageModel()
    model.snapshotBase = directory.appending(path: "snapshots")
    model.protections = UserProtections(root: directory.appending(path: "protections"))
    model.logURL = directory.appending(path: "history.json")
    model.trashBackend = testBin(directory)
    model.jobs = TrashJobs()
    // Imported geometry is read-only and cannot authorize a filesystem move.
    await model.open(exported: export)
    return model
}

/// A map the size of a real home folder: `branches` top folders, each
/// with `children` folders of `files` large files and one more level below.
@MainActor func largeSyntheticDiskModel(in directory: URL, branches: Int = 40, children: Int = 40, files: Int = 12) async throws -> StorageModel {
    let root = Folder(name: "Synthetic home", parent: nil, rootPath: "/synthetic/home")
    root.subfolders = (0..<branches).map { b in
        let top = Folder(name: "Synthetic area \(b)", parent: root)
        top.subfolders = (0..<children).map { c in
            let mid = Folder(name: "Synthetic folder \(b)-\(c)", parent: top)
            mid.subfolders = (0..<3).map { d in
                let leaf = Folder(name: "Synthetic leaf \(d)", parent: mid)
                leaf.listedFiles = (0..<files).map { f in
                    FileItem(name: "Generated \(f).bin", size: Int64((b + 1) * (c + 2) * (d + 1) * (f + 1)) * 1_048_576, modified: .distantPast, kind: .other)
                }
                leaf.ownBytes[.other] = leaf.listedFiles.reduce(0) { $0 + $1.size }
                leaf.finish()
                return leaf
            }
            mid.finish()
            return mid
        }
        top.finish()
        return top
    }
    root.finish()
    let export = directory.appending(path: "large-synthetic.mymolescan")
    try ScanExport(of: root).data().write(to: export)
    let model = StorageModel()
    model.snapshotBase = directory.appending(path: "snapshots")
    model.protections = UserProtections(root: directory.appending(path: "protections"))
    model.logURL = directory.appending(path: "history.json")
    model.trashBackend = testBin(directory)
    model.jobs = TrashJobs()
    await model.open(exported: export)
    return model
}

struct UIDiskRenderingView: View {
    @Bindable var preferences: UISplitPreferences
    let model: StorageModel
    let chart: StorageModel.Chart

    var body: some View {
        // The same split as the Disk Map pane's.
        ListSplit(width: $preferences.width) {
            switch chart {
            case .rings: SunburstChart(model: model)
            case .wheel: SliceChart(model: model, style: .wheel)
            case .pie: SliceChart(model: model, style: .pie)
            case .boxes: TreemapChart(model: model)
            case .columns: ColumnsChart(model: model)
            case .bars: BarsChart(model: model)
            }
        } list: {
            InspectorList(model: model)
        }
    }
}

/// The test process's first window pays once for AppKit, SwiftUI, the window
/// server connection, fonts, symbols and the charts' shared drawing path. A
/// running app has paid that at launch, before anyone switches charts, so
/// it's paid here first, with a chart on its own map: the measured cases'
/// maps and their layout caches stay cold.
@MainActor enum DiskRenderingWarmUp {
    private static var done = false

    static func once(in directory: URL) async throws {
        guard !done else { return }
        done = true
        let warmUp = directory.appending(path: "warm-up")
        try FileManager.default.createDirectory(at: warmUp, withIntermediateDirectories: true)
        let model = try await syntheticDiskRenderingModel(in: warmUp)
        let ui = UIInteractionWindow(UIDiskRenderingView(preferences: UISplitPreferences(), model: model, chart: .bars), width: 1_400)
        defer { ui.close() }
        try await ui.settle()
    }
}
