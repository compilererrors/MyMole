import AppKit
import SwiftUI

/// The main window's sidebar beside the pane.
struct MainSplit<Sidebar: View, Detail: View>: View {
    @Binding var sidebarShown: Bool
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { sidebarShown ? .all : .detailOnly },
            set: { sidebarShown = $0 != .detailOnly })) {
            sidebar()
                .navigationSplitViewColumnWidth(min: MainSplitMetrics.sidebarMin, ideal: MainSplitMetrics.sidebarIdeal,
                                                max: MainSplitMetrics.sidebarMax)
        } detail: {
            detail()
        }
    }
}

enum MainSplitMetrics {
    static let sidebarMin: CGFloat = 210
    static let sidebarIdeal: CGFloat = 230
    static let sidebarMax: CGFloat = 320
}
