import AppKit
import CoreTransferable
import Foundation
import Darwin
import QuartzCore
import StorageKit
import SwiftUI
import Testing

@testable import MyMole

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MYMOLE_UI_BENCHMARK"] == "1"))
struct UIResponsivenessBenchmarkTests {
    @Test func continuousNativeHeaderResize() async throws {
        let root = try uiFixtureDirectory()
        let f = try await UINativeTableFixture(defaults: testDefaults(in: root), count: 10_000)
        defer { f.close() }
        let header = try #require(f.table.headerView)
        let rect = header.headerRect(ofColumn: 1)
        let startPoint = header.convert(NSPoint(x: rect.maxX, y: rect.midY), to: nil)
        let column = try #require(f.table.tableColumns[1] as? UIMeasuredTableColumn)
        let records = HeaderResizeSamples(column: column, window: f.ui.window.windowNumber, point: startPoint)
        column.onResize = { [weak records] width in
            guard let records, width != records.lastWidth, let sent = records.sent else { return }
            records.samples.append(sent.sample())
            records.widths.append(width)
            records.lastWidth = width
            records.sent = nil
        }
        defer { column.onResize = nil }
        let frames = FrameSamples()
        frames.work = { step in
            let width = CGFloat(120 + step % 50 * 3)
            let point = header.convert(NSPoint(x: rect.minX + width, y: rect.midY), to: nil)
            records.point = point
            records.sent = UIWorkStamp()
            if let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: point, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: records.window,
                                              context: nil, eventNumber: 1, clickCount: 1, pressure: 1) {
                NSApp.postEvent(event, atStart: false)
            }
            if step == 199 { records.release() }
        }
        let link = f.scroll.displayLink(target: frames, selector: #selector(FrameSamples.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        let fallback = Timer(timeInterval: 15, repeats: false) { _ in
            MainActor.assumeIsolated { records.timedOut = true; records.release() }
        }
        RunLoop.main.add(fallback, forMode: .eventTracking)
        defer { fallback.invalidate() }
        header.mouseDown(with: try f.ui.event(.leftMouseDown, at: startPoint))
        link.invalidate()
        try #require(!records.timedOut && frames.services.count == 200)
        try #require(records.samples.count >= 180, "Native resize notifications must acknowledge the actual pointer workload")
        try #require((records.widths.max() ?? 0) - (records.widths.min() ?? 0) > 120)
        report("table.header.mouse-resize", Array(records.samples.dropFirst(20)), budget: 16.7)
        report("table.header.frame-delivery", Array(frames.intervals.dropFirst(20)), budget: 25)
    }

    @Test func scanSpeedSliderInputAndRendering() async throws {
        let root = try uiFixtureDirectory()
        let state = UIScanSpeedPreferences(defaults: testDefaults(in: root))
        let ui = UIInteractionWindow(ScanSpeedControl(performance: state.binding).padding(24), width: 600, height: 240)
        defer { ui.close() }
        try await ui.settle()
        var input: [UISample] = [], visible: [UISample] = []
        for step in 0..<64 {
            let control = try ui.element("settings.scan-speed")
            let timing = UIWorkStamp()
            // The default is the top level, so the first step goes down.
            control.adjust(step.isMultiple(of: 2) ? -1 : 1)
            input.append(timing.sample())
            ui.settleTracking()
            visible.append(timing.sample())
            try #require(state.value == PerformanceLevel.standard.rawValue - (step.isMultiple(of: 2) ? 1 : 0))
        }
        report("settings.scan-speed.adjust.input", Array(input.dropFirst(4)), budget: 16.7)
        report("settings.scan-speed.visible", Array(visible.dropFirst(4)), budget: 100)
    }

    @Test func dragDropTransportAndVisibleReorder() async throws {
        let root = try uiFixtureDirectory()
        let fixtureApp = root.appending(path: "Synthetic.app")
        try FileManager.default.createDirectory(at: fixtureApp, withIntermediateDirectories: true)
        let state = UIStatusPreferences(defaults: testDefaults(in: root))
        let ui = UIInteractionWindow(UIStatusFixtureView(preferences: state))
        defer { ui.close() }
        try await ui.settle()
        var transfer: [UISample] = [], visible: [UISample] = [], urls: [UISample] = []
        for step in 0..<64 {
            let source: StatusCardID = step.isMultiple(of: 2) ? .memory : .cpu
            let destination: StatusCardID = step.isMultiple(of: 2) ? .cpu : .memory
            let payload = StatusCardDrag(card: source, session: state.session)
            let timing = UIWorkStamp()
            let data = try await payload.exported(as: StatusCardDrag.contentType)
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: StatusCardDrag.contentType.identifier, visibility: .ownProcess) { complete in
                complete(data, nil); return nil
            }
            let decoded: StatusCardDrag = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadTransferable(type: StatusCardDrag.self) { continuation.resume(with: $0) }
            }
            try #require(state.accept([decoded], before: destination))
            transfer.append(timing.sample())
            try await ui.settle()
            visible.append(timing.sample())
            try #require(state.layout.visible.first?.id == source)
            let before = state.layout
            try #require(!state.accept([StatusCardDrag(card: source, session: UUID())], before: destination))
            try #require(state.layout == before)
            let urlProvider = NSItemProvider(object: fixtureApp as NSURL)
            let urlTiming = UIWorkStamp()
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                _ = urlProvider.loadTransferable(type: URL.self) { continuation.resume(with: $0) }
            }
            urls.append(urlTiming.sample())
            var expected = stat(), received = stat()
            try #require(url.isFileURL && lstat(fixtureApp.path, &expected) == 0 && lstat(url.path, &received) == 0)
            try #require(expected.st_dev == received.st_dev && expected.st_ino == received.st_ino && expected.st_mode == received.st_mode,
                         "A decoded app URL must identify the original fixture, including directory URLs and path aliases")
        }
        report("status.drop.transfer", Array(transfer.dropFirst(4)), budget: 16.7)
        report("status.drop.visible-reorder", Array(visible.dropFirst(4)), budget: 100)
        report("uninstall.drop.url-decoding", Array(urls.dropFirst(4)), budget: 16.7)
    }

    @Test(arguments: StorageModel.Chart.allCases)
    func diskChartAndInspectorResize(chart: StorageModel.Chart) async throws {
        let root = try uiFixtureDirectory()
        let model = try await syntheticDiskRenderingModel(in: root)
        try #require(model.opened != nil && !model.canTrash)
        let preferences = UISplitPreferences()
        try await DiskRenderingWarmUp.once(in: root)
        let start = UIWorkStamp()
        let ui = UIInteractionWindow(UIDiskRenderingView(preferences: preferences, model: model, chart: chart), width: 1_400)
        defer { ui.close() }
        try await ui.settle()
        report("disk.chart.\(chart.rawValue).first-render", [start.sample()], budget: 500)
        let frames = FrameSamples(limit: 600)
        frames.work = { step in preferences.width = 340 + Double(step % 90) * 3 }
        frames.render = { ui.host.layoutSubtreeIfNeeded() }
        let link = ui.host.displayLink(target: frames, selector: #selector(FrameSamples.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        let deadline = ContinuousClock.now + .seconds(45)
        while frames.services.count < 600, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        link.invalidate()
        try #require(frames.services.count == 600)
        // Cold presentation is measured above; steady resize gets one second
        // to warm glyphs and render resources, then at least 500 observations.
        report("disk.chart.\(chart.rawValue).resize.input", Array(frames.services.dropFirst(60)), budget: 16.7)
        report("disk.chart.\(chart.rawValue).frame-delivery", Array(frames.intervals.dropFirst(60)), budget: 25)
        try #require(!model.canTrash && model.marked.isEmpty)
    }

    /// The default step's background scans, as launch starts them: as many
    /// walks at once as the scan speed allows, each with its threads and
    /// priority, over a synthetic tree, again and again until stopped.
    private func backgroundScans(in root: URL) throws -> (stop: @Sendable () -> Void, done: Task<Void, Never>) {
        let tree = root.appending(path: "background-tree")
        for folder in 0..<120 {
            let dir = tree.appending(path: "f\(folder)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in 0..<150 { FileManager.default.createFile(atPath: dir.appending(path: "x\(file)").path, contents: Data([1])) }
        }
        let level = PerformanceLevel.standard
        let progress = ScanProgress()
        let (path, workers, slots) = (tree.path, level.workers(background: true), min(level.scanSlots(), 8))
        let done = Task.detached(priority: level.priority(background: true)) {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<slots {
                    group.addTask(priority: level.priority(background: true)) {
                        while !progress.isCancelled { _ = StorageScanner.scan(path: path, progress: progress, workers: workers) }
                    }
                }
            }
        }
        return ({ progress.cancel() }, done)
    }

    /// Resizing Disk Map while launch's scans run behind it: each step's
    /// whole main-thread cost (the new width, layout and drawing), not just
    /// the state change.
    @Test(arguments: [StorageModel.Chart.rings, .boxes])
    func diskResizeWhileScansRunInTheBackground(chart: StorageModel.Chart) async throws {
        let root = try uiFixtureDirectory()
        let model = try await syntheticDiskRenderingModel(in: root)
        let preferences = UISplitPreferences()
        let ui = UIInteractionWindow(UIDiskRenderingView(preferences: preferences, model: model, chart: chart), width: 1_400)
        defer { ui.close() }
        try await ui.settle()
        let scans = try backgroundScans(in: root)
        defer { scans.stop() }
        let frames = FrameSamples(limit: 360)
        frames.work = { step in
            preferences.width = 340 + Double(step % 90) * 3
            ui.host.layoutSubtreeIfNeeded()
            ui.host.display()
        }
        let link = ui.host.displayLink(target: frames, selector: #selector(FrameSamples.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        let deadline = ContinuousClock.now + .seconds(45)
        while frames.services.count < 360, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        link.invalidate()
        scans.stop()
        await scans.done.value
        try #require(frames.services.count == 360)
        report("disk.\(chart.rawValue).resize-step.background-scans", Array(frames.services.dropFirst(60)), budget: 16.7)
        report("disk.\(chart.rawValue).frame-delivery.background-scans", Array(frames.intervals.dropFirst(60)), budget: 25)
    }

    /// Resizing Disk Map over a map the size of a real home folder, every
    /// chart: each step's whole main-thread cost, layout and drawing included.
    @Test(arguments: StorageModel.Chart.allCases)
    func largeDiskMapResizeSteps(chart: StorageModel.Chart) async throws {
        let root = try uiFixtureDirectory()
        let model = try await largeSyntheticDiskModel(in: root)
        let preferences = UISplitPreferences()
        let ui = UIInteractionWindow(UIDiskRenderingView(preferences: preferences, model: model, chart: chart), width: 1_400)
        defer { ui.close() }
        try await ui.settle()
        let frames = FrameSamples(limit: 360)
        frames.work = { step in
            preferences.width = 340 + Double(step % 90) * 3
            ui.host.layoutSubtreeIfNeeded()
            ui.host.display()
        }
        let link = ui.host.displayLink(target: frames, selector: #selector(FrameSamples.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        let deadline = ContinuousClock.now + .seconds(60)
        while frames.services.count < 360, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        link.invalidate()
        try #require(frames.services.count == 360)
        report("disk.large.\(chart.rawValue).resize-step", Array(frames.services.dropFirst(60)), budget: 16.7)
    }

    @Test func nativeStatusAndStorageResizeInput() async throws {
        let root = try uiFixtureDirectory()
        let state = UIStatusPreferences(defaults: testDefaults(in: root))
        let ui = UIInteractionWindow(UIStatusFixtureView(preferences: state))
        let diskState = UISplitPreferences()
        let disk = UIInteractionWindow(UIDiskSplitFixtureView(preferences: diskState))
        defer { ui.close(); disk.close() }
        try await ui.settle()
        try await disk.settle()
        var statusSamples: [UISample] = [], diskSamples: [UISample] = []
        for step in 0..<64 {
            for (target, id, delta) in [(ui, "status.resize.cpu", step.isMultiple(of: 2) ? 90.0 : -90.0),
                                         (disk, "storage.list-width", step.isMultiple(of: 2) ? -40.0 : 40.0)] {
                let handle = try #require(target.element(id).object as? HorizontalDragHandleView)
                let start = NSPoint(x: handle.bounds.midX, y: handle.bounds.midY)
                let timing = UIWorkStamp()
                try target.trackMouse(in: handle, from: start, through: (1...8).map {
                    NSPoint(x: start.x + delta * Double($0) / 8, y: start.y)
                })
                if target === ui { statusSamples.append(timing.sample()) } else { diskSamples.append(timing.sample()) }
                target.settleTracking()
            }
            try #require(state.layout.cards.first { $0.id == .cpu }?.size == (step.isMultiple(of: 2) ? .wide : .standard))
            let expectedWidth = step.isMultiple(of: 2) ? 480.0 : 440.0
            try #require(abs(diskState.width - expectedWidth) < 0.5, "Native coordinates must preserve the expected width without accumulated drift")
        }
        report("status.edit.mouse-resize.input", Array(statusSamples.dropFirst(4)), budget: 16.7)
        report("storage.divider.mouse-resize.input", Array(diskSamples.dropFirst(4)), budget: 16.7)
    }

    @Test func editableStatusControlsAndPersistence() async throws {
        let root = try uiFixtureDirectory()
        let state = UIStatusPreferences(defaults: testDefaults(in: root))
        let ui = UIInteractionWindow(UIStatusFixtureView(preferences: state))
        defer { ui.close() }
        try await ui.settle()
        var input: [UISample] = [], visible: [UISample] = [], persistence: [UISample] = []
        for step in 0..<64 {
            let handle = try ui.element("status.resize.cpu")
            let start = UIWorkStamp()
            try #require(handle.accessibilityPerformPress())
            let service = start.sample()
            try await ui.settle()
            if step >= 4 {
                input.append(service)
                visible.append(milliseconds(since: start))
            }
            try #require(state.layout.visible.first { $0.id == .cpu }?.size == (step.isMultiple(of: 2) ? .wide : .standard))
            let save = UIWorkStamp()
            let restored = UIStatusPreferences(defaults: testDefaults(in: root))
            persistence.append(save.sample())
            try #require(restored.layout == state.layout)
        }
        report("status.edit.resize.input", input, budget: 16.7)
        report("status.edit.resize.visible", visible, budget: 100)
        report("status.edit.persistence", persistence, budget: 16.7)
        let disk = UISplitPreferences()
        let divider = UIInteractionWindow(UIDiskSplitFixtureView(preferences: disk))
        defer { divider.close() }
        try await divider.settle()
        var adjustments: [UISample] = []
        for step in 0..<64 {
            let node = try divider.element("storage.list-width")
            let start = UIWorkStamp()
            let accepted = step.isMultiple(of: 2)
                ? (node.object as AnyObject).accessibilityPerformIncrement?()
                : (node.object as AnyObject).accessibilityPerformDecrement?()
            try #require(accepted == true)
            adjustments.append(start.sample())
            try await divider.settle()
            try #require(disk.width == (step.isMultiple(of: 2) ? 480 : 440))
        }
        report("storage.divider.adjust", Array(adjustments.dropFirst(4)), budget: 16.7)
    }

    @Test func nativeHeaderAdjustmentsAndDensity() async throws {
        let root = try uiFixtureDirectory()
        let f = try await UINativeTableFixture(defaults: testDefaults(in: root), count: 10_000)
        defer { f.close() }
        let identity = ObjectIdentifier(f.table)
        let oldDensity = Density.current
        defer { Density.current = oldDensity }
        var visibility: [UISample] = [], fitting: [UISample] = [], density: [UISample] = [], nativeMenu: [UISample] = []
        var reordering: [UISample] = []
        for step in 0..<64 {
            let column = f.table.tableColumns[1]
            let menu = UIWorkStamp()
            try f.invokeMenu(column.title, direct: true)
            visibility.append(menu.sample())
            try #require(column.isHidden)
            try f.invokeMenu(String(localized: "Show All Columns"), direct: true)
            let nativeDispatch = UIWorkStamp()
            try f.invokeMenu(column.title)
            nativeMenu.append(nativeDispatch.sample())
            try f.invokeMenu(String(localized: "Show All Columns"), direct: true)
            let fit = UIWorkStamp()
            try f.invokeMenu(String(localized: "Fit Visible Contents"), direct: true)
            fitting.append(fit.sample())
            let moved = f.table.tableColumns[1]
            let reorder = UIWorkStamp()
            f.table.moveColumn(1, toColumn: 2)
            f.scroll.layoutSubtreeIfNeeded()
            f.ui.window.displayIfNeeded()
            reordering.append(reorder.sample())
            try #require(f.table.tableColumns[2] === moved)
            let appearance = UIWorkStamp()
            Density.current = step.isMultiple(of: 2) ? .compact : .spacious
            f.table.configureRows(height: DS.Table.row)
            f.scroll.layoutSubtreeIfNeeded()
            f.ui.window.displayIfNeeded()
            density.append(appearance.sample())
        }
        try #require(ObjectIdentifier(f.table) == identity && f.table.numberOfRows == 10_000)
        report("table.columns.visibility", Array(visibility.dropFirst(4)), budget: 16.7)
        report("table.columns.fit", Array(fitting.dropFirst(4)), budget: 16.7)
        report("table.columns.native-menu", Array(nativeMenu.dropFirst(4)), budget: 100)
        report("table.columns.reorder", Array(reordering.dropFirst(4)), budget: 16.7)
        report("appearance.density.table", Array(density.dropFirst(4)), budget: 16.7)
    }

    @Test func tableResizeScrollAndMenuService() async throws {
        UIInteractionWindow.prepareApplication()
        let root = try uiFixtureDirectory()
        let defaults = testDefaults(in: root)
        let source = (0..<10_000).map { index -> FileRow in
            var row = FileRow(id: "/synthetic/item-\(index)",
                              name: "Synthetic project \(index) with several descriptive components and a-long-generated-artifact-name.data",
                              size: Int64(index + 1) * 1_024, modified: .distantPast,
                              kind: "Generated data", location: "/synthetic/projects/group-\(index % 80)")
            row.badge = index.isMultiple(of: 3) ? "Example" : nil
            return row
        }
        let parent = FileTable(rows: source, columns: [.name, .size, .kind, .location],
                               autosave: "", selection: .constant([]), menu: { _ in [.action("Example action") {}] })
        let coordinator = parent.makeCoordinator()
        let table = FileTableView()
        table.coordinator = coordinator
        table.configureRows(height: 40)
        table.dataSource = coordinator
        table.delegate = coordinator
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for field in parent.columns {
            let column = NSTableColumn(identifier: .init(field.rawValue))
            column.minWidth = field.width.min
            column.width = field.width.ideal
            column.maxWidth = field.width.max
            table.addTableColumn(column)
        }
        coordinator.table = table
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1_100, height: 640))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        table.configureUserColumns()
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = scroll
        defer {
            coordinator.stopSorting()
            coordinator.stopPresentation()
            NSTableView.stopFitting(&coordinator.fitting)
            window.close()
        }
        window.orderBack(nil)
        coordinator.bindWindow(nil)
        coordinator.setPresentationActive(true)
        let start = UIWorkStamp()
        coordinator.load(source, marks: nil, selection: [])
        await coordinator.sortJob?.value
        coordinator.fitting = table.keepFitting("name", defaults: defaults)
        scroll.layoutSubtreeIfNeeded()
        scroll.displayIfNeeded()
        report("table.load.10000", [milliseconds(since: start)], budget: 1_000)
        try #require(table.numberOfRows == source.count)
        try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: false) != nil)
        var resize: [UISample] = []
        for step in 0..<220 {
            let start = UIWorkStamp()
            window.setContentSize(NSSize(width: 760 + CGFloat(step % 80) * 7, height: 640))
            table.columnViewport?.resized()
            let input = start.sample()
            scroll.layoutSubtreeIfNeeded()
            scroll.displayIfNeeded()
            if step >= 20 { resize.append(milliseconds(since: start, input: input)) }
        }
        report("table.resize.10000", resize, budget: 16.7)
        var scrolling: [UISample] = []
        for step in 0..<220 {
            let start = UIWorkStamp()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat((step * 17) % 9_900) * 40))
            scroll.reflectScrolledClipView(scroll.contentView)
            let input = start.sample()
            scroll.layoutSubtreeIfNeeded()
            scroll.displayIfNeeded()
            if step >= 20 { scrolling.append(milliseconds(since: start, input: input)) }
        }
        report("table.scroll.10000", scrolling, budget: 16.7)
        let menu = NSMenu()
        coordinator.headerMenu = menu
        var menus: [UISample] = []
        for step in 0..<120 {
            let start = UIWorkStamp()
            coordinator.menuNeedsUpdate(menu)
            if step >= 20 { menus.append(milliseconds(since: start)) }
        }
        #expect(!menu.items.isEmpty)
        report("table.menu", menus, budget: 16.7)
        #expect(coordinator.sortJob == nil)
    }

    /// The main window's sidebar divider dragged over a heavy pane. Each
    /// step includes the layout it causes, as a frame of a real drag would.
    @Test func mainSidebarDividerDrag() async throws {
        let root = try uiFixtureDirectory()
        try await DiskRenderingWarmUp.once(in: root)
        let model = try await syntheticDiskRenderingModel(in: root)
        let preferences = UISplitPreferences()
        let pane = Binding<String?>.constant("Disk Map")
        let view = MainSplit(sidebarShown: .constant(true)) {
            List(selection: pane) {
                ForEach(["Cleanup", "Insight", "More"], id: \.self) { group in
                    Section(group) {
                        ForEach(0..<5) { i in
                            Label {
                                HStack {
                                    Text(verbatim: "\(group) pane \(i)")
                                    Spacer(minLength: 4)
                                    Text(verbatim: "\(i + 1),2 GB").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "folder")
                            }
                            .tag(Optional("\(group) pane \(i)"))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        } detail: {
            PaneFrame(minWidth: 760, minHeight: 560) {
                UIDiskRenderingView(preferences: preferences, model: model, chart: .rings)
            }
        }
        let ui = UIInteractionWindow(view, width: 1_400, height: 820)
        defer { ui.close() }
        try await ui.settle()
        let splits = descendants(of: NSSplitView.self, in: ui.host)
        let split = try #require(splits.first { $0.isVertical && $0.arrangedSubviews.count >= 2 })
        let windowFrame = ui.window.frame
        var widths: [CGFloat] = []
        let frames = FrameSamples(limit: 200)
        frames.work = { step in
            let position = MainSplitMetrics.sidebarMin + CGFloat(step % 50) * 2
            split.setPosition(position, ofDividerAt: 0)
            ui.host.layoutSubtreeIfNeeded()
            widths.append(split.arrangedSubviews[0].frame.width)
        }
        frames.render = { ui.window.displayIfNeeded() }
        let link = ui.host.displayLink(target: frames, selector: #selector(FrameSamples.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        let deadline = ContinuousClock.now + .seconds(20)
        while frames.services.count < 200, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        link.invalidate()
        try #require(frames.services.count == 200)
        try #require((widths.max() ?? 0) - (widths.min() ?? 0) > 60, "The sidebar must actually resize during measurement")
        #expect(ui.window.frame == windowFrame, "Dragging the sidebar must not resize the window")
        report("main.sidebar.drag", Array(frames.services.dropFirst(20)), budget: 16.7)
        report("main.sidebar.frame-delivery", Array(frames.intervals.dropFirst(20)), budget: 25)
    }

    @Test func projectInspectorResize() async throws {
        let root = try uiFixtureDirectory()
        let items = (0..<4).map { group in
            FootprintItem(id: "group-\(group)", category: .build, title: "Generated group \(group)",
                          location: "/synthetic/Example", attribution: .inside,
                          entries: (0..<500).map { index in
                              FootprintEntry(path: "/synthetic/Example/group-\(group)/item-\(index)", bytes: 1_024,
                                             modified: .distantPast, isDirectory: false)
                          })
        }
        let footprint = ProjectFootprint(project: DevProject(path: "/synthetic/Example", markers: ["Package.swift"]), items: items)
        let model = ProjectsModel(footprints: [footprint], base: root, defaults: testDefaults(in: root),
                                  logURL: root.appending(path: "history.json"))
        model.trashBackend = testBin(root)
        let rows = (0..<500).map { index in
            FileRow(id: "/synthetic/Project-\(index)", name: "Example project \(index)", size: 10_000,
                    freeable: 5_000, subtitle: "Generated · Swift")
        }
        let left = AnyView(FileTable(rows: rows, columns: [.name, .size, .freeable], autosave: "", selection: .constant([])))
        let right = AnyView(ProjectDetail(model: model, footprint: footprint, showInDiskMap: {}))
        let controller = InspectorSplitController(content: left, inspector: right)
        let ui = UIInteractionWindow(Color.clear, width: 1_600, height: 740)
        let window = ui.window
        // An outer sidebar changes the workspace's viewport inside a fixed
        // window. Resizing the NSWindow here would also measure WindowServer
        // surface allocation, which is a different interaction.
        let container = NSViewController()
        container.view = NSView(frame: NSRect(x: 0, y: 0, width: 1_600, height: 740))
        container.addChild(controller)
        container.view.addSubview(controller.view)
        window.contentViewController = container
        controller.view.autoresizingMask = []
        controller.view.setFrameSize(NSSize(width: 1_400, height: 740))
        controller.splitView.setFrameSize(NSSize(width: 1_400, height: 740))
        defer { ui.close() }
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let tables = descendants(of: NSTableView.self, in: controller.view)
        try #require(tables.count == 2)
        for table in tables {
            if let table = table as? FileTableView {
                table.coordinator?.bindWindow(nil)
                table.coordinator?.setPresentationActive(true)
                await table.coordinator?.sortJob?.value
            }
        }
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try #require(tables.allSatisfy { $0.numberOfRows > 0 })
        let rowCounts = tables.map(\.numberOfRows)
        let windowFrame = window.frame
        let sortGenerations = tables.compactMap { ($0 as? FileTableView)?.coordinator?.sortGeneration }
        let itemsBefore = controller.children.map(ObjectIdentifier.init)
        let frames = FrameSamples()
        var widths: [CGFloat] = []
        var workspaceWidths: [CGFloat] = []
        let link = controller.view.displayLink(target: frames, selector: #selector(FrameSamples.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        frames.work = { step in
            if step < 100 {
                let inspectorWidth = CGFloat(340 + step % 90 * 2)
                controller.splitView.setPosition(controller.splitView.bounds.width - 1 - inspectorWidth, ofDividerAt: 0)
            } else {
                controller.view.setFrameSize(NSSize(width: 1_000 + CGFloat(step - 100) * 6, height: 740))
                workspaceWidths.append(controller.content.view.bounds.width)
            }
            widths.append(controller.inspector.view.frame.width)
        }
        frames.render = { controller.view.layoutSubtreeIfNeeded() }
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        let deadline = ContinuousClock.now + .seconds(15)
        while frames.services.count < 200, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        link.invalidate()
        try #require(frames.services.count == 200, "A visible display link must actually deliver the resize workload")
        try #require((widths.max() ?? 0) - (widths.min() ?? 0) > 150, "The inspector must actually resize during measurement")
        try #require((workspaceWidths.max() ?? 0) - (workspaceWidths.min() ?? 0) > 400, "The workspace must resize as its outer sidebar moves")
        #expect(window.frame == windowFrame, "Workspace resizing must not resize the OS window")
        report("projects.split.service", Array(frames.services[20..<100]), budget: 16.7)
        report("projects.workspace.resize", Array(frames.services[100..<200]), budget: 16.7)
        report("projects.split.frame-delivery", Array(frames.intervals.dropFirst(20)), budget: 25)
        #expect(tables.map(\.numberOfRows) == rowCounts)
        #expect(controller.children.map(ObjectIdentifier.init) == itemsBefore)
        let pendingSorts = tables.compactMap { ($0 as? FileTableView)?.coordinator?.sortJob }
        #expect(pendingSorts.isEmpty)
        let afterSorts = tables.compactMap { ($0 as? FileTableView)?.coordinator?.sortGeneration }
        #expect(afterSorts == sortGenerations)
        let outline = try #require(tables.compactMap { $0 as? FootprintOutlineView }.first)
        let group = try #require(outline.item(atRow: 1))
        outline.expandItem(group)
        try #require(outline.numberOfRows >= 500)
        let scroll = try #require(outline.enclosingScrollView)
        var scrolling: [UISample] = []
        for step in 0..<120 {
            let start = UIWorkStamp()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step * 3) * 40))
            scroll.reflectScrolledClipView(scroll.contentView)
            let input = start.sample()
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if step >= 20 { scrolling.append(milliseconds(since: start, input: input)) }
        }
        report("projects.outline.scroll.500", scrolling, budget: 16.7)
    }

    @Test(arguments: [12, 100]) func filterMenuScrollingAndComponentLoading(count: Int) async throws {
        UIInteractionWindow.prepareApplication()
        let materialized = FilterMaterialization()
        let body = DSFilterBody {
            ForEach(0..<count, id: \.self) { index in
                Toggle("Synthetic filter \(index)", isOn: .constant(index.isMultiple(of: 3)))
                    .onAppear { materialized.rows.insert(index) }
            }
        }
        let host = NSHostingView(rootView: body)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        defer { window.close() }
        let presentation = UIWorkStamp()
        window.orderFront(nil)
        window.displayIfNeeded()
        report("filters.window.present.\(count)", [milliseconds(since: presentation)], budget: 500)
        let start = UIWorkStamp()
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        report("filters.first-render.\(count)", [milliseconds(since: start)], budget: count > 12 ? 500 : 100)
        await Task.yield()
        let scroll = try #require(descendants(of: NSScrollView.self, in: host).first)
        if count > 12 {
            try #require((scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height)
            try #require(materialized.rows.count > 0 && materialized.rows.count < count / 2, "Offscreen filter controls must remain lazy")
        }
        var samples: [UISample] = []
        let scrollStep: (Int) -> Void = { step in
            let bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
            let position = step < 100 ? step : 199 - step
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(position) / 99 * bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if count > 12 {
            let frames = FrameSamples()
            frames.work = scrollStep
            let link = host.displayLink(target: frames, selector: #selector(FrameSamples.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            defer { link.invalidate() }
            let deadline = ContinuousClock.now + .seconds(15)
            while frames.services.count < 200, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            link.invalidate()
            try #require(frames.services.count == 200)
            samples = Array(frames.services.dropFirst(20))
            report("filters.scroll.\(count).frame-delivery", Array(frames.intervals.dropFirst(20)), budget: 25)
        } else {
            for step in 0..<120 {
                let start = UIWorkStamp()
                scrollStep(step)
                window.displayIfNeeded()
                if step >= 20 { samples.append(milliseconds(since: start)) }
            }
        }
        report("filters.scroll.\(count)", samples, budget: 16.7)
        if count > 12 { #expect(materialized.rows.contains(count - 1), "The last filter must become reachable by scrolling") }
    }

    @Test func statusCardsResizeScrollAndLoadingTransitions() throws {
        UIInteractionWindow.prepareApplication()
        let host = NSHostingView(rootView: BenchmarkStatusPanel(loading: true, reading: 0))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        var loading: [UISample] = []
        for step in 0..<30 {
            let start = UIWorkStamp()
            host.rootView = BenchmarkStatusPanel(loading: step.isMultiple(of: 2), reading: step)
            let input = start.sample()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if step >= 4 { loading.append(milliseconds(since: start, input: input)) }
        }
        report("status.loading-transition", loading, budget: 100)
        host.rootView = BenchmarkStatusPanel(loading: false, reading: 30)
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(descendants(of: NSScrollView.self, in: host).first)
        try #require((scroll.documentView?.bounds.height ?? 0) > 640)
        var resizing: [UISample] = []
        var scrolling: [UISample] = []
        for step in 0..<120 {
            let start = UIWorkStamp()
            window.setContentSize(NSSize(width: 760 + CGFloat(step % 60) * 8, height: 640))
            let resizeInput = start.sample()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if step >= 20 { resizing.append(milliseconds(since: start, input: resizeInput)) }
            let scrollStart = UIWorkStamp()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step % 30) * 30))
            scroll.reflectScrolledClipView(scroll.contentView)
            let scrollInput = scrollStart.sample()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if step >= 20 { scrolling.append(milliseconds(since: scrollStart, input: scrollInput)) }
        }
        report("status.resize", resizing, budget: 16.7)
        report("status.scroll", scrolling, budget: 16.7)
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func milliseconds(since start: UIWorkStamp, input: UISample? = nil) -> UISample {
        let complete = start.sample()
        return UISample(wall: complete.wall, cpu: input?.cpu ?? complete.cpu)
    }

    private func report(_ name: String, _ values: [Double], budget: Double) {
        report(name, values.map { UISample(wall: $0, cpu: nil) }, budget: budget)
    }

    private func report(_ name: String, _ values: [UISample], budget: Double) {
        let wall = values.map(\.wall).sorted()
        let cpu = values.compactMap(\.cpu).sorted()
        func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
            sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
        }
        let interactionScope = ProcessInfo.processInfo.environment["MYMOLE_UI_BENCHMARK_SCOPE"] == "interaction"
        let hardware = values.count == 1 || name.hasSuffix("frame-delivery")
        let gate = interactionScope ? (hardware ? "wall-liveness" : "thread-cpu") : "wall"
        let cpuP95 = cpu.isEmpty ? "n/a" : String(format: "%.3fms", percentile(cpu, 0.95))
        print(String(format: "ui-bench %@ n=%d p50=%.3fms p95=%.3fms p99=%.3fms max=%.3fms over33ms=%d budget=%.3fms cpu_p95=%@ gate=%@",
                     name, wall.count, percentile(wall, 0.5), percentile(wall, 0.95), percentile(wall, 0.99),
                     wall.last ?? 0, wall.filter { $0 > 33.3 }.count, budget, cpuP95, gate))
        guard ProcessInfo.processInfo.environment["MYMOLE_STRICT_UI_BENCHMARKS"] == "1" else { return }
        if interactionScope && hardware {
            #expect((wall.last ?? 0) < (name.hasSuffix("frame-delivery") ? 100 : 1_000), "UI presentation stopped making progress")
            return
        }
        if interactionScope {
            #expect(cpu.count == values.count && cpu.contains { $0 > 0 }, "Thread CPU measurements must actually exist")
            guard cpu.count == values.count else { return }
        }
        let checked = interactionScope ? cpu : wall
        #expect(percentile(checked, 0.95) <= budget, "UI service budget exceeded")
        let p99Budget = name.hasSuffix("frame-delivery") ? 33.3 : max(budget * 2, 33.3)
        #expect(percentile(checked, 0.99) <= p99Budget, "UI p99 budget exceeded")
        if budget < 100 {
            #expect((wall.last ?? 0) < 100, "An interactive update blocked for 100 ms")
        }
    }
}

@MainActor private final class HeaderResizeSamples {
    let column: NSTableColumn
    let window: Int
    var point: NSPoint
    var sent: UIWorkStamp?
    var samples: [UISample] = []
    var widths: [CGFloat] = []
    var timedOut = false
    var lastWidth: CGFloat

    init(column: NSTableColumn, window: Int, point: NSPoint) {
        self.column = column; self.window = window; self.point = point; lastWidth = column.width
    }

    func release() {
        if let event = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window,
                                          context: nil, eventNumber: 1, clickCount: 1, pressure: 0) {
            NSApp.postEvent(event, atStart: false)
        }
    }
}

