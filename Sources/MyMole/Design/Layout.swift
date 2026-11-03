import SwiftUI

// Every pane has the same skeleton:
//
//   toolbar           pane title + one-line scope; global actions only
//   DSPaneHeader      summary (big number + caption) and pane actions,
//                     then a fixed-height status strip of DSCapsules
//   content           DSPage of DSSections, or a list/table edge to edge
//   DSActionBar       what's selected, and the pane's one primary action
//
// DSNotice is for things that need attention (errors, a tip with an
// action); progress and freshness live in the status strip instead.

/// A scrolling page with the app's margins, its content centred at
/// `DS.Size.pageMaxWidth`.
struct DSPage<Content: View>: View {
    enum Width { case readable, full }

    /// Not read: every page has the same width.
    var width: Width = .full
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                content
            }
            .frame(maxWidth: DS.Size.pageMaxWidth, alignment: .leading)
            .padding(.horizontal, DS.Space.page)
            .padding(.vertical, DS.Space.lg)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A titled group on a card. Its direct children become rows separated by
/// inset hairlines, like a grouped list in System Settings.
struct DSSection<Content: View, Accessory: View>: View {
    var title: String?
    var footer: String?
    /// Rows get the standard padding and dividers; off for free-form content.
    var rows = true
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if title != nil || !(Accessory.self == EmptyView.self) {
                HStack(alignment: .firstTextBaseline) {
                    if let title { DSText(title, .heading) }
                    Spacer(minLength: DS.Space.sm)
                    accessory
                }
                .padding(.horizontal, DS.Space.xs)
            }
            Group {
                if rows {
                    Group(subviews: content) { subviews in
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(subviews) { row in
                                row
                                    .padding(.horizontal, DS.Space.lg)
                                    .padding(.vertical, DS.Space.md)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if row.id != subviews.last?.id {
                                    Divider().padding(.leading, DS.Space.lg)
                                }
                            }
                        }
                    }
                } else {
                    content
                        .padding(DS.Space.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .dsCard()
            if let footer {
                DSText(footer, .metadata).padding(.horizontal, DS.Space.xs)
            }
        }
    }
}

extension DSSection where Accessory == EmptyView {
    init(_ title: String? = nil, footer: String? = nil, rows: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title: title, footer: footer, rows: rows, content: content, accessory: { EmptyView() })
    }
}

extension DSSection {
    init(_ title: String?, footer: String? = nil, rows: Bool = true, @ViewBuilder content: () -> Content,
         @ViewBuilder accessory: () -> Accessory) {
        self.init(title: title, footer: footer, rows: rows, content: content, accessory: accessory)
    }
}

extension View {
    /// The one card surface: a faint fill and a hairline, never heavy.
    func dsCard(radius: CGFloat = DS.Radius.card) -> some View {
        background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

/// Something the page needs to say: progress, a tip, a warning. One look for
/// all of them, so a warning never reads as body text.
struct DSNotice<Actions: View>: View {
    enum Kind { case info, working, success, warning, critical }

    let kind: Kind
    let text: String
    @ViewBuilder var actions: Actions

    init(_ kind: Kind, _ text: String, @ViewBuilder actions: () -> Actions) {
        self.kind = kind
        self.text = text
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.md) {
            Group {
                if kind == .working {
                    PulseDot(tint: tint)
                } else {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
            }
            .frame(width: DS.Size.iconColumn)
            DSText(text, .body)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions.controlSize(.small).fixedSize()
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm + 2)
        .background(tint.opacity(kind == .info ? 0.08 : 0.12), in: .rect(cornerRadius: DS.Radius.control))
    }

    private var tint: Color {
        switch kind {
        case .info: .secondary
        case .working: Theme.accent
        case .success: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    private var symbol: String {
        switch kind {
        case .info: "info.circle.fill"
        case .working: "circle.dotted"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }
}

extension DSNotice where Actions == EmptyView {
    init(_ kind: Kind, _ text: String) {
        self.init(kind, text) { EmptyView() }
    }
}

/// The pane's bottom bar: what's selected on the left, the one primary
/// action on the right.
struct DSActionBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: DS.Space.md) {
            leading
            Spacer(minLength: DS.Space.md)
            trailing
        }
        .padding(.horizontal, DS.Space.page)
        .padding(.vertical, DS.Space.md)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// A row's leading icon, in the fixed icon column.
struct DSIcon: View {
    let symbol: String
    var tint: Color = .secondary
    var large = false

    var body: some View {
        Image(systemName: symbol)
            .font(large ? .title3 : .body)
            .foregroundStyle(tint)
            .frame(width: large ? 28 : DS.Size.iconColumn)
    }
}

/// A count with its label, in its status colour: "4 will make changes".
struct DSCountChip: View {
    let count: Int
    let label: String
    let tint: Color

    init(_ count: Int, _ label: String, _ tint: Color) {
        self.count = count
        self.label = label
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            Text(count.formatted()).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
                .contentTransition(.numericText())
            DSText(label, .lead)
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: DS.Radius.control))
        .keepWhole()
        .animation(.snappy, value: count)
    }
}

/// A section heading over content that brings its own cards (grids of tiles).
struct DSSectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        DSText(title, .heading).padding(.horizontal, DS.Space.xs)
    }
}

