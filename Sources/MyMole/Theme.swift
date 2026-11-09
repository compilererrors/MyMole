import AppKit
import SwiftUI

// MyMole's design system. Following Apple's HIG for macOS 26: pane title and tools live in the window toolbar, content is
// plain lists and cards, each pane has at most one prominent action, and the
// accent color marks that action and little else. Liquid Glass is left to
// the system controls (toolbar, sidebar) rather than painted onto content.

enum Theme {
    // The accent and the other colour roles are the theme's: see
    // Design/Palette.swift and `EnvironmentValues.palette`.

    // Aliases into the design tokens (Design/DesignComponents.swift).
    // Computed, so they follow a change of density like the tokens do.
    @MainActor static var pad: CGFloat { DS.Space.page }  // content inset from the pane edges
    @MainActor static var gap: CGFloat { DS.Space.md }  // between cards and grid cells
    static let radius = DS.Radius.card

    /// Green → amber → red as a percentage climbs.
    static func load(_ pct: Double) -> Color {
        pct < 60 ? .green : pct < 85 ? .orange : .red
    }
}

/// The app icon, as macOS loaded it from the bundle — one source for the
/// Dock and the window.
struct AppIconImage: View {
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Pane chrome

extension View {
    /// Puts Back and Forward, then the pane's title and subtitle, at the
    /// leading edge of the window toolbar and its tools at the trailing
    /// edge, the same on every pane.
    func paneToolbar<Tools: ToolbarContent>(
        _ title: LocalizedStringResource, subtitle: LocalizedStringResource, @ToolbarContentBuilder tools: () -> Tools
    ) -> some View {
        toolbar {
            ToolbarItem(placement: .navigation) { PaneHistoryControls() }
            ToolbarItem(placement: .navigation) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(Text(subtitle))
                }
                .padding(.horizontal, 6)
            }
            .sharedBackgroundVisibility(.hidden)
            // Pushes the tools to the trailing edge on every pane.
            ToolbarSpacer(.flexible)
            tools()
        }
        .navigationTitle(Text(title))
    }

    func paneToolbar(_ title: LocalizedStringResource, subtitle: LocalizedStringResource) -> some View {
        paneToolbar(title, subtitle: subtitle) { ToolbarItem { EmptyView() } }
    }

    /// The pane's one prominent action. Its label is never shortened.
    func primaryAction() -> some View {
        buttonStyle(.borderedProminent).controlSize(.large).fixedSize()
    }

    /// Standard content container: one radius, one fill, one hairline;
    /// card padding follows the density unless a tighter one is asked for.
    func card(padding: CGFloat? = nil) -> some View {
        self.padding(padding ?? DS.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()
    }
}

/// Setup and empty states share a readable card with the page's margins.
/// Short windows scroll the complete content, including its actions.
struct CenterCard<Actions: View>: View {
    let symbol: String?
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    @ViewBuilder var actions: Actions
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    Group {
                        if let symbol { Image(systemName: symbol).font(.system(size: 30, weight: .medium)).foregroundStyle(palette.accent.color) }
                        else { PulseDot(size: 16) }
                    }.accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        Text(title).font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(subtitle).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    actions
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: 600, alignment: .leading)
                .dsCard()
                .padding(DS.Space.page)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }
    }
}

/// A captioned metric in a card.
struct StatTile<Content: View>: View {
    let caption: LocalizedStringResource
    /// The tile opens a pane: its caption ends in the arrow the tool tiles have.
    var linked = false
    /// The card's padding, when tighter than a card's own.
    var padding: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.xs) {
                Text(caption)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                if linked {
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            content
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .card(padding: padding)
    }
}

/// The one big-number style, so every metric reads the same.
struct Metric: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DS.MetricRole.tile.font)
            .monospacedDigit()
            .dsNumericTransition()
    }
}

struct UsageBar: View {
    let fraction: Double
    var tint: Color? = nil
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint ?? Theme.load(fraction * 100))
                    .frame(width: g.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
    }
}
