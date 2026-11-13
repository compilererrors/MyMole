#if DEBUG
import AppKit
import CoreTransferable
import SwiftUI
import StorageKit
import Testing

@testable import MyMole

@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MYMOLE_UI_E2E"] == "1"))
struct UIInteractionEndToEndTests {
    @Test func resizeReturningToOriginDoesNotClickAndShortDragsDoNotLeakState() async throws {
        let files = try EndToEndFixture()
        let state = UIStatusPreferences(defaults: testDefaults(in: files.root))
        let ui = UIInteractionWindow(UIStatusFixtureView(preferences: state))
        let diskState = UISplitPreferences()
        let disk = UIInteractionWindow(UIDiskSplitFixtureView(preferences: diskState))
        defer { ui.close(); disk.close() }
        try await ui.settle()
        try await disk.settle()
        let saved = state.layout
        let handle = try #require(ui.element("status.resize.cpu").object as? HorizontalDragHandleView)
        let start = NSPoint(x: handle.bounds.midX, y: handle.bounds.midY)
        try ui.trackMouse(in: handle, from: start, through: [NSPoint(x: start.x + 90, y: start.y), start])
        ui.settleTracking()
        #expect(state.layout == saved)
        try disk.drag("storage.list-width", by: NSSize(width: 3, height: 0))
        #expect(abs(diskState.width - 437) < 0.5)
        try disk.drag("storage.list-width", by: NSSize(width: -40, height: 0))
        #expect(abs(diskState.width - 477) < 0.5)
        print("ui-e2e resize.return-and-short-drag-state")
    }
    @Test func scanSpeedAccessibilityResetAndPersistence() async throws {
        let files = try EndToEndFixture()
        let before = try files.contents()
        let state = UIScanSpeedPreferences(defaults: testDefaults(in: files.root))
        state.value = 1
        let ui = UIInteractionWindow(ScanSpeedControl(performance: state.binding).padding(24), width: 600, height: 240)
        defer { ui.close() }
        try await ui.settle()
        for expected in 2...PerformanceLevel.allCases.count {
            try ui.element("settings.scan-speed").adjust(1)
            ui.settleTracking()
            #expect(state.value == expected)
        }
        #expect(state.value == PerformanceLevel.hyperspeed.rawValue)
        // Maximum, one below Hyperspeed, is the default, so Reset appears away from it.
        try ui.element("settings.scan-speed").adjust(-1)
        ui.settleTracking()
        #expect(state.value == PerformanceLevel.full.rawValue)
        try ui.element("settings.scan-speed").adjust(-1)
        ui.settleTracking()
        #expect(state.value == PerformanceLevel.fast.rawValue)
        #expect(try ui.element("settings.scan-speed.reset").accessibilityPerformPress())
        ui.settleTracking()
        #expect(state.value == PerformanceLevel.standard.rawValue)
        #expect(UIScanSpeedPreferences(defaults: testDefaults(in: files.root)).value == state.value)
        #expect(try files.contents() == before)
        print("ui-e2e settings.scan-speed.accessibility-reset-persistence")
    }
    @Test func uninstallConfirmationMovesOnlyOwnedFixtureAndUndoRestoresBytes() async throws {
        let files = try EndToEndFixture()
        let path = try files.app()
        let kept = try files.file("Documents/never-selected.bin")
        _ = try files.file("Library/Caches/com.example.SyntheticEditor/cache.bin")
        let before = try files.contents()
        let model = AppsModel(home: files.home, folders: [files.home + "/Applications"],
                              base: files.root.appending(path: "apps"), logURL: files.log,
                              recycle: { paths in Trasher.moveToTrash(paths, through: .init(still: { _ in true }, protections: TrashGate.keepsNothing), backend: files.backend) },
                              isRunning: { _ in false }, otherCopies: { _ in [] },
                              system: .init(base: files.home + "/System", isReady: { false }, remove: { _, _, _ in .init() }),
                              trash: files.backend, protections: files.protections, imageOf: { _ in nil },
                              eject: { _ in "Disabled in UI verification" }, identityReaders: .init(groups: { _ in [] }), runtimeRoots: [])
        model.jobs = files.jobs
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first)
        _ = await model.leftovers(for: app)
        let ui = UIInteractionWindow(UninstallSheet(model: model, app: app).defaultAppStorage(testDefaults(in: files.root)), width: 760)
        defer { ui.close() }
        try await ui.settle()
        #expect(try ui.element("uninstall.submit").accessibilityPerformPress())
        try await ui.settle()
        #expect(try ui.element("confirmation.cancel").accessibilityPerformPress())
        try await files.wait { ui.window.sheets.isEmpty }
        try await ui.settle()
        #expect(try files.contents() == before)
        #expect(try ui.element("uninstall.submit").accessibilityPerformPress())
        try await ui.settle()
        #expect(try ui.element("confirmation.accept").accessibilityPerformPress())
        try await files.wait { !model.uninstalling && !files.exists(path) }
        #expect(files.exists(kept) && model.canUndo)
        model.undoUninstall()
        await model.undoJob?.value
        try await files.wait { files.exists(path) }
        #expect(try files.contents() == before)
        print("ui-e2e uninstall.confirm-cancel-owned-trash-restore")
    }
    @Test func inspectorNativeDividerMouseTracking() async throws {
        _ = try EndToEndFixture()
        let controller = InspectorSplitController(content: AnyView(Text("Synthetic results")), inspector: AnyView(Text("Synthetic inspector")))
        let ui = UIInteractionWindow(Text("Synthetic workspace"), width: 1_200, height: 600)
        ui.window.contentViewController = controller
        defer { ui.close() }
        controller.view.setFrameSize(NSSize(width: 1_200, height: 600))
        try await ui.settle()
        let split = controller.splitView
        let identities = controller.children.map(ObjectIdentifier.init)
        let initial = controller.inspector.view.frame.width
        let start = NSPoint(x: controller.content.view.frame.maxX + 0.5, y: split.bounds.midY)
        let widths: [CGFloat] = [460, 500, 520, 480]
        try ui.trackMouse(in: split, from: start, through: widths.map {
            NSPoint(x: split.bounds.width - split.dividerThickness - $0 + 0.5, y: start.y)
        })
        #expect(abs(controller.inspector.view.frame.width - 480) <= 2)
        #expect(abs(controller.inspector.view.frame.width - initial) > 20)
        split.setFrameSize(NSSize(width: 721, height: 600))
        split.adjustSubviews()
        split.setFrameSize(NSSize(width: 1_200, height: 600))
        split.adjustSubviews()
        #expect(abs(controller.inspector.view.frame.width - 480) <= 2)
        #expect(controller.children.map(ObjectIdentifier.init) == identities)
        #expect(!split.inLiveResize)
        print("ui-e2e inspector.divider.mouse-width-restoration")
    }

    @Test func tableNativeHeadersMenusSelectionAndKeyboard() async throws {
        let files = try EndToEndFixture()
        let contentBefore = try files.contents()
        let f = try await UINativeTableFixture(defaults: testDefaults(in: files.root))
        defer { f.close() }
        let column = f.table.tableColumns[1]
        let width = column.width
        let otherWidths = f.table.tableColumns.dropFirst(2).map(\.width)
        try f.resizeColumn(1, by: 70)
        #expect(column.width >= width + 60)
        #expect(f.table.tableColumns.dropFirst(2).map(\.width) == otherWidths)
        let order = f.table.tableColumns.map(\.identifier)
        try f.reorderColumn(1, to: 2)
        try f.reorderColumn(2, to: 1)
        #expect(f.table.tableColumns.map(\.identifier) == order)
        #expect(column.width >= width + 60)
        try f.invokeMenu(column.title)
        #expect(column.isHidden)
        try f.invokeMenu(String(localized: "Show All Columns"))
        #expect(!column.isHidden)
        #expect(column.width >= width + 60)
        try f.invokeMenu(String(localized: "Fit Visible Contents"))
        #expect(f.table.tableColumns.allSatisfy { $0.width >= $0.minWidth && $0.width <= $0.maxWidth })
        let rows = try #require(f.table.perform(NSSelectorFromString("accessibilityRows"))?.takeUnretainedValue() as? NSArray)
        try #require(rows.count > 2)
        _ = f.table.perform(NSSelectorFromString("setAccessibilitySelectedRows:"), with: [rows[2]])
        #expect(f.table.selectedRow == 2)
        f.ui.window.makeFirstResponder(f.table)
        try f.ui.key(51, characters: "\u{7f}")
        #expect(f.marks.count == 1)
        #expect(try files.contents() == contentBefore)
        print("ui-e2e table.header-mouse-reorder-menu-selection-keyboard")
    }
    @Test func statusWidthMouseKeyboardAndPersistence() async throws {
        let files = try EndToEndFixture()
        let defaults = testDefaults(in: files.root)
        let state = UIStatusPreferences(defaults: defaults)
        let ui = UIInteractionWindow(UIStatusFixtureView(preferences: state))
        defer { ui.close() }
        try await ui.settle()
        let before = try ui.element("status.card.cpu").accessibilityFrame()
        try ui.drag("status.resize.cpu", by: NSSize(width: 90, height: 0))
        #expect(state.layout.visible.first { $0.id == .cpu }?.size == .wide)
        let after = try ui.element("status.card.cpu").accessibilityFrame()
        #expect(after.width > before.width * 1.5)
        try ui.click("status.resize.cpu")
        #expect(state.layout.visible.first { $0.id == .cpu }?.size == .standard)
        try ui.key(124, characters: "\u{F703}")
        ui.settleTracking()
        #expect(state.layout.visible.first { $0.id == .cpu }?.size == .wide)
        #expect(UIStatusPreferences(defaults: testDefaults(in: files.root)).layout == state.layout)
        print("ui-e2e status.resize.mouse-keyboard-persistence")
    }

    @Test func statusEditorUsesRealControls() async throws {
        let files = try EndToEndFixture()
        let state = UIStatusPreferences(defaults: testDefaults(in: files.root))
        let ui = UIInteractionWindow(UIStatusFixtureView(preferences: state, editor: true))
        defer { ui.close() }
        try await ui.settle()
        #expect(try ui.element("status.visible.cpu").accessibilityPerformPress())
        try await ui.settle()
        #expect(state.layout.hidden.contains { $0.id == .cpu })
        #expect(try ui.element("status.later.cpu").accessibilityPerformPress())
        try await ui.settle()
        #expect(state.layout.cards[1].id == .cpu)
        #expect(try ui.element("status.show-all").accessibilityPerformPress())
        try await ui.settle()
        #expect(state.layout.hidden.isEmpty && state.layout.cards[1].id == .cpu)
        #expect(try ui.element("status.restore-default").accessibilityPerformPress())
        try await ui.settle()
        #expect(state.layout == StatusLayout())
        #expect(UIStatusPreferences(defaults: testDefaults(in: files.root)).layout == state.layout)
        print("ui-e2e status.editor.visibility-order-persistence")
    }

    @Test func everyStatusCardResizesAndNarrowWindowsDisableWidthEdits() async throws {
        let files = try EndToEndFixture()
        let state = UIStatusPreferences(defaults: testDefaults(in: files.root))
        let ui = UIInteractionWindow(UIStatusFixtureView(preferences: state))
        defer { ui.close() }
        try await ui.settle()
        for id in StatusCardID.allCases {
            let handleID = "status.resize." + id.rawValue
            try ui.reveal(handleID)
            let original = try #require(ui.element(handleID).object as? HorizontalDragHandleView)
            try ui.drag(handleID, by: NSSize(width: 90, height: 0))
            #expect(state.layout.cards.first { $0.id == id }?.size == .wide)
            try ui.drag(handleID, by: NSSize(width: -90, height: 0))
            #expect(state.layout.cards.first { $0.id == id }?.size == .standard)
            #expect(try ui.element(handleID).object === original)
        }
        let saved = state.layout
        ui.window.setContentSize(NSSize(width: 430, height: 800))
        ui.settleTracking()
        let handle = try #require(ui.element("status.resize.cpu").object as? HorizontalDragHandleView)
        #expect(!handle.isEnabled && !handle.accessibilityPerformPress())
        #expect(!handle.accessibilityPerformIncrement())
        #expect(state.layout == saved)
        ui.window.setContentSize(NSSize(width: 1_100, height: 800))
        ui.settleTracking()
        #expect(handle.isEnabled)
        #expect(UIStatusPreferences(defaults: testDefaults(in: files.root)).layout == saved)
        print("ui-e2e status.all-cards.resize-narrow-identity")
    }

    @Test func cancellingNativeResizeRestoresPreferences() async throws {
        let files = try EndToEndFixture()
        let state = UIStatusPreferences(defaults: testDefaults(in: files.root))
        let ui = UIInteractionWindow(UIStatusFixtureView(preferences: state))
        let diskState = UISplitPreferences()
        let disk = UIInteractionWindow(UIDiskSplitFixtureView(preferences: diskState))
        defer { ui.close(); disk.close() }
        try await ui.settle()
        try await disk.settle()
        let saved = state.layout
        try ui.drag("status.resize.cpu", by: NSSize(width: 100, height: 0), cancel: true)
        #expect(state.layout == saved)
        #expect(UIStatusPreferences(defaults: testDefaults(in: files.root)).layout == saved)
        try disk.drag("storage.list-width", by: NSSize(width: -100, height: 0), cancel: true)
        #expect(diskState.width == 440)
        print("ui-e2e resize.escape-cancels-without-saving")
    }

    @Test func statusDropDecodingAndSessionIsolation() async throws {
        let files = try EndToEndFixture()
        let state = UIStatusPreferences(defaults: testDefaults(in: files.root))
        let ui = UIInteractionWindow(UIStatusFixtureView(preferences: state))
        defer { ui.close() }
        try await ui.settle()
        for valid in [true, false] {
            let before = state.layout
            let payload = StatusCardDrag(card: .memory, session: valid ? state.session : UUID())
            let data = try await payload.exported(as: StatusCardDrag.contentType)
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: StatusCardDrag.contentType.identifier, visibility: .ownProcess) { complete in
                complete(data, nil)
                return nil
            }
            let decoded: StatusCardDrag = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadTransferable(type: StatusCardDrag.self) { continuation.resume(with: $0) }
            }
            #expect(state.accept([decoded], before: .cpu) == valid)
            try await ui.settle()
            if valid {
                #expect(state.layout.visible.first?.id == .memory)
                #expect(state.layout != before)
            } else {
                #expect(state.layout == before)
            }
        }
        #expect(UIStatusPreferences(defaults: testDefaults(in: files.root)).layout == state.layout)
        print("ui-e2e status.drop.decoding-session-isolation")
    }

    @Test func diskMapDividerMouseDrag() async throws {
        let files = try EndToEndFixture()
        let untouched = try files.contents()
        let state = UISplitPreferences()
        let ui = UIInteractionWindow(UIDiskSplitFixtureView(preferences: state))
        defer { ui.close() }
        try await ui.settle()
        try ui.drag("storage.list-width", by: NSSize(width: -100, height: 0))
        #expect(state.width > 500)
        try ui.drag("storage.list-width", by: NSSize(width: 1_600, height: 0))
        #expect(state.width == Double(StorageView.listWidth(saved: 0, total: ui.host.bounds.width)))
        #expect(try files.contents() == untouched)
        print("ui-e2e storage.divider.mouse-clamping")
    }
}
#endif
