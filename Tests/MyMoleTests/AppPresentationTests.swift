import Foundation
@testable import StorageKit
import Testing

@testable import MyMole

@Suite struct AppPresentationTests {
    @Test func pinnedAppsLeadBothPresentationsAndKeepTheirOriginalStatus() {
        let apps = [
            AppBundle(path: "/synthetic/Small.app", name: "Small", bundleID: "org.example.Small", version: nil, bytes: 10, fromAppStore: false),
            AppBundle(path: "/synthetic/Large.app", name: "Large", bundleID: "org.example.Large", version: nil, bytes: 1000, fromAppStore: false),
        ]
        for asList in [true, false] {
            let presentation = AppPresentation(apps, query: "", sort: .size, showMacOS: false, asList: asList,
                running: [apps[0].path], ownPath: nil, pinned: [apps[0].path])
            #expect(presentation.apps.map(\.path) == apps.map(\.path))
            #expect(presentation.totalBytes == 1010)
            if asList {
                #expect(presentation.rows.first?.pinned == true)
                #expect(presentation.rows.first?.badge == String(localized: "Open"))
            }
        }
    }
    @Test func preparedRowsFollowScopeAndBadgesWithoutLosingHiddenBatchChoices() {
        let apps = [
            AppBundle(path: "/synthetic/Editor.app", name: "Editor", bundleID: "org.synthetic.Editor", version: "2", bytes: 40, fromAppStore: false),
            AppBundle(path: "/synthetic/Viewer.app", name: "Viewer", bundleID: "org.synthetic.Viewer", version: nil, bytes: 80, fromAppStore: true),
            AppBundle(path: "/System/Applications/System.app", name: "System", bundleID: "org.synthetic.System", version: nil, bytes: 120, fromAppStore: false),
        ]
        let table = AppPresentation(apps, query: "Editor", sort: .size, showMacOS: false, asList: true,
                                    running: [apps[0].path], ownPath: nil)
        #expect(table.apps == [apps[0]] && table.rows.map(\.id) == [apps[0].path])
        #expect(table.hiddenMacOS == 1 && table.totalBytes == 40 && !table.measuring)
        #expect(table.byPath[apps[1].path] == apps[1])
        #expect(table.rows.first?.badge == String(localized: "Open"))
        let grid = AppPresentation(apps, query: "", sort: .size, showMacOS: true, asList: false, running: [], ownPath: nil)
        #expect(grid.apps.count == 3 && grid.hiddenMacOS == 0 && grid.rows.isEmpty)
    }

    @Test func orphanSelectionAndTotalsUseTheOriginalOrderAndIgnoreStalePaths() {
        let items = (0..<50).map { i in
            Orphan(leftover: Leftover(path: "/synthetic/cache/\(i)", bytes: Int64(i), place: "Caches"), bundleID: "org.absent.Item\(i)")
        }
        let data = OrphanDataset(items)
        let selected: Set<String> = [items[20].path, items[2].path, "/synthetic/stale"]
        #expect(data.selected(selected) == [items[2], items[20]])
        #expect(data.bytes(in: selected) == 22 && data.totalBytes == 1_225)
    }
}
