import AppKit
import StorageKit
import SwiftUI

// MyMole's design components. Every view builds its text, rows, values and
// badges from these, so spacing, type and — above all — how long names
// behave is decided once:
//
// • Names and paths are never cut in the middle. They wrap, at the natural
//   break points of a file name (`/`, `-`, `_`, `.`, spaces) rather than
//   mid-word, and only text beyond a generous line count ends in "…", with
//   the full text in a tooltip.
// • Values (sizes, counts) and control labels never compress or wrap.

/// How much room the interface gives, chosen in Settings. Compact fits the
/// most on screen; Spacious, the default, gives margins, rows and gaps about
/// a quarter more room, so nothing feels cramped while no column or row of
/// information is given up. Every measure below follows it.
enum Density: String, CaseIterable, Identifiable {
    case compact, spacious

    static let key = "appearance.density"
    static let standard = Density.spacious
    /// Read once at launch and set by Settings before the views are made
    /// again; every measure is a plain lookup, on the main actor only.
    @MainActor static var current = Density(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? standard

    var id: String { rawValue }
    var title: String { self == .compact ? String(localized: "Compact") : String(localized: "Spacious") }

    @MainActor static func pick(_ compact: CGFloat, _ spacious: CGFloat) -> CGFloat {
        current == .compact ? compact : spacious
    }
}

enum DS {
    @MainActor enum Space {
        static var xxs: CGFloat { Density.pick(2, 3) }
        static var xs: CGFloat { Density.pick(4, 5) }
        static var sm: CGFloat { Density.pick(8, 10) }
        static var md: CGFloat { Density.pick(12, 15) }
        static var lg: CGFloat { Density.pick(16, 20) }
        /// Margin between the window edge and content, on every pane.
        static var page: CGFloat { Density.pick(24, 32) }
        static var xl: CGFloat { Density.pick(24, 30) }
        /// Between sections of a page.
        static var section: CGFloat { Density.pick(20, 28) }
    }

    /// Rows of the AppKit tables and outlines, and the gap between their columns.
    @MainActor enum Table {
        static var row: CGFloat { Density.pick(34, 40) }
        static var compactRow: CGFloat { Density.pick(26, 32) }
        static var tallRow: CGFloat { Density.pick(46, 54) }
        static var headerRow: CGFloat { Density.pick(32, 38) }
        static var columnGap: CGFloat { Density.pick(6, 10) }
        /// The gap with the table's lines: wider in a grid, where a line runs down its middle.
        static func columnGap(_ lines: TableLines) -> CGFloat { columnGap + (lines == .grid ? 6 : 0) }
        static var cellInset: CGFloat { Density.pick(2, 6) }
        /// The slot an outline's disclosure arrow is centred in, and the gap after it.
        static let disclosure: CGFloat = 16
        static var disclosureGap: CGFloat { Density.pick(2, 4) }
        /// One level of an outline: a slot and its gap, so a row's arrow sits under its parent's tick box.
        static var indent: CGFloat { disclosure + disclosureGap }
        /// A tick box, or an icon, and the gap to what follows it.
        static var tickStep: CGFloat { Density.pick(22, 24) }
        static let iconStep: CGFloat = 22
        /// Inset rows with rounded selection, as Finder and Mail draw them, when there's room.
        static var style: NSTableView.Style { Density.current == .compact ? .fullWidth : .inset }
    }

    static func mono(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .system(size: size, design: .monospaced)
    }

    static func monoNSFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// The two big-number roles. A tile's number stands alone in a dashboard
    /// card, so it's a little larger; a pane's sits beside its caption in
    /// the pane header.
    enum MetricRole {
        case tile, pane

        var font: Font {
            .system(size: self == .tile ? 28 : 26, weight: .semibold, design: .rounded)
        }
    }

    /// Continuous radii: chips 7,
    /// controls and rows 8, cards and panels 10, sheets 12.
    enum Radius {
        static let chip: CGFloat = 7
        static let control: CGFloat = 8
        static let card: CGFloat = 10
        static let sheet: CGFloat = 12
    }

    @MainActor enum Size {
        static var rowMinHeight: CGFloat { Density.pick(28, 34) }
        static var iconColumn: CGFloat { Density.pick(20, 22) }
        static let inspectorWidth: CGFloat = 320
        /// The narrowest a chart beside a list may get.
        static let chartMinWidth: CGFloat = 280
        /// A draggable divider: wide enough to grab, drawn as a hairline.
        static let splitHandle: CGFloat = 7
        /// Widest a page's content gets; wider windows centre it.
        static let pageMaxWidth: CGFloat = 1200
        static let reviewWidth: CGFloat = 720
        /// Long reviews scroll their body and keep the action footer reachable.
        static let reviewBodyMaxHeight: CGFloat = 640
        /// The status strip under a pane header: fixed, so nothing jumps.
        static var stripHeight: CGFloat { Density.pick(26, 28) }
    }
}

/// What a piece of text is, which fixes its font and color everywhere.
enum TextRole {
    case title, heading, body, lead, metadata, mono

