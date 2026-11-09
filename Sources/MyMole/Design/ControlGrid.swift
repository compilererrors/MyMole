import SwiftUI

/// Labelled fields share column edges and keep their labels with their control.
/// Rows grow to their content instead of clipping multiline labels.
struct DSControlGrid: Layout {
    var minimum: CGFloat = 240
    var spacing: CGFloat

    private func columns(count: Int, width: CGFloat, minimum: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        let fit = min(count, max(1, Int((max(0, width) + spacing) / (minimum + spacing))))
        let rows = (count + fit - 1) / fit
        return (count + rows - 1) / rows
    }

    private func plan(_ subviews: Subviews, width: CGFloat) -> (columns: Int, cell: CGFloat, heights: [CGFloat]) {
        let intrinsicMinimum = subviews.map { $0.sizeThatFits(.init(width: 0, height: nil)).width }.max() ?? 0
        let columns = columns(count: subviews.count, width: width, minimum: max(minimum, intrinsicMinimum))
        let cell = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        var heights: [CGFloat] = []
        for index in subviews.indices {
            let height = subviews[index].sizeThatFits(.init(width: cell, height: nil)).height
            if index % columns == 0 { heights.append(height) }
            else { heights[heights.count - 1] = max(heights.last ?? 0, height) }
        }
        return (columns, cell, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
            ?? CGFloat(subviews.count) * minimum + CGFloat(max(0, subviews.count - 1)) * spacing
        let heights = plan(subviews, width: width).heights
        return CGSize(width: width, height: heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = plan(subviews, width: bounds.width)
        var y = bounds.minY
        for index in subviews.indices {
            let column = index % layout.columns, row = index / layout.columns
            if column == 0, row > 0 { y += layout.heights[row - 1] + spacing }
            subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (layout.cell + spacing), y: y),
                                 anchor: .topLeading, proposal: .init(width: layout.cell, height: layout.heights[row]))
        }
    }
}
