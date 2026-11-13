import SwiftUI

/// Contextual help works with a pointer, keyboard and VoiceOver.
struct DSInfoButton: View {
    let title: String
    let detail: String
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(String(localized: "About \(title)"))
        .help(detail)
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(title).font(.headline)
                Text(detail).fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.lg)
            .frame(width: 340, alignment: .leading)
        }
    }
}
