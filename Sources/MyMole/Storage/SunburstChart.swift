import StorageKit
import SwiftUI

/// Rings of folders around the current one: the inner ring is its contents,
/// each ring out is the next level down. Click a segment to step into it,
/// click the middle to step back out.
struct SunburstChart: View {
    @Environment(\.palette) private var palette
    @Bindable var model: StorageModel
    @State private var arcs: [Arc] = []
    @State private var drawing: SunburstChart.LayoutKey?

    private static let rings = 4

    var body: some View {
        GeometryReader { geo in
            let arcs = arcs
            let g = Geometry(size: geo.size, rings: Self.rings)
            ZStack {
                Canvas { ctx, _ in
                    var batch = ShapeBatch()
                    for arc in arcs where g.isVisible(arc) {
                        let hot = model.isHighlighted(arc.segment)
                        let color = ChartColors.color(
                            for: arc.segment, branch: arc.branch, depth: arc.depth, byKind: model.colorByKind)
                        batch.add(g.path(arc), color: hot ? color.mix(with: .white, by: 0.35) : color)
                    }
                    batch.draw(in: ctx, edge: palette.workspace.color)
                }
                .dsCrossfade(value: drawing)
                center(g)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let seg = g.hit(p, arcs)?.segment
                    if model.hovered != seg { model.hovered = seg }
                case .ended:
                    if model.hovered != nil { model.hovered = nil }
                }
            }
            .onTapGesture { p in
                if g.inCenter(p) {
                    model.back()
                } else if case .folder(let f) = g.hit(p, arcs)?.segment {
                    model.open(f)
                }
            }
        }
        .task(id: LayoutKey(model)) {
            let key = LayoutKey(model)
            // A map still being written is laid out afresh every time.
            let map = model.showingLive ? nil : model.root.map(ObjectIdentifier.init)
            let next: [Arc]
            if let map, let kept = ChartLayouts.sunburst.value(key, map: map) {
                next = kept
            } else {
                next = model.current.map { Sunburst.layout($0, rings: Self.rings, include: model.isReady) } ?? []
                if let map { ChartLayouts.sunburst.keep(next, for: key, map: map) }
            }
            withAnimation(model.showingLive ? nil : Motion.content) {
                arcs = next
                drawing = LayoutKey(model)
            }
        }
        .padding(16)
    }

    /// What's in the middle: the hovered segment, or the folder itself.
    private func center(_ g: Geometry) -> some View {
        let seg = model.hovered
        let name = seg?.name ?? model.current?.name ?? ""
        let size = seg?.size ?? currentSize
        return VStack(spacing: 4) {
            DSName(name, .heading, lines: 3)
                .multilineTextAlignment(.center)
            Metric(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            if seg == nil, let cur = model.current, cur.parent != nil {
                Label("Back", systemImage: "arrow.uturn.backward")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .folder(let f)? = seg {
                Text("\(f.fileCount.formatted()) files").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: g.hole * 1.6)
        .allowsHitTesting(false)
    }

    /// Size of the current folder as charted (sums streamed parts mid-scan).
    private var currentSize: Int64 { model.current.map(model.chartedSize) ?? 0 }

    struct LayoutKey: Hashable {
        let folder: ObjectIdentifier?
        let revision: Int

        @MainActor init(_ m: StorageModel) {
            folder = m.current.map { ObjectIdentifier($0) }
            revision = m.revision
        }
    }

    /// Ring geometry for a given size.
    struct Geometry {
        let center: CGPoint
        let hole: CGFloat
        let ring: CGFloat

        init(size: CGSize, rings: Int) {
            let radius = max(min(size.width, size.height) / 2, 40)
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            hole = radius * 0.34
            ring = (radius - hole) / CGFloat(rings)
        }

        func inCenter(_ p: CGPoint) -> Bool { hypot(p.x - center.x, p.y - center.y) < hole }

        /// At least half a pixel along its outer edge. A thinner segment is
        /// covered by its own 1-point edge, drawn in the background color.
        func isVisible(_ arc: Arc) -> Bool {
            let outer = hole + CGFloat(arc.depth) * ring
            return CGFloat(arc.end - arc.start) * outer >= 0.5
        }

        /// Arc angles run clockwise from 12 o'clock; SwiftUI's from 3 o'clock.
        private func angle(_ a: Double) -> Angle { .radians(a - .pi / 2) }

        func path(_ arc: Arc) -> Path {
            let inner = hole + CGFloat(arc.depth - 1) * ring + 0.5
            let outer = inner + ring - 1
            var p = Path()
            p.addArc(center: center, radius: outer, startAngle: angle(arc.start), endAngle: angle(arc.end), clockwise: false)
            p.addArc(center: center, radius: inner, startAngle: angle(arc.end), endAngle: angle(arc.start), clockwise: true)
            p.closeSubpath()
            return p
        }

        func hit(_ p: CGPoint, _ arcs: [Arc]) -> Arc? {
            let dx = p.x - center.x
            let dy = p.y - center.y
            let r = hypot(dx, dy)
            guard r >= hole else { return nil }
            let ringIndex = Int((r - hole) / ring) + 1
            var a = atan2(Double(dy), Double(dx)) + .pi / 2
            if a < 0 { a += 2 * .pi }
            return Sunburst.hit(arcs, ring: ringIndex, angle: a)
        }
    }
}
