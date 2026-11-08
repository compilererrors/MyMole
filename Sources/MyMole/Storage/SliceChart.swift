import StorageKit
import SwiftUI

/// One level of the current folder as a pie or a wheel (a ring with the
/// total in the middle). Small items fold into one "Other" slice so every
/// slice that's drawn is big enough to see and to label.
struct SliceChart: View {
    @Environment(\.palette) private var palette
    enum Style { case pie, wheel }

    @Bindable var model: StorageModel
    let style: Style
    @State private var slices: [Slice] = []

    struct Slice {
        let segment: Segment?  // nil for "Other"
        let name: String
        let size: Int64
        let start: Double  // radians, clockwise from 12 o'clock
        let end: Double
        let color: Color
        var mid: Double { (start + end) / 2 }
        var fraction: Double { (end - start) / (2 * .pi) }
    }

    private static let maxSlices = 18

    var body: some View {
        GeometryReader { geo in
            let g = Geo(size: geo.size, style: style)
            ZStack {
                Canvas { ctx, _ in
                    for s in slices {
                        let hot = s.segment.map(model.isHighlighted) ?? false
                        let path = g.path(s)
                        ctx.fill(path, with: .color(hot ? s.color.mix(with: .white, by: 0.3) : s.color))
                        ctx.stroke(path, with: .color(palette.workspace.color), lineWidth: 1.5)
                    }
                    drawLabels(ctx, g)
                }
                if style == .wheel { center(g) }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let seg = g.hit(p, slices)?.segment
                    if model.hovered != seg { model.hovered = seg }
                case .ended:
                    if model.hovered != nil { model.hovered = nil }
                }
            }
            .onTapGesture { p in
                if style == .wheel && g.inHole(p) {
                    model.back()
                } else if case .folder(let f)? = g.hit(p, slices)?.segment {
                    model.open(f)
                }
            }
        }
        .task(id: SunburstChart.LayoutKey(model)) { slices = layout() }
        .padding(DS.Space.lg)
    }

    private func layout() -> [Slice] {
        guard let cur = model.current else { return [] }
        let parts = chartParts(of: cur, include: model.isReady)
        let total = Double(parts.reduce(0) { $0 + $1.size })
        guard total > 0 else { return [] }
        // Keep slices of at least 1.5%, up to a readable count; the rest is "Other".
        var shown = parts.prefix(Self.maxSlices).filter { Double($0.size) / total >= 0.015 }
        if shown.isEmpty, let first = parts.first { shown = [first] }
        let rest = parts.dropFirst(shown.count)
        var out: [Slice] = []
        var a = 0.0
        for (i, p) in shown.enumerated() {
            let span = 2 * .pi * Double(p.size) / total
            out.append(
                Slice(segment: p, name: p.name, size: p.size, start: a, end: a + span,
                      color: ChartColors.color(for: p, branch: i, depth: 1, byKind: model.colorByKind)))
            a += span
        }
        if !rest.isEmpty {
            let size = rest.reduce(0) { $0 + $1.size }
            out.append(
                Slice(segment: nil, name: String(localized: "\(rest.count) smaller items"), size: size, start: a, end: 2 * .pi,
                      color: Color(nsColor: .tertiaryLabelColor)))
        }
        return out
    }

    /// A slice wide enough gets its name inside it; on the pie, the rest of
    /// the bigger slices are named outside on a short leader line. Names
    /// are whole either way (see `ChartLabel`).
    private func drawLabels(_ ctx: GraphicsContext, _ g: Geo) {
        let background = palette.workspace.color
        var outside: [(slice: Slice, y: CGFloat)] = []
        for s in slices {
            let size = ByteCountFormatter.string(fromByteCount: s.size, countStyle: .file)
            if ChartLabel.draw(s.name, detail: size, in: g.innerBox(s), on: s.color, placement: .center, large: true, ctx: ctx) {
                continue
            }
            if style == .pie, s.fraction >= 0.015 {
                outside.append((s, g.center.y - cos(s.mid) * (g.radius + 12)))
            }
        }
        // Outside labels stand in a column on each side of the pie, pushed
        // apart so none overlap, each tied to its slice by a leader line.
        let rowHeight: CGFloat = 36
        for right in [true, false] {
            var side = outside.filter { (sin($0.slice.mid) >= 0) == right }.sorted { $0.y < $1.y }
            guard !side.isEmpty else { continue }
            for i in side.indices.dropFirst() { side[i].y = max(side[i].y, side[i - 1].y + rowHeight) }
            let overflow = side[side.count - 1].y + rowHeight / 2 - g.bottom
            if overflow > 0 {
                for i in side.indices { side[i].y -= overflow }
                for i in side.indices.reversed().dropFirst() { side[i].y = min(side[i].y, side[i + 1].y - rowHeight) }
            }
            let column = g.center.x + (right ? 1 : -1) * (g.radius + 24)
            for (s, y) in side {
                let box = CGRect(x: right ? column + 4 : column - 4 - g.labelWidth, y: y - rowHeight / 2, width: g.labelWidth, height: rowHeight)
                let size = ByteCountFormatter.string(fromByteCount: s.size, countStyle: .file)
                guard ChartLabel.draw(s.name, detail: size, in: box, on: background, placement: right ? .leading : .trailing, large: true, ctx: ctx)
                else { continue }
                let dir = CGPoint(x: sin(s.mid), y: -cos(s.mid))
                let p0 = CGPoint(x: g.center.x + dir.x * g.radius, y: g.center.y + dir.y * g.radius)
                let p1 = CGPoint(x: g.center.x + dir.x * (g.radius + 10), y: g.center.y + dir.y * (g.radius + 10))
                var line = Path()
                line.move(to: p0)
                line.addLine(to: p1)
                line.addLine(to: CGPoint(x: column, y: y))
                ctx.stroke(line, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
            }
        }
    }

    private func center(_ g: Geo) -> some View {
        let hovered = slices.first { $0.segment != nil && $0.segment == model.hovered }
        let size = hovered?.size ?? slices.reduce(0) { $0 + $1.size }
        return VStack(spacing: DS.Space.xs) {
            DSName(hovered?.name ?? model.current?.name ?? "", .heading, lines: 2)
                .multilineTextAlignment(.center)
            Metric(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            if hovered == nil, model.current?.parent != nil {
                Label("Back", systemImage: "arrow.uturn.backward").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: g.hole * 1.5)
        .allowsHitTesting(false)
    }

    struct Geo {
        let center: CGPoint
        let radius: CGFloat
        let hole: CGFloat
        let labelWidth: CGFloat
        let bottom: CGFloat

        init(size: CGSize, style: Style) {
            labelWidth = style == .pie ? min(120, size.width * 0.16) : 0
            let margin: CGFloat = style == .pie ? labelWidth + 32 : 0
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            bottom = size.height
            radius = max(30, min(size.width / 2 - margin, size.height / 2 - (style == .pie ? 26 : 0)))
            hole = style == .wheel ? radius * 0.58 : 0
        }

        private func angle(_ a: Double) -> Angle { .radians(a - .pi / 2) }

        func path(_ s: Slice) -> Path {
            var p = Path()
            if hole > 0 {
                p.addArc(center: center, radius: radius, startAngle: angle(s.start), endAngle: angle(s.end), clockwise: false)
                p.addArc(center: center, radius: hole, startAngle: angle(s.end), endAngle: angle(s.start), clockwise: true)
            } else {
                p.move(to: center)
                p.addArc(center: center, radius: radius, startAngle: angle(s.start), endAngle: angle(s.end), clockwise: false)
            }
            p.closeSubpath()
            return p
        }

        /// The room for a label inside a slice: centered at the middle of the
        /// slice's band, as wide as the slice is there.
        func innerBox(_ s: Slice) -> CGRect {
            let band = radius - hole
            let r = hole + band * (hole > 0 ? 0.5 : 0.6)
            let span = min(s.end - s.start, .pi)
            let chord = 2 * r * CGFloat(sin(span / 2))
            let w = min(chord * 0.8, band * 0.95, 160)
            let h = min(chord * 0.6, band * 0.6)
            let c = CGPoint(x: center.x + CGFloat(sin(s.mid)) * r, y: center.y - CGFloat(cos(s.mid)) * r)
            return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        }

        func inHole(_ p: CGPoint) -> Bool { hypot(p.x - center.x, p.y - center.y) < hole }

        func hit(_ p: CGPoint, _ slices: [Slice]) -> Slice? {
            let r = hypot(p.x - center.x, p.y - center.y)
            guard r >= hole, r <= radius else { return nil }
            var a = atan2(Double(p.y - center.y), Double(p.x - center.x)) + .pi / 2
            if a < 0 { a += 2 * .pi }
            return slices.first { a >= $0.start && a < $0.end }
        }
    }
}
