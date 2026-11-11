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
    var title: Phrase?
    var footer: Phrase?
    /// Rows get the standard padding and dividers; off for free-form content.
    var rows = true
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory
    var fills = false

    /// The card takes the height it's given, so sections side by side end level.
    func filling() -> DSSection {
        var section = self
        section.fills = true
        return section
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if title != nil || !(Accessory.self == EmptyView.self) {
                HStack(alignment: .firstTextBaseline) {
                    if let title { DSText(phrase: title, .heading) }
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
            .frame(maxHeight: fills ? .infinity : nil, alignment: .top)
            .dsCard()
            if let footer {
                DSText(phrase: footer, .metadata).padding(.horizontal, DS.Space.xs)
            }
        }
    }
}

extension DSSection where Accessory == EmptyView {
    init(_ title: LocalizedStringResource? = nil, footer: LocalizedStringResource? = nil, rows: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.init(title: title.map(Phrase.init), footer: footer.map(Phrase.init), rows: rows, content: content, accessory: { EmptyView() })
    }

    /// A title made elsewhere, shown as it is.
    @_disfavoredOverload
    init(_ title: String, rows: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title: Phrase(verbatim: title), footer: nil, rows: rows, content: content, accessory: { EmptyView() })
    }

    /// A footer made elsewhere, shown as it is.
    @_disfavoredOverload
    init(_ title: LocalizedStringResource? = nil, footer: String?, rows: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title: title.map(Phrase.init), footer: footer.map(Phrase.init(verbatim:)), rows: rows, content: content, accessory: { EmptyView() })
    }
}

extension DSSection {
    init(_ title: LocalizedStringResource?, footer: LocalizedStringResource? = nil, rows: Bool = true,
         @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.init(title: title.map(Phrase.init), footer: footer.map(Phrase.init), rows: rows, content: content, accessory: accessory)
    }

    @_disfavoredOverload
    init(_ title: LocalizedStringResource?, footer: String?, rows: Bool = true,
         @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.init(title: title.map(Phrase.init), footer: footer.map(Phrase.init(verbatim:)), rows: rows, content: content, accessory: accessory)
    }
}

extension View {
    /// The one card surface: a faint fill and a hairline, never heavy.
    func dsCard(radius: CGFloat = DS.Radius.card) -> some View {
        modifier(CardSurface(radius: radius))
    }
}

/// The card surface in the theme's colours: faint over the workspace, or
/// opaque when the user asked macOS to reduce transparency.
struct CardSurface: ViewModifier {
    let radius: CGFloat
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background(
                palette.card.color.opacity(Palette.cardOpacity(reduceTransparency: reduceTransparency)),
                in: .rect(cornerRadius: radius, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(palette.separator.color, lineWidth: 1))
    }
}

/// Something the page needs to say: progress, a tip, a warning. One look for
/// all of them, so a warning never reads as body text.
struct DSNotice<Actions: View>: View {
    @Environment(\.palette) private var palette
    enum Kind { case info, working, success, warning, critical }

    let kind: Kind
    let text: Phrase
    @ViewBuilder var actions: Actions

    init(_ kind: Kind, _ text: LocalizedStringResource, @ViewBuilder actions: () -> Actions) {
        self.init(kind, phrase: Phrase(text), actions: actions)
    }

    @_disfavoredOverload
    init(_ kind: Kind, _ text: String, @ViewBuilder actions: () -> Actions) {
        self.init(kind, phrase: Phrase(verbatim: text), actions: actions)
    }

    init(_ kind: Kind, phrase text: Phrase, @ViewBuilder actions: () -> Actions) {
        self.kind = kind
        self.text = text
        self.actions = actions()
    }

