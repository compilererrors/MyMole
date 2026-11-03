import StorageKit
import SwiftUI

/// Two levels of nested rectangles: the current folder's contents, and
/// inside each big one, its own contents. Click a block to step into it.
struct TreemapChart: View {
    @Bindable var model: StorageModel
    @State private var cells: [Cell] = []

    struct Cell {
        let rect: CGRect
        let segment: Segment
        let level: Int
        let branch: Int
    }

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            Canvas { ctx, _ in
                for c in cells {
                    let base = ChartColors.color(for: c.segment, branch: c.branch, depth: c.level, byKind: model.colorByKind)
                    let hot = model.isHighlighted(c.segment)
                    let fill = hot ? base.mix(with: .white, by: 0.3) : base
                    let shape = Path(roundedRect: c.rect.insetBy(dx: 1, dy: 1), cornerRadius: c.level == 1 ? 6 : 3)
                    // A soft top-light gradient gives each block some depth
                    // without the noise of a full cushion render.
                    ctx.fill(
                        shape,
                        with: .linearGradient(
                            Gradient(colors: [fill.mix(with: .white, by: 0.12), fill.mix(with: .black, by: 0.12)]),
                            startPoint: c.rect.origin, endPoint: CGPoint(x: c.rect.maxX, y: c.rect.maxY)))
                    if c.level == 1 {
                        ctx.stroke(shape, with: .color(.black.opacity(0.25)), lineWidth: 1)
                        if c.rect.height > 34 {
                            // The block's label strip, above its second level.
                            ChartLabel.draw(
                                c.segment.name,
                                detail: ByteCountFormatter.string(fromByteCount: c.segment.size, countStyle: .file),
                                in: CGRect(x: c.rect.minX + 7, y: c.rect.minY + 4, width: c.rect.width - 14, height: 28),
                                on: fill, ctx: ctx)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let seg = cells.last { $0.rect.contains(p) }?.segment
                    if model.hovered != seg { model.hovered = seg }
                case .ended:
                    if model.hovered != nil { model.hovered = nil }
                }
            }
            .onTapGesture { p in
                if case .folder(let f)? = cells.last(where: { $0.rect.contains(p) })?.segment { model.open(f) }
            }
            .task(id: Key(model: model, size: geo.size)) {
                cells = layout(in: bounds)
            }
        }
        .padding(16)
    }

    private struct Key: Hashable {
        let folder: ObjectIdentifier?
        let revision: Int
        let width: Int
        let height: Int

        @MainActor init(model: StorageModel, size: CGSize) {
            folder = model.current.map { ObjectIdentifier($0) }
            revision = model.revision
            width = Int(size.width)
            height = Int(size.height)
        }
    }

    private func layout(in bounds: CGRect) -> [Cell] {
        guard let cur = model.current else { return [] }
        let ready = model.isReady
        let parts = chartParts(of: cur, include: ready)
        let rects = Squarify.layout(parts.map { Double($0.size) }, in: bounds)
        var out: [Cell] = []
        for (i, (part, rect)) in zip(parts, rects).enumerated() where rect.width >= 1 && rect.height >= 1 {
            out.append(Cell(rect: rect, segment: part, level: 1, branch: i))
            // Second level inside blocks with room, below the label strip.
            guard case .folder(let f) = part, rect.width > 60, rect.height > 60 else { continue }
            let inner = CGRect(x: rect.minX + 4, y: rect.minY + 34, width: rect.width - 8, height: rect.height - 38)
            guard inner.width > 10, inner.height > 10 else { continue }
            let kids = chartParts(of: f, include: ready)
            for (k, r) in zip(kids, Squarify.layout(kids.map { Double($0.size) }, in: inner)) where r.width >= 2 && r.height >= 2 {
                out.append(Cell(rect: r, segment: k, level: 2, branch: i))
            }
        }
        return out
    }
}