@MainActor private final class FilterMaterialization {
    var rows = Set<Int>()
}

private struct BenchmarkStatusPanel: View {
    let loading: Bool
    let reading: Int

    var body: some View {
        if loading {
            DSLoading("Synthetic loading")
        } else {
            DSPage {
                StatusGridView(cards: StatusLayout().visible, spacing: 15) { card in
                    StatusCard(card: card.id) {
                        StatusTelemetry(card: card.id, snapshot: SyntheticStatusReadings.snapshot(reading: reading),
                                        history: SyntheticStatusReadings.history, trashBytes: 0, order: .constant(.cpu))
                    } actions: {
                        Button("Example action") {}
                    }
                }
            }
        }
    }
}

@MainActor private final class FrameSamples: NSObject {
    let limit: Int
    var work: ((Int) -> Void)?
    var render: (() -> Void)?
    var services: [UISample] = []
    var intervals: [Double] = []
    private var last: CFTimeInterval?

    init(limit: Int = 200) { self.limit = limit }

    @objc func tick(_ link: CADisplayLink) {
        guard services.count < limit else { return }
        let start = CACurrentMediaTime()
        if let last { intervals.append((start - last) * 1_000) }
        last = start
        let timing = UIWorkStamp()
        work?(services.count)
        services.append(timing.sample())
        render?()
        NSApp.updateWindows()
    }
}

private struct UISample {
    let wall: Double
    let cpu: Double?
}

private struct UIWorkStamp {
    private let wall = ContinuousClock.now
    private let cpu = Self.threadCPU()

    func sample() -> UISample {
        UISample(wall: Double((ContinuousClock.now - wall) / .microseconds(1)) / 1_000,
                 cpu: Double(Self.threadCPU() - cpu) / 1_000_000)
    }

    private static func threadCPU() -> UInt64 {
        var time = timespec()
        precondition(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time) == 0, "Thread CPU clock is required")
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }
}
