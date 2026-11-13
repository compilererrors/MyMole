import AppKit
import SwiftUI

/// A chart beside a list, with the divider between them. AppKit owns the
/// frames: while the divider is dragged only the two panes' frames change,
/// and the list's width is saved once, when the drag ends. A width kept in
/// the defaults and written every frame woke every `@AppStorage` in the app
/// and laid the whole pane out again for each pointer event.
struct ListSplit<Chart: View, List: View>: NSViewControllerRepresentable {
    /// The list's saved width; 0 until the divider is first dragged.
    @Binding var width: Double
    @ViewBuilder var chart: () -> Chart
    @ViewBuilder var list: () -> List
    @Environment(\.palette) private var palette

    func makeNSViewController(context: Context) -> ListSplitController {
        let controller = ListSplitController(chart: AnyView(chart().environment(\.self, context.environment)),
                                             list: AnyView(list().environment(\.self, context.environment)))
        controller.commit = { width = $0 }
        controller.saved = width
        return controller
    }

    func updateNSViewController(_ controller: ListSplitController, context: Context) {
        controller.chart.rootView = AnyView(chart().environment(\.self, context.environment))
        controller.list.rootView = AnyView(list().environment(\.self, context.environment))
        controller.commit = { width = $0 }
        if controller.saved != width { controller.saved = width }
        controller.style(accent: palette.accentText.ns, separator: palette.separator.ns, enabled: context.environment.isEnabled)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: ListSplitController, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 1_000,
               height: proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 600)
    }
}

final class ListSplitController: NSViewController {
    let chart: NSHostingController<AnyView>
    let list: NSHostingController<AnyView>
    let handle = HorizontalDragHandleView()
    var commit: (Double) -> Void = { _ in }
    /// The width as saved; a drag shows `live` until it ends.
    var saved: Double = 0 { didSet { if live == nil { arrange() } } }
    private var live: CGFloat?
    private var start: CGFloat?

    init(chart: AnyView, list: AnyView) {
        self.chart = NSHostingController(rootView: chart)
        self.list = NSHostingController(rootView: list)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = ArrangingView()
        container.arrange = { [weak self] in self?.arrange() }
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The split owns the frames; SwiftUI never measures either pane for it.
        chart.sizingOptions = []
        list.sizingOptions = []
        addChild(chart)
        addChild(list)
        view.addSubview(chart.view)
        view.addSubview(handle)
        view.addSubview(list.view)
        handle.separator = true
        handle.setAccessibilityRole(.splitter)
        handle.setAccessibilityLabel(String(localized: "List width"))
        handle.setAccessibilityIdentifier("storage.list-width")
        handle.onChange = { [weak self] translation in self?.drag(translation.width) }
        handle.onEnd = { [weak self] _ in self?.endDrag() }
        handle.onCancel = { [weak self] in self?.cancelDrag() }
        handle.onAdjust = { [weak self] direction in self?.adjust(direction) }
    }

    func style(accent: NSColor, separator: NSColor, enabled: Bool) {
        if handle.contentTintColor != accent { handle.contentTintColor = accent }
        if handle.separatorColor != separator { handle.separatorColor = separator; handle.needsDisplay = true }
        if handle.isEnabled != enabled {
            handle.isEnabled = enabled
            handle.window?.invalidateCursorRects(for: handle)
        }
    }

    private var total: CGFloat { view.bounds.width }
    private var shown: CGFloat { live ?? StorageView.listWidth(saved: saved, total: total) }

    private func drag(_ dx: CGFloat) {
        let from = start ?? StorageView.listWidth(saved: saved, total: total)
        start = from
        live = StorageView.listWidth(saved: Double(from - dx), total: total)
        arrange()
    }

    private func endDrag() {
        guard let live else { start = nil; return }
        self.live = nil
        start = nil
        saved = Double(live)
        commit(Double(live))
    }

    private func cancelDrag() {
        live = nil
        start = nil
        arrange()
    }

    private func adjust(_ direction: Int) {
        let next = Double(StorageView.listWidth(saved: Double(shown + CGFloat(direction) * 40), total: total))
        saved = next
        commit(next)
    }

    /// Frames from the width alone: chart, divider, list.
    fileprivate func arrange() {
        guard isViewLoaded else { return }
        let bounds = view.bounds
        let side = shown
        let divider = DS.Size.splitHandle
        let chartWidth = max(0, bounds.width - side - divider)
        chart.view.frame = NSRect(x: 0, y: 0, width: chartWidth, height: bounds.height)
        handle.frame = NSRect(x: chartWidth, y: 0, width: divider, height: bounds.height)
        list.view.frame = NSRect(x: chartWidth + divider, y: 0, width: side, height: bounds.height)
        let value = String(Int(side))
        if handle.configuredValue != value { handle.setAccessibilityValue(value); handle.configuredValue = value }
    }
}

/// Lays its children out through the controller whenever its size changes.
private final class ArrangingView: NSView {
    var arrange: () -> Void = {}
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        arrange()
    }
}

/// A pane's room: at least the minimum, otherwise what it is offered, and
/// the content laid out in exactly that. Unlike `.frame(minWidth:)`, it
/// never measures the content to answer: the split view beside it asks for
/// the pane's minimum on every frame of a divider drag or window resize,
/// and measuring a whole pane each time was most of that frame.
struct PaneFrame: Layout {
    let minWidth: CGFloat
    let minHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        func side(_ offered: CGFloat?, _ least: CGFloat) -> CGFloat {
            guard let offered else { return least }
            return offered.isFinite ? max(least, offered) : offered
        }
        return CGSize(width: side(proposal.width, minWidth), height: side(proposal.height, minHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }

    // No alignment guides: the default asks the content for its own, which
    // lays the whole pane out again.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

/// Lays its content out as it is, but offers its parent no alignment
/// guides. A stack asks each child for its guides, and a `ViewThatFits`
/// answers by measuring its choices again, on every frame of a resize.
/// For content that is aligned by its edges or centre, never by a text
/// baseline, the result is the same.
struct AlignmentBarrier: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

extension View {
    func withoutAlignmentGuides() -> some View { AlignmentBarrier { self } }
}
