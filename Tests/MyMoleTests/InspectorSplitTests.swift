import AppKit
import SwiftUI
import Testing

@testable import MyMole

@MainActor @Suite struct InspectorSplitTests {
    @Test func hostedPanesInheritEnvironmentAndSurviveOuterSidebarResizing() async throws {
        var enabled: [Bool] = []
        var directions: [LayoutDirection] = []
        var made = 0
        let probe = PaneEnvironmentProbe { active, direction in
            enabled.append(active)
            directions.append(direction)
            made += 1
        }
        let host = NSHostingView(rootView: InspectorSplit { probe } inspector: { probe }
            .environment(\.layoutDirection, .rightToLeft).disabled(true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        try #require(made == 2)
        #expect(enabled.allSatisfy { !$0 })
        #expect(directions.allSatisfy { $0 == .rightToLeft })
        for width in stride(from: 760, through: 1_200, by: 10) {
            host.setFrameSize(NSSize(width: width, height: 600))
            host.layoutSubtreeIfNeeded()
        }
        #expect(made == 2)
    }

    @Test func dividerResizingRetainsHostsAndRespectsPaneLimits() async throws {
        let controller = InspectorSplitController(content: AnyView(Text("Synthetic content")),
                                                  inspector: AnyView(Text("Synthetic inspector")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1_200, height: 600))
        controller.view.setFrameSize(NSSize(width: 1_200, height: 600))
        controller.splitView.setFrameSize(NSSize(width: 1_200, height: 600))
        defer { window.close() }
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(30))
        controller.view.layoutSubtreeIfNeeded()
        let hosts = controller.children.map(ObjectIdentifier.init)
        for width in stride(from: 340, through: 520, by: 3) {
            controller.splitView.setPosition(controller.splitView.bounds.width - controller.splitView.dividerThickness - CGFloat(width), ofDividerAt: 0)
            controller.splitView.adjustSubviews()
            controller.view.layoutSubtreeIfNeeded()
            let actual = controller.inspector.view.frame.width
            try #require(abs(actual - CGFloat(width)) <= 1, "Inspector width \(actual), split \(controller.splitView.bounds.width), view \(controller.view.bounds.width), window \(window.contentView?.bounds.width ?? 0), requested \(width)")
            #expect(controller.content.view.frame.width >= 380)
        }
        #expect(controller.children.map(ObjectIdentifier.init) == hosts)
        #expect(controller.content.sizingOptions.isEmpty && controller.inspector.sizingOptions.isEmpty)
        controller.inspector.rootView = AnyView(Text("Changed synthetic selection"))
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.children.map(ObjectIdentifier.init) == hosts)
        #expect(controller.inspector.view.frame.width >= 340 && controller.inspector.view.frame.width <= 520)
        let chosenWidth = controller.inspector.view.frame.width
        controller.splitView.setFrameSize(NSSize(width: 721, height: 600))
        controller.splitView.adjustSubviews()
        controller.splitView.setFrameSize(NSSize(width: 1_200, height: 600))
        controller.splitView.adjustSubviews()
        #expect(abs(controller.inspector.view.frame.width - chosenWidth) <= 1)
    }
}

private struct PaneEnvironmentProbe: NSViewRepresentable {
    let record: (Bool, LayoutDirection) -> Void

    func makeNSView(context: Context) -> NSView {
        record(context.environment.isEnabled, context.environment.layoutDirection)
        return NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
