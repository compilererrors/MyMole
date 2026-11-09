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
            for editing in [false, true] {
                try await checkCardFrames(compact: density == .compact, spacing: density == .compact ? 12 : 15, editing: editing)
            }
        }
    }

    private func checkCardFrames(compact: Bool, spacing: CGFloat, editing: Bool) async throws {
        let host = NSHostingView(rootView: Panel(expanded: false, compact: compact, spacing: spacing, editing: editing))
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
        host.rootView = Panel(expanded: true, compact: compact, spacing: spacing, editing: editing)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        #expect(frames(in: host) == before)
        for card in StatusLayout().visible {
            #expect((before[card.id]?.height ?? 0) >= card.height(compactDensity: compact) - 1)
        }
        for row in Dictionary(grouping: Array(before.values), by: \.minY).values {
            #expect(row.allSatisfy { abs($0.height - row[0].height) < 1 })
        }
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
    let compact: Bool
    let spacing: CGFloat
    let editing: Bool
    private let layout = StatusLayout()
    var body: some View {
        StatusGrid(cards: layout.visible, compactDensity: compact, editing: editing, spacing: spacing) {
            ForEach(layout.visible) { card in
                StatusCard(card: card.id, editing: editing, drag: StatusCardDrag(card: card.id, session: UUID())) {
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
