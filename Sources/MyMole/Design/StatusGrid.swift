import SwiftUI

/// Geometry depends on preferences and width, never on live text or readings.
enum StatusGrid {
    nonisolated static func columnCount(width: CGFloat, spacing: CGFloat) -> Int {
        let width = width.isFinite ? max(1, width) : 900
        return max(1, min(3, Int((width + spacing) / (280 + spacing))))
    }

    nonisolated static func frames(cards: [StatusLayout.Card], width: CGFloat, spacing: CGFloat, compactDensity: Bool = false, editing: Bool = false) -> [CGRect] {
        let width = width.isFinite ? max(1, width) : 900
        let columns = columnCount(width: width, spacing: spacing)
        var frames = [CGRect](repeating: .zero, count: cards.count)
        var row: [Int] = []
        var units = 0
        var y: CGFloat = 0
        func finishRow() {
            guard !row.isEmpty else { return }
            let preferredHeight = row.map { cards[$0].height(compactDensity: compactDensity) }.max() ?? 0
            let height = preferredHeight + (editing ? 40 : 0)
            let available = max(1, width - CGFloat(units - 1) * spacing)
            let unit = available / CGFloat(units)
            var x: CGFloat = 0
            for index in row {
                let span = min(columns, cards[index].size.span)
                let cardWidth = unit * CGFloat(span) + CGFloat(span - 1) * spacing
                frames[index] = CGRect(x: x, y: y, width: cardWidth, height: height)
                x += cardWidth + spacing
            }
            y += height + spacing
            row = []; units = 0
        }
        for index in cards.indices {
            let span = min(columns, cards[index].size.span)
            if units + span > columns { finishRow() }
            row.append(index)
            units += span
            if units == columns { finishRow() }
        }
        finishRow()
        return frames
    }

}

/// The scrollable height and each card's frame use the same measured width.
/// Native frame/position modifiers keep drawing and hit testing in agreement.
struct StatusGridView<Content: View>: View {
    let cards: [StatusLayout.Card]
    var compactDensity = false
    var editing = false
    let spacing: CGFloat
    @ViewBuilder var content: (StatusLayout.Card) -> Content
    @State private var width: CGFloat = 900

    var body: some View {
        let measured = StatusGrid.frames(cards: cards, width: width, spacing: spacing,
                                         compactDensity: compactDensity, editing: editing)
        GeometryReader { geometry in
            let frames = StatusGrid.frames(cards: cards, width: geometry.size.width, spacing: spacing,
                                           compactDensity: compactDensity, editing: editing)
            ZStack(alignment: .topLeading) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    content(card)
                        .frame(width: frames[index].width, height: frames[index].height, alignment: .topLeading)
                        .contentShape(.rect)
                        .position(x: frames[index].midX, y: frames[index].midY)
                }
            }
            .frame(width: geometry.size.width, height: frames.map(\.maxY).max() ?? 0, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max(1, $0) }
        }
        .frame(height: measured.map(\.maxY).max() ?? 0)
    }
}

struct StatusCard<Content: View, Actions: View>: View {
    let card: StatusCardID
    var editing = false
    var size: StatusCardSize = .standard
    var canResize = true
    var drag: StatusCardDrag? = nil
    var onResize: (StatusCardSize) -> Void = { _ in }
    var onMove: (Int) -> Void = { _ in }
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @State private var proposedSize: StatusCardSize?
    private enum Handle: Hashable { case move }
    @FocusState private var focusedHandle: Handle?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                if editing, let drag {
                    Image(systemName: "line.3.horizontal")
                        .frame(width: 22, height: 24)
                        .contentShape(Rectangle())
                        .draggable(drag) {
                            Label(card.title, systemImage: card.symbol).padding(DS.Space.md).dsCard()
                        }
                        .accessibilityLabel("Move \(card.title)")
                        .accessibilityIdentifier("status.move." + card.rawValue)
                        .accessibilityAdjustableAction { direction in onMove(direction == .increment ? 1 : -1) }
                        .focusable()
                        .focused($focusedHandle, equals: .move)
                        .onTapGesture { focusedHandle = .move }
                        .onKeyPress(keys: [.upArrow, .downArrow]) { key in
                            guard key.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
                            onMove(key.key == .upArrow ? -1 : 1)
                            return .handled
                        }
                        .help("Drag to reorder \(card.title). The Actions menu also offers Move Earlier and Move Later.")
                }
                Label(card.title, systemImage: card.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: DS.Space.sm)
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
                .accessibilityLabel("Actions for \(card.title)")
                .help("Actions and layout for \(card.title)")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xs) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            if editing {
                HStack {
                    Text(proposedSize?.title ?? size.title).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    HorizontalDragHandle(label: String(localized: "Resize \(card.title)"),
                                         identifier: "status.resize." + card.rawValue, value: size.title,
                                         enabled: canResize, onChange: { translation in
                        proposedSize = abs(translation.width) < 40 ? size : translation.width > 0 ? .wide : .standard
                    }, onEnd: { translation in
                        let next: StatusCardSize = abs(translation.width) < 40 ? size : translation.width > 0 ? .wide : .standard
                        if next != size { onResize(next) }
                        proposedSize = nil
                    }, onPress: {
                        proposedSize = nil
                        toggleWidth()
                    }, onCancel: { proposedSize = nil }, onAdjust: { direction in
                        onResize(direction > 0 ? .wide : .standard)
                    })
                        .frame(width: 26, height: 22)
                        .opacity(canResize ? 1 : 0.4)
                        .help(canResize ? String(localized: "Drag sideways to resize, or click to toggle width. Cards in a row share a height.")
                              : String(localized: "Widen the window to change card width."))
                }
            }
        }
        .padding(DS.Space.md)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .dsCard()
        .overlay {
            if proposedSize != nil {
                RoundedRectangle(cornerRadius: DS.Radius.card).stroke(.tint, lineWidth: 2)
            }
        }
        .clipped()
        .contextMenu { actions }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("status.card." + card.rawValue)
    }

    private func toggleWidth() {
        if canResize { onResize(size == .wide ? .standard : .wide) }
    }
}
