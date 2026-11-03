import AppKit
import StorageKit
import SwiftUI

/// Colors for the disk charts. Folder branches get hues spaced by the golden
/// ratio, so any number of them stay distinct and neighbours never match;
/// deeper rings of a branch fade toward the background so the structure
/// reads from the center out.
enum ChartColors {
    static func branch(_ index: Int, depth: Int) -> Color {
        let hue = (0.505 + Double(index) * 0.618_034).truncatingRemainder(dividingBy: 1)
        let fade = Double(max(depth - 1, 0)) * 0.12
        return Color(hue: hue, saturation: 0.62 - fade * 0.8, brightness: 0.90 - fade * 0.6)
    }

    static func kind(_ kind: FileKind) -> Color {
        switch kind {
        case .apps: Color(hue: 0.60, saturation: 0.60, brightness: 0.92)
        case .developer: Color(hue: 0.76, saturation: 0.50, brightness: 0.88)
        case .caches: Color(hue: 0.48, saturation: 0.55, brightness: 0.80)
        case .media: Color(hue: 0.95, saturation: 0.55, brightness: 0.92)
        case .documents: Color(hue: 0.08, saturation: 0.60, brightness: 0.95)
        case .archives: Color(hue: 0.14, saturation: 0.65, brightness: 0.92)
        case .system: Color(hue: 0.58, saturation: 0.12, brightness: 0.70)
        case .other: Color(hue: 0.60, saturation: 0.08, brightness: 0.55)
        }
    }

    /// The kind holding most of a segment's bytes.
    static func dominantKind(_ s: Segment) -> FileKind {
        let bytes: KindBytes =
            switch s {
            case .folder(let f): f.totalBytes
            case .files(let f): f.ownBytes
            }
        return FileKind.allCases.max { bytes[$0] < bytes[$1] } ?? .other
    }

    static func color(for s: Segment, branch: Int, depth: Int, byKind: Bool) -> Color {
        if byKind { return kind(dominantKind(s)) }
        if case .files = s { return Color(nsColor: .tertiaryLabelColor) }
        return ChartColors.branch(branch, depth: depth)
    }
}