// MARK: - Pane header and status strip

/// The top of a pane: its summary and actions, then a status strip of
/// capsules at a fixed height so the content below never jumps. Under it
/// sits anything the user folds open (the output), then the content.
struct DSPaneHeader<Summary: View, Actions: View, Strip: View, Detail: View>: View {
    @ViewBuilder var summary: Summary
    @ViewBuilder var actions: Actions
    @ViewBuilder var strip: Strip
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(alignment: .center, spacing: DS.Space.lg) {
                summary
                Spacer(minLength: DS.Space.md)
                actions
            }
            HStack(spacing: DS.Space.sm) { strip }
                .frame(minHeight: DS.Size.stripHeight, alignment: .leading)
            detail
        }
        .frame(maxWidth: DS.Size.pageMaxWidth, alignment: .leading)
        .padding(.horizontal, DS.Space.page)
        .padding(.top, DS.Space.lg + 2)
        .padding(.bottom, DS.Space.md + 2)
        .frame(maxWidth: .infinity)
    }
}

extension DSPaneHeader where Detail == EmptyView {
    init(@ViewBuilder summary: () -> Summary, @ViewBuilder actions: () -> Actions, @ViewBuilder strip: () -> Strip) {
        self.init(summary: summary, actions: actions, strip: strip, detail: { EmptyView() })
    }
}

/// The big number of a pane and what it counts: "1,24 GB found in 36 items".
struct DSMetric: View {
    let value: String
    let caption: String

    init(_ value: String, _ caption: String) {
        self.value = value
        self.caption = caption
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            DSText(caption, .lead)
        }
        .keepWhole()
    }
}

/// One fact in a status strip: a count, a freshness, a state. Status colour
/// as a faint fill with a matching hairline; a pulse when it's live.
struct DSCapsule: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary
    var live = false

    init(_ text: String, symbol: String? = nil, tint: Color = .secondary, live: Bool = false) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.live = live
    }

    var body: some View {
        HStack(spacing: DS.Space.xs + 2) {
            if live {
                PulseDot(tint: tint == .secondary ? Theme.accent : tint, size: 6)
            } else if let symbol {
                Image(systemName: symbol).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint == .secondary ? Color.secondary : Color.primary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, DS.Space.sm + 2)
        .frame(height: DS.Size.stripHeight)
        .background(tint.opacity(0.11), in: .rect(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).strokeBorder(tint.opacity(0.28), lineWidth: 1))
        .keepWhole()
    }
}

/// A count in a status strip, number first: "5 will make changes".
struct DSCountCapsule: View {
    let count: Int
    let label: String
    var tint: Color = .secondary

    init(_ count: Int, _ label: String, tint: Color = .secondary) {
        self.count = count
        self.label = label
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            Text(count.formatted()).font(.callout.weight(.semibold)).foregroundStyle(tint == .secondary ? Color.primary : tint)
                .monospacedDigit().contentTransition(.numericText())
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Space.sm + 2)
        .frame(height: DS.Size.stripHeight)
        .background(tint.opacity(0.11), in: .rect(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).strokeBorder(tint.opacity(0.28), lineWidth: 1))
        .keepWhole()
        .animation(.snappy, value: count)
    }
}

/// A small text action in a status strip ("Show Output", "Stop").
struct DSStripButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                if let symbol { Image(systemName: symbol).font(.caption2.weight(.semibold)) }
                Text(title).font(.caption.weight(.medium))
            }
            .padding(.horizontal, DS.Space.sm)
            .frame(height: DS.Size.stripHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .fixedSize()
    }
}

/// "Scanning… 0:12" while a job runs: the live capsule with its timer.
struct DSRunningCapsule: View {
    let text: String
    let since: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let secs = since.map { max(0, Int(ctx.date.timeIntervalSince($0))) } ?? 0
            DSCapsule(secs >= 2 ? "\(text) \(Duration.seconds(secs).formatted(.time(pattern: .minuteSecond)))" : text,
                      tint: Theme.accent, live: true)
        }
    }
}

/// "Moved 3 items (1,2 GB) to the Trash · Undo" floating over the bottom of
/// a pane after a move to the Trash.
struct DSUndoToast: View {
    let text: String
    let canUndo: Bool
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: "trash").foregroundStyle(.secondary)
            Text(text)
            if canUndo {
                Button("Undo", action: undo)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: .capsule)
        .shadow(radius: 8, y: 2)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