    var font: Font {
        switch self {
        case .title: .title2.weight(.semibold)
        case .heading: .headline
        case .body: .body
        case .lead: .callout
        case .metadata: .caption
        case .mono: DS.mono(11, relativeTo: .caption)
        }
    }

    var style: HierarchicalShapeStyle {
        switch self {
        case .title, .heading, .body, .mono: .primary
        case .lead, .metadata: .secondary
        }
    }
}

enum Breakable {
    /// Inserts invisible break opportunities after file-name separators so
    /// long names wrap between their parts instead of mid-word. A separator
    /// that opens a part (the dot of `.rustup`, `/.cache`) stays with it.
    static func text(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        var previous: Character? = nil
        for ch in s {
            out.append(ch)
            if isSeparator(ch), let previous, !isSeparator(previous) || ch == "/" { out.append("\u{200B}") }
            previous = ch
        }
        return out
    }

    private static func isSeparator(_ ch: Character) -> Bool { ch == "/" || ch == "-" || ch == "_" || ch == "." }

    /// A path for display: home shown as `~`, breakable at every `/`.
    static func path(_ p: String) -> String {
        let home = Home.path
        let short = p == home ? "~" : p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
        return text(short)
    }
}

/// What a component shows: a phrase of the interface, looked up in the
/// string catalog (Localization/Localizable.xcstrings), or a value shown as
/// it is, such as a name, a path, a size or text made elsewhere. A literal
/// handed to a component is a phrase; a `String` value is shown as it is.
///
/// A component's `String` form is generic over `StringProtocol`, as SwiftUI's
/// own text views are: a concrete `LocalizedStringResource` then outranks it
/// for a literal, which `@_disfavoredOverload` alone doesn't manage once a
/// second argument is given, so the phrase reaches the catalog.
struct Phrase {
    private let resource: LocalizedStringResource?
    private let verbatim: String

    init(_ resource: LocalizedStringResource) {
        self.resource = resource
        verbatim = ""
    }

    init(verbatim: String) {
        resource = nil
        self.verbatim = verbatim
    }

    var text: Text { resource.map { Text($0) } ?? Text(verbatim: verbatim) }
    /// As the reader sees it, for tooltips and accessibility.
    var string: String { resource.map { String(localized: $0) } ?? verbatim }
}

/// Plain copy in a text role. Wraps to show everything unless `lines` caps it.
struct DSText: View {
    let text: Phrase
    var role: TextRole = .body
    var lines: Int? = nil

    init(_ text: LocalizedStringResource, _ role: TextRole = .body, lines: Int? = nil) {
        self.init(phrase: Phrase(text), role, lines: lines)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ text: S, _ role: TextRole = .body, lines: Int? = nil) {
        self.init(phrase: Phrase(verbatim: String(text)), role, lines: lines)
    }

    init(phrase: Phrase, _ role: TextRole = .body, lines: Int? = nil) {
        text = phrase
        self.role = role
        self.lines = lines
    }

