import StorageKit
import SwiftUI

/// Icicle chart: the same hierarchy as Rings, unrolled into columns. Each
/// column is one level deeper; a block's height is its share of the
/// current folder. Straight edges make names easy to label and read.
struct ColumnsChart: View {
    @Bindable var model: StorageModel
    @State private var arcs: [Arc] = []
    @State private var drawing: SunburstChart.LayoutKey?

    private static let levels = 4

    var body: some View {
        GeometryReader { geo in
            let arcs = arcs
            let colWidth = geo.size.width / CGFloat(Self.levels)
            let h = geo.size.height
            Canvas { ctx, _ in
                var batch = ShapeBatch()
                var labels: [(Arc, CGRect, Color)] = []
                for arc in arcs {
                    let r = rect(arc, colWidth: colWidth, height: h)
                    guard r.height >= 1 else { continue }
                    let color = ChartColors.color(for: arc.segment, branch: arc.branch, depth: arc.depth, byKind: model.colorByKind)
                    let hot = model.isHighlighted(arc.segment)
                    let fill = hot ? color.mix(with: .white, by: 0.3) : color
                    batch.add(Path(roundedRect: r.insetBy(dx: 1, dy: 0.5), cornerRadius: min(4, r.height / 3)), color: fill, edged: false)
                    if r.height >= 20 { labels.append((arc, r, fill)) }
                }
                // Blocks never overlap, so their labels can follow all fills.
                batch.draw(in: ctx, edge: nil)
                for (arc, r, fill) in labels {
                    ChartLabel.draw(
                        arc.segment.name,
                        detail: ByteCountFormatter.string(fromByteCount: arc.segment.size, countStyle: .file),
                        in: r.insetBy(dx: 6, dy: 3), on: fill, emphasis: arc.depth == 1, ctx: ctx)
                }
            }
            .dsCrossfade(value: drawing)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let seg = hit(p, colWidth: colWidth, height: h)?.segment
                    if model.hovered != seg { model.hovered = seg }
                case .ended:
                    if model.hovered != nil { model.hovered = nil }
                }
            }
            .onTapGesture { p in
                if case .folder(let f)? = hit(p, colWidth: colWidth, height: h)?.segment { model.open(f) }
            }
            .task(id: Key(base: SunburstChart.LayoutKey(model), height: Int(h))) {
                let next = model.current.flatMap { cur in h > 0 ? Sunburst.layout(cur, rings: Self.levels, minAngle: 2 * .pi / Double(h), include: model.isReady) : nil } ?? []
                withAnimation(model.showingLive ? nil : Motion.content) {
                    self.arcs = next
                    drawing = SunburstChart.LayoutKey(model)
                }
            }
        }
        .padding(DS.Space.lg)
    }

    private struct Key: Hashable {
        let base: SunburstChart.LayoutKey
        let height: Int
    }

    private func rect(_ a: Arc, colWidth: CGFloat, height: CGFloat) -> CGRect {
        let y0 = CGFloat(a.start / (2 * .pi)) * height
        let y1 = CGFloat(a.end / (2 * .pi)) * height
        return CGRect(x: CGFloat(a.depth - 1) * colWidth, y: y0, width: colWidth, height: y1 - y0)
    }

    private func hit(_ p: CGPoint, colWidth: CGFloat, height: CGFloat) -> Arc? {
        let depth = Int(p.x / colWidth) + 1
        let angle = Double(p.y / height) * 2 * .pi
        return Sunburst.hit(arcs, ring: depth, angle: angle)
    }
}
