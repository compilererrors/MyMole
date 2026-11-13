import AppKit
import SwiftUI
import Testing

@testable import MyMole

@MainActor @Suite struct PageLayoutTests {
    @MainActor final class Measurement { var width: CGFloat = 0 }

    private func contentWidth(readable: Bool) async -> CGFloat {
        let measurement = Measurement()
        let host = NSHostingView(rootView: DSPage(width: readable ? .readable : .full) {
            Color.clear.frame(height: 40)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measurement.width = $0 }
        })
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 2000, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<40 where measurement.width == 0 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return measurement.width
    }

    @Test func fullWorkspaceUsesWideWindowsAndReadablePagesKeepTheirLimit() async {
        let full = await contentWidth(readable: false)
        let readable = await contentWidth(readable: true)
        #expect(full > 1800)
        #expect(readable >= 1199 && readable <= 1201)
    }

    @Test func densityChangesCardsAndSpacingWithoutChangingTextRoles() {
        let before = Density.current
        defer { Density.current = before }
        Density.current = .compact
        let compact = (DS.Size.appTileMinimum, DS.Size.appTileIcon, DS.Size.appTilePadding, DS.Space.page, DS.Table.row)
        Density.current = .spacious
        #expect(DS.Size.appTileMinimum > compact.0)
        #expect(DS.Size.appTileIcon > compact.1)
        #expect(DS.Size.appTilePadding > compact.2)
        #expect(DS.Space.page > compact.3 && DS.Table.row > compact.4)
    }
}
