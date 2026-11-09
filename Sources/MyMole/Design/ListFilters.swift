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

/// Propose a limit without stretching short forms to fill it. A flexible
/// max-height frame around ViewThatFits would leave large empty spaces.
struct DSFilterBody<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        FilterBodyHeight {
            ViewThatFits(in: .vertical) {
                content.fixedSize(horizontal: false, vertical: true)
                ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 360)
            }
        }
    }
}

private struct FilterBodyHeight: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(.init(width: proposal.width, height: 360)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: .init(width: bounds.width, height: min(360, bounds.height)))
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
