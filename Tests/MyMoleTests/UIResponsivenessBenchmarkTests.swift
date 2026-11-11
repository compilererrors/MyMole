import AppKit
import Foundation
import QuartzCore
import StorageKit
import SwiftUI
import Testing

@testable import MyMole

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MYMOLE_UI_BENCHMARK"] == "1"))
struct UIResponsivenessBenchmarkTests {
    @Test func tableResizeScrollAndMenuService() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ui-benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let start = ContinuousClock.now
        coordinator.load(source, marks: nil, selection: [])
        await coordinator.sortJob?.value
        coordinator.fitting = table.keepFitting("name", defaults: defaults)
        scroll.layoutSubtreeIfNeeded()
        scroll.displayIfNeeded()
        report("table.load.10000", [milliseconds(since: start)], budget: 1_000)
        try #require(table.numberOfRows == source.count)
        try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: false) != nil)
        var resize: [Double] = []
        for step in 0..<220 {
            let start = ContinuousClock.now
            window.setContentSize(NSSize(width: 760 + CGFloat(step % 80) * 7, height: 640))
            table.columnViewport?.resized()
            scroll.layoutSubtreeIfNeeded()
            scroll.displayIfNeeded()
            if step >= 20 { resize.append(milliseconds(since: start)) }
        }
        report("table.resize.10000", resize, budget: 16.7)
        var scrolling: [Double] = []
        for step in 0..<220 {
            let start = ContinuousClock.now
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat((step * 17) % 9_900) * 40))
            scroll.reflectScrolledClipView(scroll.contentView)
            scroll.layoutSubtreeIfNeeded()
            scroll.displayIfNeeded()
            if step >= 20 { scrolling.append(milliseconds(since: start)) }
        }
        report("table.scroll.10000", scrolling, budget: 16.7)
        let menu = NSMenu()
        coordinator.headerMenu = menu
        var menus: [Double] = []
        for step in 0..<120 {
            let start = ContinuousClock.now
            coordinator.menuNeedsUpdate(menu)
            if step >= 20 { menus.append(milliseconds(since: start)) }
        }
        #expect(!menu.items.isEmpty)
        report("table.menu", menus, budget: 16.7)
        #expect(coordinator.sortJob == nil)
    }

    @Test func projectInspectorResize() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "split-benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let rows = (0..<500).map { index in
            FileRow(id: "/synthetic/Project-\(index)", name: "Example project \(index)", size: 10_000,
                    freeable: 5_000, subtitle: "Generated · Swift")
        }
        let left = AnyView(FileTable(rows: rows, columns: [.name, .size, .freeable], autosave: "", selection: .constant([])))
        let right = AnyView(ProjectDetail(model: model, footprint: footprint, showInDiskMap: {}))
        let controller = InspectorSplitController(content: left, inspector: right)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_400, height: 740),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1_400, height: 740))
        controller.view.setFrameSize(NSSize(width: 1_400, height: 740))
        controller.splitView.setFrameSize(NSSize(width: 1_400, height: 740))
        defer { window.close() }
        window.orderFront(nil)
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
        let sortGenerations = tables.compactMap { ($0 as? FileTableView)?.coordinator?.sortGeneration }
        let itemsBefore = controller.children.map(ObjectIdentifier.init)
        let frames = FrameSamples()
        var widths: [CGFloat] = []
        let link = controller.view.displayLink(target: frames, selector: #selector(FrameSamples.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        frames.work = { step in
            let inspectorWidth = CGFloat(340 + (step < 100 ? step : 200 - step) % 90 * 2)
            controller.splitView.setPosition(controller.splitView.bounds.width - 1 - inspectorWidth, ofDividerAt: 0)
            controller.splitView.adjustSubviews()
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            widths.append(controller.inspector.view.frame.width)
        }
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        let deadline = ContinuousClock.now + .seconds(15)
        while frames.services.count < 200, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        link.invalidate()
        try #require(frames.services.count == 200, "A visible display link must actually deliver the resize workload")
        try #require((widths.max() ?? 0) - (widths.min() ?? 0) > 150, "The inspector must actually resize during measurement")
        report("projects.split.service", Array(frames.services.dropFirst(20)), budget: 16.7)
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
        var scrolling: [Double] = []
        for step in 0..<120 {
            let start = ContinuousClock.now
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step * 3) * 40))
            scroll.reflectScrolledClipView(scroll.contentView)
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if step >= 20 { scrolling.append(milliseconds(since: start)) }
        }
        report("projects.outline.scroll.500", scrolling, budget: 16.7)
    }

    @Test(arguments: [12, 100]) func filterMenuScrollingAndComponentLoading(count: Int) async throws {
        let body = DSFilterBody {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<count, id: \.self) { index in
                    Toggle("Synthetic filter \(index)", isOn: .constant(index.isMultiple(of: 3)))
                }
            }
        }
        let host = NSHostingView(rootView: body)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        defer { window.close() }
        let start = ContinuousClock.now
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        report("filters.first-render.\(count)", [milliseconds(since: start)], budget: count > 12 ? 500 : 100)
        let scroll = try #require(descendants(of: NSScrollView.self, in: host).first)
        if count > 12 { try #require((scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height) }
        var samples: [Double] = []
        for step in 0..<120 {
            let start = ContinuousClock.now
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step % 80) * 25))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if step >= 20 { samples.append(milliseconds(since: start)) }
        }
        report("filters.scroll.\(count)", samples, budget: 16.7)
    }

    @Test func statusCardsResizeScrollAndLoadingTransitions() throws {
        let host = NSHostingView(rootView: BenchmarkStatusPanel(loading: true, reading: 0))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        var loading: [Double] = []
        for step in 0..<30 {
            let start = ContinuousClock.now
            host.rootView = BenchmarkStatusPanel(loading: step.isMultiple(of: 2), reading: step)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if step >= 4 { loading.append(milliseconds(since: start)) }
        }
        report("status.loading-transition", loading, budget: 100)
        host.rootView = BenchmarkStatusPanel(loading: false, reading: 30)
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(descendants(of: NSScrollView.self, in: host).first)
        try #require((scroll.documentView?.bounds.height ?? 0) > 640)
        var resizing: [Double] = []
        var scrolling: [Double] = []
        for step in 0..<120 {
            let start = ContinuousClock.now
            window.setContentSize(NSSize(width: 760 + CGFloat(step % 60) * 8, height: 640))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if step >= 20 { resizing.append(milliseconds(since: start)) }
            let scrollStart = ContinuousClock.now
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step % 30) * 30))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if step >= 20 { scrolling.append(milliseconds(since: scrollStart)) }
        }
        report("status.resize", resizing, budget: 16.7)
        report("status.scroll", scrolling, budget: 16.7)
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        Double((ContinuousClock.now - start) / .microseconds(1)) / 1_000
    }

    private func report(_ name: String, _ values: [Double], budget: Double) {
        let sorted = values.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
        }
        let p95 = percentile(0.95)
        let hitches = values.filter { $0 > 33.3 }.count
        print(String(format: "ui-bench %@ n=%d p50=%.3fms p95=%.3fms p99=%.3fms max=%.3fms over33ms=%d budget=%.3fms",
                     name, sorted.count, percentile(0.5), p95, percentile(0.99), sorted.last ?? 0, hitches, budget))
        if ProcessInfo.processInfo.environment["MYMOLE_STRICT_UI_BENCHMARKS"] == "1" {
            #expect(p95 <= budget, "UI service budget exceeded")
            let p99Budget = name.hasSuffix("frame-delivery") ? 33.3 : max(budget * 2, 33.3)
            #expect(percentile(0.99) <= p99Budget, "UI p99 budget exceeded")
            if budget < 100 {
                #expect((sorted.last ?? 0) < 100, "An interactive update blocked for 100 ms")
            }
        }
    }
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
                        ForEach(0..<8, id: \.self) { index in
                            Text("Synthetic reading \(reading + index)")
                        }
                    } actions: {
                        Button("Example action") {}
                    }
                }
            }
        }
    }
}

@MainActor private final class FrameSamples: NSObject {
    var work: ((Int) -> Void)?
    var services: [Double] = []
    var intervals: [Double] = []
    private var last: CFTimeInterval?

    @objc func tick(_ link: CADisplayLink) {
        guard services.count < 200 else { return }
        let start = CACurrentMediaTime()
        if let last { intervals.append((start - last) * 1_000) }
        last = start
        work?(services.count)
        services.append((CACurrentMediaTime() - start) * 1_000)
    }
}
