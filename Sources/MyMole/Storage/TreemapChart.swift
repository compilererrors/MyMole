import StorageKit
import SwiftUI

/// Two levels of nested rectangles: the current folder's contents, and
/// inside each big one, its own contents. Click a block to step into it.
struct TreemapChart: View {
    @Bindable var model: StorageModel
    @State private var cells: [Cell] = []
    @State private var drawing: SunburstChart.LayoutKey?

    struct Cell {
        let rect: CGRect
        let segment: Segment
        let level: Int
        let branch: Int
    }

    var body: some View {
        GeometryReader { geo in
            let cells = cells
            let bounds = CGRect(origin: .zero, size: geo.size)
            Canvas { ctx, _ in
                for c in cells {
                    let fill = fill(for: c)
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
                    }
                }

                // Labels follow the fills so a nested name stays inside its
                // own block. Tiny blocks borrow their parent's label strip.
                let hovered = cells.last { $0.level > 1 && $0.segment == model.hovered }
                let labeled = hovered.map { c in
                    ChartLabel.draw(
                        name(of: c.segment),
                        detail: ByteCountFormatter.string(fromByteCount: c.segment.size, countStyle: .file),
                        in: c.rect.insetBy(dx: 7, dy: 4), on: fill(for: c), ctx: ctx)
                } ?? false
                for c in cells where c.level == 1 && c.rect.height > 34 {
                    let rect = CGRect(x: c.rect.minX + 7, y: c.rect.minY + 4, width: c.rect.width - 14, height: 28)
                    if !labeled, let hovered, hovered.branch == c.branch,
                       ChartLabel.draw(name(of: hovered.segment),
                                       detail: ByteCountFormatter.string(fromByteCount: hovered.segment.size, countStyle: .file),
                                       in: rect, on: fill(for: c), ctx: ctx) {
                        continue
                    }
                    ChartLabel.draw(
                        name(of: c.segment),
                        detail: ByteCountFormatter.string(fromByteCount: c.segment.size, countStyle: .file),
                        in: rect, on: fill(for: c), ctx: ctx)
                }
            }
            .dsCrossfade(value: drawing)
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
                let next = layout(in: bounds)
                withAnimation(model.showingLive ? nil : Motion.content) {
                    self.cells = next
                    drawing = SunburstChart.LayoutKey(model)
                }
            }
        }
        .padding(16)
    }

    private func fill(for cell: Cell) -> Color {
        let color = ChartColors.color(for: cell.segment, branch: cell.branch, depth: cell.level, byKind: model.colorByKind)
        return model.isHighlighted(cell.segment) ? color.mix(with: .white, by: 0.3) : color
    }

    private func name(of segment: Segment) -> String {
        if case .files(let folder) = segment, folder.smallFileCount == 0, folder.listedFiles.count == 1 {
            return folder.listedFiles[0].name
        }
        return segment.name
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
