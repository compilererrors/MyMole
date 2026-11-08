import Testing

@testable import MyMole

/// Back and Forward between panes, as in a browser.
@Suite struct PaneHistoryTests {
    @Test func backAndForwardRetraceTheVisits() {
        var h = PaneHistory()
        #expect(!h.canGoBack && !h.canGoForward)
        // Dashboard → Deep Clean → Disk Map.
        h.left(.dashboard)
        h.left(.clean)
        #expect(h.goBack(from: .diskMap) == .clean)
        #expect(h.goBack(from: .clean) == .dashboard)
        #expect(h.goBack(from: .dashboard) == nil)
        #expect(h.goForward(from: .dashboard) == .clean)
        #expect(h.goForward(from: .clean) == .diskMap)
        #expect(h.goForward(from: .diskMap) == nil)
        #expect(h.canGoBack && !h.canGoForward)
    }

    @Test func aNewVisitDropsWhatLayAhead() {
        var h = PaneHistory()
        h.left(.dashboard)
        h.left(.clean)
        _ = h.goBack(from: .diskMap)
        #expect(h.canGoForward)
        // From Deep Clean to History instead: Disk Map is no longer ahead.
        h.left(.clean)
        #expect(!h.canGoForward)
        #expect(h.goBack(from: .history) == .clean)
        #expect(h.goBack(from: .clean) == .dashboard)
    }

    @Test func theSamePaneTwiceInARowIsOneVisit() {
        var h = PaneHistory()
        h.left(.clean)
        h.left(.clean)
        #expect(h.back == [.clean])
    }

    @Test func onlyTheLatestVisitsAreKept() {
        var h = PaneHistory()
        let panes = Pane.allCases
        for i in 0..<(PaneHistory.limit + 10) { h.left(panes[i % panes.count]) }
        #expect(h.back.count == PaneHistory.limit)
        #expect(h.back.last == panes[(PaneHistory.limit + 9) % panes.count])
    }
}
