import AppKit
import SwiftUI

// MyMole's design system. Following Apple's HIG for macOS 26: pane title and tools live in the window toolbar, content is
// plain lists and cards, each pane has at most one prominent action, and the
// accent color marks that action and little else. Liquid Glass is left to
// the system controls (toolbar, sidebar) rather than painted onto content.

enum Theme {
    /// The signature teal, sampled from the app icon (#25CDD3).
    static let brand = Color(.sRGB, red: 0.145, green: 0.804, blue: 0.827)

    /// The single brand accent: prominent actions, selection, key gauges.
    /// The signature teal in Dark Mode; a shade deeper in Light Mode so white
    /// button labels and thin marks stay legible on a light background.
    static let accent = Color(
        nsColor: NSColor(name: "MyMoleAccent") { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.145, green: 0.804, blue: 0.827, alpha: 1)
                : NSColor(srgbRed: 0.059, green: 0.659, blue: 0.682, alpha: 1)
        })

    // Aliases into the design tokens (Design/DesignComponents.swift).
    static let pad = DS.Space.page  // content inset from the pane edges
    static let gap = DS.Space.md  // between cards and grid cells
    static let radius = DS.Radius.card

    static func sectionSymbol(_ name: String) -> String {
        switch name {
        case "User essentials": "person.crop.circle"
        case "App caches": "app.badge"
        case "Browsers": "globe"
        case "Cloud & Office": "icloud"
        case "Developer tools", "Development": "hammer"
        case "System", "System caches": "lock.shield"
        case "Trash": "trash"
        case "Application Support": "folder"
        case "App leftovers": "shippingbox"
        case "Virtualization": "server.rack"
        case "Device backups & firmware": "iphone"
        case "Large files": "doc.richtext"
        default: "square.stack.3d.up"
        }
    }

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
    /// Puts the pane's title and subtitle at the leading edge of the window
    /// toolbar and its tools at the trailing edge, the same on every pane.
    func paneToolbar<Tools: ToolbarContent>(
        _ title: String, subtitle: String, @ToolbarContentBuilder tools: () -> Tools
    ) -> some View {
        toolbar {
            ToolbarItem(placement: .navigation) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(subtitle)
                }
                .padding(.horizontal, 6)
            }
            .sharedBackgroundVisibility(.hidden)
            // Pushes the tools to the trailing edge on every pane.
            ToolbarSpacer(.flexible)
            tools()
        }
        .navigationTitle(title)
    }

    func paneToolbar(_ title: String, subtitle: String) -> some View {
        paneToolbar(title, subtitle: subtitle) { ToolbarItem { EmptyView() } }
    }

    /// The pane's one prominent action. Its label is never shortened.
    func primaryAction() -> some View {
        buttonStyle(.borderedProminent).controlSize(.large).fixedSize()
    }

    /// Standard content container: one radius, one fill, one hairline.
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()
    }
}

/// Empty, progress and finished states, built on the system's own
/// `ContentUnavailableView` so they look like the rest of macOS. A nil
/// symbol shows a spinner.
struct CenterCard<Actions: View>: View {
    let symbol: String?
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        ContentUnavailableView {
            if let symbol {
                Label(title, systemImage: symbol)
            } else {
                VStack(spacing: 12) {
                    PulseDot(size: 16)
                    Text(title).font(.title2.bold())
                }
            }
        } description: {
            Text(subtitle).fixedSize(horizontal: false, vertical: true)
        } actions: {
            // Buttons side by side keep their whole labels; the system view
            // would otherwise squeeze them to "Open System S…".
            actions.fixedSize()
        }
    }
}

/// A captioned metric in a card.
struct StatTile<Content: View>: View {
    let caption: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

/// The one big-number style, so every metric reads the same.
struct Metric: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 28, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
    }
}

struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Theme.load(fraction * 100))
                    .frame(width: g.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
    }
}