    var body: some View {
        DSActionGroup {
            HStack(alignment: .center, spacing: DS.Space.md) {
                Group {
                    if kind == .working {
                        PulseDot(tint: tint)
                    } else {
                        Image(systemName: symbol).foregroundStyle(tint)
                    }
                }
                .frame(width: DS.Size.iconColumn)
                DSText(phrase: text, .body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } trailing: {
            actions.controlSize(.small)
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm + 2)
        .background(tint.opacity(kind == .info ? 0.08 : 0.12), in: .rect(cornerRadius: DS.Radius.control))
    }

    private var tint: Color {
        switch kind {
        case .info: .secondary
        case .working: palette.accentText.color
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
    init(_ kind: Kind, _ text: LocalizedStringResource) {
        self.init(kind, phrase: Phrase(text)) { EmptyView() }
    }

    @_disfavoredOverload
    init(_ kind: Kind, _ text: String) {
        self.init(kind, phrase: Phrase(verbatim: text)) { EmptyView() }
    }
}

/// Keeps an action's explanation with its buttons, including in narrow sheets.
struct DSActionGroup<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.md) {
                leading
                Spacer(minLength: DS.Space.md)
                HStack(spacing: DS.Space.sm) { trailing }.fixedSize()
            }
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                leading
                DSFlow(spacing: DS.Space.sm, alignsToTrailing: true) { trailing }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

/// The pane's bottom bar: choice summary and the primary action.
struct DSActionBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        DSActionGroup {
            leading
        } trailing: {
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
                .dsNumericTransition()
            DSText(label, .lead)
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: DS.Radius.control))
        .keepWhole()
        .animation(Motion.snappy, value: count)
    }
}

/// A section heading over content that brings its own cards (grids of tiles).
struct DSSectionHeader: View {
    let title: Phrase

    init(_ title: LocalizedStringResource) { self.title = Phrase(title) }
    @_disfavoredOverload
    init(_ title: String) { self.title = Phrase(verbatim: title) }

    var body: some View {
        DSText(phrase: title, .heading).padding(.horizontal, DS.Space.xs)
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
    var controlsTitle: LocalizedStringResource?
    var controlsDetail: LocalizedStringResource?

    func contextualControls(_ title: LocalizedStringResource, detail: LocalizedStringResource) -> Self {
        var header = self
        header.controlsTitle = title
        header.controlsDetail = detail
        return header
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            if controlsTitle != nil {
                summary
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: DS.Space.lg) {
                        summary
                        Spacer(minLength: DS.Space.md)
                        actions
                    }
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        summary
                        actions
                    }
                }
            }
            // One line as long as the facts fit; a narrow window wraps them
            // instead of cutting any off.
            DSFlow(spacing: DS.Space.md) { strip }
                .frame(minHeight: DS.Size.stripHeight, alignment: .leading)
            if let controlsTitle, let controlsDetail {
                DSControlBar(controlsTitle, detail: controlsDetail) { actions }
            }
            detail
        }
        .frame(maxWidth: controlsTitle == nil ? DS.Size.pageMaxWidth : .infinity, alignment: .leading)
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

/// Tiles in rows that always fill the width. As many go on a row as fit at
/// `minimum`, and the tiles are spread over the rows as evenly as can be:
/// seven where four fit are four and three, never four, two and a gap. The
/// tiles of a row share its width, and every tile has the same height.
struct DSTiles: Layout {
    var minimum: CGFloat
    var spacing: CGFloat

    /// How many tiles each row takes.
    static func rows(count: Int, width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> [Int] {
        guard count > 0 else { return [] }
        let fit = min(count, max(1, Int((width + spacing) / (minimum + spacing))))
        let rows = (count + fit - 1) / fit
        return (0..<rows).map { count / rows + ($0 < count % rows ? 1 : 0) }
    }

    private func tileWidth(_ tiles: Int, in width: CGFloat) -> CGFloat {
        max(0, (width - spacing * CGFloat(tiles - 1)) / CGFloat(tiles))
    }

    /// The tallest tile at the width its row gives it.
    private func tileHeight(_ subviews: Subviews, rows: [Int], width: CGFloat) -> CGFloat {
        var first = 0
        var tallest: CGFloat = 0
        for tiles in rows {
            let proposal = ProposedViewSize(width: tileWidth(tiles, in: width), height: nil)
            for tile in subviews[first..<first + tiles] { tallest = max(tallest, tile.sizeThatFits(proposal).height) }
            first += tiles
        }
        return tallest
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count = CGFloat(subviews.count)
        // Without a width to fill, all on one row at their minimum.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? count * minimum + spacing * max(0, count - 1)
        let rows = Self.rows(count: subviews.count, width: width, minimum: minimum, spacing: spacing)
        let height = tileHeight(subviews, rows: rows, width: width)
        return CGSize(width: width, height: height * CGFloat(rows.count) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = Self.rows(count: subviews.count, width: bounds.width, minimum: minimum, spacing: spacing)
        let height = tileHeight(subviews, rows: rows, width: bounds.width)
        var first = 0
        var y = bounds.minY
        for tiles in rows {
            let width = tileWidth(tiles, in: bounds.width)
            for (i, tile) in subviews[first..<first + tiles].enumerated() {
                tile.place(at: CGPoint(x: bounds.minX + CGFloat(i) * (width + spacing), y: y), proposal: ProposedViewSize(width: width, height: height))
            }
            first += tiles
            y += height + spacing
        }
    }
}

/// A card that goes somewhere: the whole card is the button. Under the
/// pointer its outline takes the accent, and it dims while pressed.
struct DSTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Tile(configuration: configuration) }

