import StorageKit
import SwiftUI

/// The current folder's contents as ranked bars: the plainest view, for
/// reading exact names and sizes.
struct BarsChart: View {
    @Environment(\.palette) private var palette
    @Bindable var model: StorageModel

    private static let limit = 40

    var body: some View {
        if let cur = model.current {
            let parts = chartParts(of: cur, include: model.isReady)
            let biggest = Double(parts.first?.size ?? 1)
            let total = Double(max(parts.reduce(0) { $0 + $1.size }, 1))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.sm) {
                    ForEach(Array(parts.prefix(Self.limit).enumerated()), id: \.element) { i, p in
                        bar(p, color: ChartColors.color(for: p, branch: i, depth: 1, byKind: model.colorByKind),
                            fraction: Double(p.size) / biggest, share: Double(p.size) / total)
                    }
                    if parts.count > Self.limit {
                        DSText("\(parts.count - Self.limit) smaller items not shown — see the list on the right.", .metadata)
                    }
                }
                .animation(model.showingLive ? nil : Motion.content, value: model.revision)
                .padding(DS.Space.page)
            }
        }
    }

    private func bar(_ p: Segment, color: Color, fraction: Double, share: Double) -> some View {
        let hot = model.isHighlighted(p)
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                DSName(p.name, .lead, lines: 2)
                Spacer(minLength: DS.Space.sm)
                DSValue(String(format: "%.1f%%", share * 100), .metadata)
                DSValue(bytes: p.size, .lead, weight: .semibold)
            }
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 4)
                    .fill(hot ? color.mix(with: .white, by: 0.3) : color)
                    .frame(width: max(4, g.size.width * fraction))
            }
            .frame(height: 14)
        }
        .padding(DS.Space.sm)
        .background(hot ? palette.accent.color.opacity(0.08) : .clear, in: .rect(cornerRadius: DS.Radius.control))
        .contentShape(Rectangle())
        .onHover { inside in
            let next = inside ? p : (model.hovered == p ? nil : model.hovered)
            if model.hovered != next { model.hovered = next }
        }
        .onTapGesture { if case .folder(let f) = p { model.open(f) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if case .folder(let f) = p { model.open(f) } }
    }
}
