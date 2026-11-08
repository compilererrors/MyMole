import AppKit
import SwiftUI
import Testing

@testable import MyMole

@MainActor @Suite struct StatusCardStabilityTests {
    @Test func expandingAndMissingReadingsKeepEveryCardInPlace() async throws {
        let previous = Density.current
        defer { Density.current = previous }
        for density in Density.allCases {
            Density.current = density
            try await checkCardFrames()
        }
    }

    private func checkCardFrames() async throws {
        let host = NSHostingView(rootView: Panel(expanded: false))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 1800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        let before = frames(in: host)
        #expect(before.count == StatusCardID.allCases.count)
        host.rootView = Panel(expanded: true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        #expect(frames(in: host) == before)
        #expect(before.values.allSatisfy { abs($0.height - 320) < 1 })
    }

    private func frames(in host: NSView) -> [StatusCardID: CGRect] {
        var result: [StatusCardID: CGRect] = [:]
        var remaining = [host]
        while let view = remaining.popLast() {
            if let probe = view as? ProbeView { result[probe.card] = probe.convert(probe.bounds, to: host) }
            remaining += view.subviews
        }
        return result
    }
}

private struct Panel: View {
    let expanded: Bool
    private let layout = StatusLayout()
    var body: some View {
        StatusGrid(sizes: layout.visible.map(\.size), spacing: DS.Space.md) {
            ForEach(layout.visible) { card in
                StatusCard(card: card.id) {
                    if expanded {
                        ForEach(0..<30) { index in
                            Text("Synthetic reading \(index): details that wrap and change with a new sample.")
                        }
                    } else {
                        Text("No reading available right now.")
                    }
                } actions: {
                    Button("Example action") {}
                }
                .background(Probe(card: card.id))
            }
        }
        .frame(width: 720)
    }
}

private final class ProbeView: NSView {
    let card: StatusCardID
    init(card: StatusCardID) {
        self.card = card
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
}

private struct Probe: NSViewRepresentable {
    let card: StatusCardID
    func makeNSView(context: Context) -> ProbeView { ProbeView(card: card) }
    func updateNSView(_ view: ProbeView, context: Context) {}
}
