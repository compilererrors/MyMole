import SwiftUI

/// Geometry depends on preferences and width, never on live text or readings.
struct StatusGrid: Layout {
    let sizes: [StatusCardSize]
    let spacing: CGFloat

    nonisolated static func frames(sizes: [StatusCardSize], width: CGFloat, spacing: CGFloat) -> [CGRect] {
        let width = width.isFinite ? max(1, width) : 900
        let columns = max(1, min(3, Int((width + spacing) / (280 + spacing))))
        let unit = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        var column = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        return sizes.map { size in
            let span = min(columns, size.span)
            if column + span > columns {
                y += rowHeight + spacing
                column = 0
                rowHeight = 0
            }
            let rect = CGRect(
                x: CGFloat(column) * (unit + spacing), y: y,
                width: CGFloat(span) * unit + CGFloat(span - 1) * spacing, height: size.height)
            column += span
            rowHeight = max(rowHeight, size.height)
            return rect
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 900
        let frames = Self.frames(sizes: sizes, width: width, spacing: spacing)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, Self.frames(sizes: sizes, width: bounds.width, spacing: spacing)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}

struct StatusCard<Content: View, Actions: View>: View {
    let card: StatusCardID
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Label(card.title, systemImage: card.symbol)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: DS.Space.sm)
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Actions for \(card.title)")
                .help("Actions and layout for \(card.title)")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.sm) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dsCard()
        .clipped()
        .contextMenu { actions }
    }
}
