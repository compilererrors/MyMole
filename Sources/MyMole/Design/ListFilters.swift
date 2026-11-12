import AppKit
import SwiftUI

/// Filters sit next to their results. Opening this never starts a scan.
struct DSFilterButton<Content: View>: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let count: Int
    let clear: () -> Void
    @ViewBuilder var content: Content
    @State private var presented = false

    init(_ title: LocalizedStringResource, detail: LocalizedStringResource, count: Int, clear: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.count = count
        self.clear = clear
        self.content = content()
    }

    var body: some View {
        Button { presented.toggle() } label: {
            Label(count == 0 ? String(localized: "Filters") : String(localized: "Filters (\(count))"),
                  systemImage: count == 0 ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .help("Filter the results below")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                DSFilterBody { content }
                Divider()
                HStack(spacing: DS.Space.sm) {
                    Button("Clear Filters", action: clear).disabled(count == 0)
                    Spacer()
                    Button("Done") { presented = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(DS.Space.lg)
            .frame(width: 340)
            .controlSize(.regular)
            .dialogControls()
            .dialogKeyboard()
        }
    }
}

/// Short forms keep their natural height; large collections only create
/// controls as they enter the viewport.
struct DSFilterBody<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Group(subviews: content) { fields in
            if fields.count > 12 {
                List {
                    ForEach(fields) { field in
                        field
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.horizontal, 0, for: .scrollContent)
                .frame(height: 360)
            } else {
                MeasuredFilterBody {
                    VStack(alignment: .leading, spacing: 8) { content }
                }
            }
        }
    }
}

private struct MeasuredFilterBody<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> FilterBodyScroll {
        let scroll = FilterBodyScroll()
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: FilterBodyScroll, context: Context) {
        scroll.content = AnyView(content.environment(\.self, context.environment))
        scroll.invalidateContent()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FilterBodyScroll, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 340
        guard width > 0 else { return .zero }
        return CGSize(width: width, height: min(360, nsView.contentHeight(width: width)))
    }
}

final class FilterBodyScroll: NSScrollView {
    var content = AnyView(EmptyView())
    private let host = NSHostingController(rootView: AnyView(EmptyView()))
    private var reportedHeight: CGFloat = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        host.sizingOptions = []
        documentView = host.view
    }

    required init?(coder: NSCoder) { fatalError() }

    func invalidateContent() {
        host.rootView = AnyView(content.frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                guard let self, abs(self.reportedHeight - height) > 0.5 else { return }
                self.reportedHeight = height
                self.needsLayout = true
                self.invalidateIntrinsicContentSize()
            })
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    func contentHeight(width: CGFloat) -> CGFloat {
        host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    override func layout() {
        super.layout()
        let width = contentView.bounds.width
        guard width > 0 else { return }
        host.view.setFrameSize(NSSize(width: width, height: contentHeight(width: width)))
    }
}

/// Every active criterion stays visible after its editor is closed.
struct DSFilterChip: View {
    let title: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: DS.Space.xs) {
                Text(title).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(String(localized: "Remove filter: \(title)"))
        .accessibilityLabel(String(localized: "Remove filter: \(title)"))
    }
}
