import AppKit
import SwiftUI
import Testing

@testable import MyMole

@MainActor @Suite struct PaneTests {
    @Test func theMenuAndSidebarOfferTheSamePanes() {
        let shown = Pane.groups.flatMap(\.1)
        #expect(shown.allSatisfy { $0.isAvailable })
        #if APPSTORE
        #expect(!shown.contains(.systemClean) && !Pane.systemClean.isAvailable)
        #else
        #expect(shown.contains(.systemClean))
        #endif
    }

    @Test func shortcutsStayTheSameInBothEditions() {
        #expect(Pane.dashboard.shortcut == "1" && Pane.systemClean.shortcut == "3" && Pane.uninstall.shortcut == "4")
        #expect(Pane.history.shortcut == nil && Pane.settings.shortcut == nil)
        let keys = Pane.allCases.compactMap(\.shortcut)
        #expect(Set(keys.map(\.character)).count == keys.count)
    }
}

@Suite struct FlowTests {
    @Test func factsWrapInsteadOfBeingCutOff() {
        let sizes = [CGSize(width: 100, height: 26), CGSize(width: 80, height: 26), CGSize(width: 120, height: 28)]
        #expect(DSFlow.rows(sizes, width: 400, spacing: 8).map(\.items) == [[0, 1, 2]])
        let narrow = DSFlow.rows(sizes, width: 200, spacing: 8)
        #expect(narrow.map(\.items) == [[0, 1], [2]] && narrow[0].width == 188 && narrow[1].height == 28)
        // One wider than the row still gets a row of its own.
        #expect(DSFlow.rows([CGSize(width: 500, height: 20)], width: 100, spacing: 8).map(\.items) == [[0]])
        // Empty children (an `if` that's false) take no room.
        #expect(DSFlow.rows([.zero, CGSize(width: 10, height: 10)], width: 100, spacing: 8).map(\.items) == [[1]])
    }
}

@MainActor
@Suite struct DiskMapSplitTests {
    @Test func theListKeepsItsWidthWithinWhatBothSidesNeed() {
        // Never dragged: 44 % of the pane, at least the inspector's width.
        #expect(StorageView.listWidth(saved: 0, total: 1000) == 440)
        #expect(StorageView.listWidth(saved: 0, total: 600) == DS.Size.inspectorWidth)
        // Dragged: kept, but never past the narrowest list or chart.
        #expect(StorageView.listWidth(saved: 500, total: 1200) == 500)
        #expect(StorageView.listWidth(saved: 100, total: 1200) == DS.Size.inspectorWidth)
        #expect(StorageView.listWidth(saved: 2000, total: 1200) == 1200 - DS.Size.chartMinWidth - DS.Size.splitHandle)
    }

    /// Dragging the divider moves both panes on every pointer event but
    /// saves the width once, when the drag ends; a cancelled drag saves
    /// nothing. A save on every event drew the whole pane anew each frame.
    @MainActor @Test func draggingTheDividerSavesTheWidthOnlyWhenTheDragEnds() throws {
        var saved: [Double] = []
        let controller = ListSplitController(chart: AnyView(Color.clear), list: AnyView(Color.clear))
        controller.commit = { saved.append($0) }
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        let list = controller.list.view
        let start = list.frame.width
        for step in 1...30 { controller.handle.onChange(CGSize(width: -Double(step) * 2, height: 0)) }
        #expect(saved.isEmpty)
        #expect(abs(list.frame.width - (start + 60)) < 0.5)
        #expect(abs(controller.chart.view.frame.width + DS.Size.splitHandle + list.frame.width - 1_200) < 0.5)
        controller.handle.onEnd(.zero)
        #expect(saved == [Double(start + 60)])
        controller.handle.onChange(CGSize(width: -100, height: 0))
        controller.handle.onCancel()
        #expect(saved.count == 1 && abs(list.frame.width - (start + 60)) < 0.5)
    }
}
