import SwiftUI

struct StatusLayoutEditor: View {
    @Binding var layout: StatusLayout
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSText("Customize Live Status", .title)
            DSText(
                "Choose visible cards and their size. Drag rows or use the arrows to change order. Your layout is saved on this Mac.",
                .metadata)
            DSText("You can also use Edit Layout on the page. Row heights stay aligned, and hidden cards remain available from the hidden-cards menu.", .metadata)
            List {
                ForEach(layout.cards) { card in
                    HStack(spacing: DS.Space.md) {
                        Toggle(isOn: Binding(get: { card.visible }, set: { layout.setVisible($0, for: card.id) })) {
                            Label(card.id.title, systemImage: card.id.symbol)
                        }
                        .toggleStyle(.checkbox)
                        Spacer(minLength: DS.Space.sm)
                        Picker("Size", selection: Binding(get: { card.size }, set: { layout.setSize($0, for: card.id) })) {
                            ForEach(StatusCardSize.allCases) { Text($0.title).tag($0) }
                        }
                        .fixedSize()
                        .accessibilityLabel("Size for \(card.id.title)")
                        Button {
                            layout.move(card.id, by: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .disabled(layout.cards.first?.id == card.id)
                        .accessibilityLabel("Move \(card.id.title) earlier")
                        Button {
                            layout.move(card.id, by: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .disabled(layout.cards.last?.id == card.id)
                        .accessibilityLabel("Move \(card.id.title) later")
                    }
                    .padding(.vertical, DS.Space.xs)
                }
                .onMove { layout.move(from: $0, to: $1) }
            }
            .frame(height: 380)
            DSActionGroup {
                DSFlow(spacing: DS.Space.sm) {
                    Button("Show All Cards") { layout.showAll() }.disabled(layout.hidden.isEmpty)
                    Button("Restore Default Layout") { layout = StatusLayout() }
                }
            } trailing: {
                Button("Done") { dismiss() }.primaryAction().keyboardShortcut(.cancelAction)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.reviewWidth)
        .dialogKeyboard()
    }
}
