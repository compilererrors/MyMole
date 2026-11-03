import CoreGraphics
import Foundation

/// What a chart segment stands for.
public enum Segment: Sendable, Hashable {
    case folder(Folder)
    /// The files directly inside a folder, as one block.
    case files(Folder)

    public var folder: Folder {
        switch self {
        case .folder(let f), .files(let f): f
        }
    }

    public var size: Int64 {
        switch self {
        case .folder(let f): f.size
        case .files(let f): f.looseBytes
        }
    }

    public var name: String {
        switch self {
        case .folder(let f): f.name
        case .files: "Files"
        }
    }

    public var path: String {
        switch self {
        case .folder(let f): f.path
        case .files(let f): f.path
        }
    }

    public static func == (a: Segment, b: Segment) -> Bool {
        switch (a, b) {
        case (.folder(let x), .folder(let y)), (.files(let x), .files(let y)): x === y
        default: false
        }
    }

    public func hash(into h: inout Hasher) {
        switch self {
        case .folder(let f):
            h.combine(0)
            h.combine(ObjectIdentifier(f))
        case .files(let f):
            h.combine(1)
            h.combine(ObjectIdentifier(f))
        }
    }
}

/// The pieces of one folder worth drawing, largest first. Sizes are summed
/// from the parts rather than read from `size`, so a folder whose subtrees
/// are still streaming in charts what's known so far.
public func chartParts(of folder: Folder, include: (Folder) -> Bool = { _ in true }) -> [Segment] {
    var parts = folder.subfolders.filter { include($0) && $0.size > 0 }.map(Segment.folder)
    if folder.looseBytes > 0 { parts.append(.files(folder)) }
    return parts.sorted { $0.size > $1.size }
}

// MARK: - Treemap

/// Squarified treemap (after Bruls, Huizing & van Wijk): lay rectangles out
/// in rows along the shorter side, growing a row only while that keeps its
/// cells closer to square.
public enum Squarify {
    /// Rectangles for `values` (any order) inside `rect`; zero values get an
    /// empty rect. Areas are proportional to the values.
    public static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var out = Array(repeating: CGRect.zero, count: values.count)
        let total = values.reduce(0) { $0 + max($1, 0) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return out }

        let scale = Double(rect.width * rect.height) / total
        // Largest first is what makes the rows square up.
        let order = values.indices.filter { values[$0] > 0 }.sorted { values[$0] > values[$1] }
        var free = rect
        var row: [Int] = []
        var rowArea = 0.0

        func worst(_ items: [Int], _ area: Double, side: Double) -> Double {
            guard area > 0, side > 0 else { return .infinity }
            var maxA = 0.0
            var minA = Double.infinity
            for i in items {
                let a = values[i] * scale
                maxA = max(maxA, a)
                minA = min(minA, a)
            }
            let s2 = side * side
            let a2 = area * area
            return max(s2 * maxA / a2, a2 / (s2 * minA))
        }

        func place(_ items: [Int], _ area: Double) {
            let horizontal = free.width >= free.height  // strip down the left edge
            let thickness = CGFloat(area / Double(horizontal ? free.height : free.width))
            var offset: CGFloat = 0
            for i in items {
                let length = CGFloat(values[i] * scale) / thickness
                out[i] =
                    horizontal
                    ? CGRect(x: free.minX, y: free.minY + offset, width: thickness, height: length)
                    : CGRect(x: free.minX + offset, y: free.minY, width: length, height: thickness)
                offset += length
            }
            free =
                horizontal
                ? CGRect(x: free.minX + thickness, y: free.minY, width: max(0, free.width - thickness), height: free.height)
                : CGRect(x: free.minX, y: free.minY + thickness, width: free.width, height: max(0, free.height - thickness))
        }

        for i in order {
            let side = Double(min(free.width, free.height))
            let area = values[i] * scale
            if row.isEmpty || worst(row + [i], rowArea + area, side: side) <= worst(row, rowArea, side: side) {
                row.append(i)
                rowArea += area
            } else {
                place(row, rowArea)
                row = [i]
                rowArea = area
            }
        }
        if !row.isEmpty { place(row, rowArea) }
        return out
    }
}

// MARK: - Sunburst

/// One ring segment. Angles in radians, clockwise from 12 o'clock.
public struct Arc: Sendable, Identifiable {
    public let segment: Segment
    public let depth: Int  // 1 = innermost ring
    public let start: Double
    public let end: Double
    /// Which top-level slice it belongs to, for coloring by folder.
    public let branch: Int
    public var id: Segment { segment }
}

public enum Sunburst {
    /// Rings for `folder` out to `rings` levels. Segments narrower than
    /// `minAngle` are dropped (they'd be sub-pixel) — their space stays empty
    /// rather than being reassigned, so angles stay true to size.
    public static func layout(
        _ folder: Folder, rings: Int = 4, minAngle: Double = 0.004, include: (Folder) -> Bool = { _ in true }
    ) -> [Arc] {
        var arcs: [Arc] = []
        func walk(_ f: Folder, depth: Int, start: Double, span: Double, branch: Int?) {
            let parts = chartParts(of: f, include: include)
            let total = Double(parts.reduce(0) { $0 + $1.size })
            guard total > 0 else { return }
            var a = start
            for (i, p) in parts.enumerated() {
                let s = span * Double(p.size) / total
                defer { a += s }
                guard s >= minAngle else { continue }
                let b = branch ?? i
                arcs.append(Arc(segment: p, depth: depth, start: a, end: a + s, branch: b))
                if case .folder(let child) = p, depth < rings {
                    walk(child, depth: depth + 1, start: a, span: s, branch: b)
                }
            }
        }
        walk(folder, depth: 1, start: 0, span: 2 * .pi, branch: nil)
        return arcs
    }

    /// The arc under a point given in polar form (angle clockwise from 12
    /// o'clock), with `ring` 1-based.
    public static func hit(_ arcs: [Arc], ring: Int, angle: Double) -> Arc? {
        arcs.first { $0.depth == ring && angle >= $0.start && angle < $0.end }
    }
}
