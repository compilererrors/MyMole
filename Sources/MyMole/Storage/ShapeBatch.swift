import SwiftUI

/// Draws many shapes that never overlap with one fill per color and one
/// stroke for all their edges. A chart redraws on every frame of a resize;
/// a fill and a stroke for each of its thousands of segments changed the
/// shading as often, and that was most of the frame.
struct ShapeBatch {
    private var fills: [Color: Path] = [:]
    private var colors: [Color] = []
    private var edges = Path()

    mutating func add(_ path: Path, color: Color, edged: Bool = true) {
        if fills[color] == nil { colors.append(color) }
        fills[color, default: Path()].addPath(path)
        if edged { edges.addPath(path) }
    }

    /// Fills in the order their colors first came, then every edge at once.
    func draw(in ctx: GraphicsContext, edge: Color?, lineWidth: CGFloat = 1) {
        for color in colors { if let path = fills[color] { ctx.fill(path, with: .color(color)) } }
        if let edge, !edges.isEmpty { ctx.stroke(edges, with: .color(edge), lineWidth: lineWidth) }
    }
}
