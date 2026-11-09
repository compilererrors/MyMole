import SwiftUI

/// A list's controls have a visible purpose and scope. Field labels stay
/// visible after the user has typed or picked a value.
struct DSControlBar<Content: View>: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringResource, detail: LocalizedStringResource, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(.system(size: 12, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DSControlGrid(spacing: DS.Space.lg) { content }
                .controlSize(.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .accessibilityElement(children: .contain)
    }
}

struct DSControlField<Content: View>: View {
    let title: LocalizedStringResource
    var inline = false
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringResource, inline: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.inline = inline
        self.content = content()
    }

    var body: some View {
        Group {
            if inline {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Space.sm) {
                        label.frame(width: 72, alignment: .leading)
                        content.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        label
                        content.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    label
                    content.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    private var label: some View {
        Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Noninteractive facts stay quieter than actions and warnings.
struct DSStatusFact: View {
    let text: LocalizedStringResource
    let symbol: String

    init(_ text: LocalizedStringResource, symbol: String) {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, DS.Space.xs)
    }
}

/// Names each side of a master/detail list before its column headings.
struct DSListHeading: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    init(_ title: LocalizedStringResource, detail: LocalizedStringResource) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .background(.bar)
    }
}