    private struct Tile: View {
        let configuration: Configuration
        @Environment(\.palette) private var palette
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            configuration.label
                .contentShape(shape)
                .overlay(shape.strokeBorder(palette.accentText.color.opacity(hovered ? 0.6 : 0), lineWidth: 1))
                .opacity(configuration.isPressed ? 0.75 : 1)
                .onHover { hovered = $0 }
        }
    }
}

/// Lays its children out in rows, left to right, starting a new row when
/// the next one doesn't fit. Each child keeps its own size.
struct DSFlow: Layout {
    var spacing: CGFloat
    var alignsToTop = false
    var alignsToTrailing = false

    private func sizes(_ subviews: Subviews, width: CGFloat?) -> [CGSize] {
        subviews.map { view in
            let ideal = view.sizeThatFits(.unspecified)
            guard let width, width.isFinite, ideal.width > width else { return ideal }
            return view.sizeThatFits(.init(width: max(0, width), height: nil))
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = Self.rows(sizes(subviews, width: proposal.width), width: proposal.width ?? .infinity, spacing: spacing)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(subviews, width: bounds.width)
        var y = bounds.minY
        for row in Self.rows(sizes, width: bounds.width, spacing: spacing) {
            var x = alignsToTrailing ? bounds.maxX - row.width : bounds.minX
            for i in row.items {
                subviews[i].place(
                    at: CGPoint(x: x, y: y + (alignsToTop ? 0 : (row.height - sizes[i].height) / 2)),
                    proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + spacing
            }
            y += row.height + spacing
        }
    }

    struct Row: Equatable {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Which children go on which row: as many as fit in `width`, and at
    /// least one per row, so a child wider than the row still shows.
    static func rows(_ sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, size) in sizes.enumerated() where size.width > 0 || size.height > 0 {
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// The big number of a pane and what it counts: "1,24 GB found in 36 items".
struct DSMetric: View {
    let value: String
    let caption: Phrase

    init(_ value: String, _ caption: LocalizedStringResource) {
        self.value = value
        self.caption = Phrase(caption)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ value: String, _ caption: S) {
        self.value = value
        self.caption = Phrase(verbatim: String(caption))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Text(value)
                .font(DS.MetricRole.pane.font)
                .monospacedDigit()
                .dsNumericTransition()
            DSText(phrase: caption, .lead)
        }
        .keepWhole()
    }
}

/// One fact in a status strip: a count, a freshness, a state. Status colour
/// as a faint fill with a matching hairline; a pulse when it's live.
struct DSCapsule: View {
    let text: Phrase
    var symbol: String?
    var tint: Color = .secondary
    var live = false
    /// Shown after the phrase as it is, such as a running time.
    var suffix: String?

    init(_ text: LocalizedStringResource, symbol: String? = nil, tint: Color = .secondary, live: Bool = false) {
        self.init(phrase: Phrase(text), symbol: symbol, tint: tint, live: live)
    }

    @_disfavoredOverload
    init(_ text: String, symbol: String? = nil, tint: Color = .secondary, live: Bool = false) {
        self.init(phrase: Phrase(verbatim: text), symbol: symbol, tint: tint, live: live)
    }

    init(phrase text: Phrase, symbol: String? = nil, tint: Color = .secondary, live: Bool = false, suffix: String? = nil) {
        self.text = text
        self.suffix = suffix
        self.symbol = symbol
        self.tint = tint
        self.live = live
    }

    var body: some View {
        HStack(spacing: DS.Space.xs + 2) {
            if live {
                PulseDot(tint: tint == .secondary ? nil : tint, size: 6)
            } else if let symbol {
                Image(systemName: symbol).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            }
            (suffix.map { Text("\(text.text) \($0)") } ?? text.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint == .secondary ? Color.secondary : Color.primary)
                .monospacedDigit()
                .dsNumericTransition()
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
    let label: Phrase
    var tint: Color = .secondary

    init(_ count: Int, _ label: LocalizedStringResource, tint: Color = .secondary) {
        self.count = count
        self.label = Phrase(label)
        self.tint = tint
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ count: Int, _ label: S, tint: Color = .secondary) {
        self.count = count
        self.label = Phrase(verbatim: String(label))
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            Text(count.formatted()).font(.callout.weight(.semibold)).foregroundStyle(tint == .secondary ? Color.primary : tint)
                .monospacedDigit().dsNumericTransition()
            label.text.font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Space.sm + 2)
        .frame(height: DS.Size.stripHeight)
        .background(tint.opacity(0.11), in: .rect(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).strokeBorder(tint.opacity(0.28), lineWidth: 1))
        .keepWhole()
        .animation(Motion.snappy, value: count)
    }
}

/// A small text action in a status strip ("Show Output", "Stop").
struct DSStripButton: View {
    @Environment(\.palette) private var palette
    let title: Phrase
    var symbol: String?
    let action: () -> Void

    init(_ title: LocalizedStringResource, symbol: String? = nil, action: @escaping () -> Void) {
        self.init(phrase: Phrase(title), symbol: symbol, action: action)
    }

    @_disfavoredOverload
    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.init(phrase: Phrase(verbatim: title), symbol: symbol, action: action)
    }

    init(phrase title: Phrase, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                if let symbol { Image(systemName: symbol).font(.caption2.weight(.semibold)) }
                title.text.font(.caption.weight(.medium))
            }
            .padding(.horizontal, DS.Space.sm)
            .frame(height: DS.Size.stripHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.accentText.color)
        .fixedSize()
    }
}

/// "Scanning… 0:12" while a job runs: the live capsule with its timer.
struct DSRunningCapsule: View {
    @Environment(\.palette) private var palette
    let text: Phrase
    let since: Date?

    init(text: LocalizedStringResource, since: Date?) {
        self.text = Phrase(text)
        self.since = since
    }

    @_disfavoredOverload
    init<S: StringProtocol>(text: S, since: Date?) {
        self.text = Phrase(verbatim: String(text))
        self.since = since
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let secs = since.map { max(0, Int(ctx.date.timeIntervalSince($0))) } ?? 0
            DSCapsule(phrase: text, tint: palette.accentText.color, live: true,
                      suffix: secs >= 2 ? Duration.seconds(secs).formatted(.time(pattern: .minuteSecond)) : nil)
        }
    }
}

/// How far a scan has come, beside its running capsule: a bar and the
/// percentage. Nil while the amount isn't known yet.
struct DSScanProgress: View {
    let fraction: Double?

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            PulseBar(value: fraction)
                .frame(width: 120)
            if let fraction {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 32, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Digits that roll as a number changes, unless the user asked macOS to
/// reduce motion.
struct NumericTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.contentTransition(reduceMotion ? .identity : .numericText())
    }
}

extension View {
    func dsNumericTransition() -> some View { modifier(NumericTransition()) }

    /// The outgoing drawing stays in the same bounds while its prepared
    /// replacement fades in. Callers change identity with the prepared data.
    func dsCrossfade<ID: Hashable>(value: ID) -> some View {
        ZStack { self.id(value).transition(.opacity) }
    }

    /// Keep the native table and its viewport in place while its empty state
    /// fades in. Only the overlay animates, never the table's rows or sorting.
    func dsEmptyOverlay<Empty: View>(showing: Bool, @ViewBuilder content: () -> Empty) -> some View {
        overlay {
            ZStack {
                if showing { content().transition(.opacity) }
            }
            .animation(Motion.content, value: showing)
        }
    }

    /// The bottom of a working pane: the action bar while something is
    /// chosen, inset so it never covers the list, and the feedback toast
    /// floating a fixed gap above whatever is at the bottom, measured rather
    /// than assumed, whatever the bar's height or the density.
    func dsBottom<Bar: View, Toast: View>(
        showing bar: Bool, @ViewBuilder bar content: () -> Bar, @ViewBuilder toast: () -> Toast
    ) -> some View {
        modifier(BottomFeedback(toast: toast()))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if bar { content().transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .animation(Motion.content, value: bar)
    }
}

private struct BottomFeedback<Toast: View>: ViewModifier {
    let toast: Toast
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, height > 0 ? height + DS.Space.lg * 2 : 0)
            .overlay(alignment: .bottom) {
                ZStack { toast }
                    .padding(.horizontal, DS.Space.lg)
                    .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { next in
                        withAnimation(Motion.content) { height = next }
                    }
                    .padding(.bottom, DS.Space.lg)
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
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: .capsule)
        .shadow(radius: 8, y: 2)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