    var body: some View {
        text.text
            .font(role.font)
            .foregroundStyle(role.style)
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A file, folder or app name. Wraps at name separators up to `lines`
/// lines; anything longer ends in "…" and the full name is in the tooltip.
struct DSName: View {
    let name: String
    var role: TextRole = .body
    var lines = 3
    /// Keeps the height of all `lines` even for a short name, so a grid of
    /// names stays even.
    var reservesSpace = false

    init(_ name: String, _ role: TextRole = .body, lines: Int = 3, reservesSpace: Bool = false) {
        self.name = name
        self.role = role
        self.lines = lines
        self.reservesSpace = reservesSpace
    }

    var body: some View {
        Text(Breakable.text(name))
            .font(role.font)
            .foregroundStyle(role.style)
            .lineLimit(lines, reservesSpace: reservesSpace)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .help(name)
            .accessibilityLabel(name)
    }
}

/// A path, with home as `~`, wrapping at `/`.
struct DSPath: View {
    let path: String
    var role: TextRole = .metadata
    var lines = 3

    init(_ path: String, _ role: TextRole = .metadata, lines: Int = 3) {
        self.path = path
        self.role = role
        self.lines = lines
    }

    var body: some View {
        Text(Breakable.path(path))
            .font(role.font)
            .foregroundStyle(role.style)
            .lineLimit(lines)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .help(path)
            .accessibilityLabel(path)
            .focusable(interactions: .activate)
            .contextMenu { FileMenuItems(paths: [path], canOpen: false) }
    }
}

/// A number that must read whole: sizes, counts, percentages.
struct DSValue: View {
    let text: String
    var role: TextRole = .lead
    var weight: Font.Weight = .regular

    init(_ text: String, _ role: TextRole = .lead, weight: Font.Weight = .regular) {
        self.text = text
        self.role = role
        self.weight = weight
    }

    init(bytes: Int64, _ role: TextRole = .lead, weight: Font.Weight = .regular) {
        self.init(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), role, weight: weight)
    }

    var body: some View {
        Text(text)
            .font(role.font.weight(weight).monospacedDigit())
            .foregroundStyle(role.style)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A small colored capsule label.
struct DSBadge: View {
    let text: Phrase
    let tint: Color

    init(_ text: LocalizedStringResource, tint: Color) {
        self.text = Phrase(text)
        self.tint = tint
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ text: S, tint: Color) {
        self.text = Phrase(verbatim: String(text))
        self.tint = tint
    }

    var body: some View {
        text.text
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: .capsule)
            .lineLimit(1)
            .fixedSize()
    }
}

/// The standard list row: fixed icon column, a title and optional detail
/// that wrap as needed, and a trailing area that never compresses.
struct DSRow<Icon: View, Detail: View, Trailing: View>: View {
    let title: String
    var titleRole: TextRole = .body
    @ViewBuilder var icon: Icon
    @ViewBuilder var detail: Detail
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            icon.frame(width: DS.Size.iconColumn)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                DSName(title, titleRole)
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing.fixedSize()
        }
        .frame(minHeight: DS.Size.rowMinHeight)
        .padding(.vertical, DS.Space.xxs)
        .contentShape(Rectangle())
    }
}

extension DSRow where Detail == EmptyView {
    init(
        title: String, titleRole: TextRole = .body,
        @ViewBuilder icon: () -> Icon, @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(title: title, titleRole: titleRole, icon: icon, detail: { EmptyView() }, trailing: trailing)
    }
}

extension View {
    /// For control labels and short UI words: take natural width, never wrap.
    func keepWhole() -> some View { lineLimit(1).fixedSize() }
}

/// The filter field above a list: magnifying glass, placeholder, and a
/// clear button once there's text. Looks like the system search field.
struct DSFilterField: View {
    @Environment(\.closeDialog) private var closeDialog
    /// Whether a row with these texts (name, folder…) passes `query`: every
    /// word typed appears in one of them, in any case.
    nonisolated static func matches(_ query: String, _ texts: String...) -> Bool {
        TextQuery(query).matches(texts: texts)
    }

    /// "· 3 chosen hidden by the filter", so a choice the filter hides is never a surprise.
    static func hiddenNote(chosen: Set<String>, shown: Set<String>) -> String {
        let hidden = chosen.subtracting(shown).count
        return hidden == 0 ? "" : String(localized: " · \(hidden) hidden by the filter")
    }

    let prompt: String
    @Binding var text: String
    @Environment(\.palette) private var palette
    @Environment(\.findRequest) private var findRequest
    @FocusState private var focused: Bool

    init(_ prompt: String, text: Binding<String>) {
        self.prompt = prompt
        _text = text
    }

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .focused($focused)
                // A dialog closes first; main-pane search clears its query.
                .onExitCommand {
                    if let closeDialog { closeDialog() }
                    else if text.isEmpty { focused = false }
                    else { text = "" }
                }
                .onChange(of: findRequest) { focused = true }
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Clear")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .frame(height: 28)
        .background(palette.field.color, in: .rect(cornerRadius: DS.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(focused ? palette.accentText.color : palette.separator.color, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

/// The notice for a move where nothing reached the Trash, with the first
/// reason, so it never reads as "Moved Zero KB".
func nothingMoved(_ failed: [(path: String, reason: String)]) -> String {
    let count = failed.count == 1 ? "it" : "\(failed.count) items"
    let why = failed.first.map { ": \($0.reason.trimmingCharacters(in: CharacterSet(charactersIn: ".")))" } ?? ""
    return String(localized: "Nothing was moved to the Trash; MyMole couldn't move \(count)\(why).")
}

/// An empty result from a scan that couldn't read everything: nothing was
/// found in what could be read, which isn't the same as nothing being there.
struct DSIncompleteEmpty: View {
    let what: String
    let unreadable: [String]
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No \(what) in What Could Be Read", systemImage: "exclamationmark.triangle")
        } description: {
            Text(Self.explanation(unreadable))
        } actions: {
            Button("Scan Again", action: retry)
        }
    }

    static func explanation(_ unreadable: [String]) -> String {
        let places = unreadable.prefix(3).map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
        let more = unreadable.count > 3 ? String(localized: " and \(unreadable.count - 3) more") : ""
        return String(localized: "MyMole couldn't read \(places)\(more), so this may not be everything. ")
            + String(localized: "Give MyMole Full Disk Access or access to those folders, then scan again.")
    }
}
