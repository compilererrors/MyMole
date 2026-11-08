import AppKit
import SwiftUI

// The colour roles every view draws with, in a few theme families. A role
// resolves to an NSColor for light, dark and increased contrast, so the same
// role serves SwiftUI views, AppKit tables and the disk map's charts. Text
// and status colours stay the system's in every family: they carry meaning
// and macOS's own contrast, which a theme mustn't weaken.

/// Light, Dark, or whatever the system uses.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance.mode"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    /// For `preferredColorScheme`: nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// The same as an AppKit appearance: nil follows the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum ThemeFamily: String, CaseIterable, Identifiable {
    case native, graphiteBlue, fjord, paper

    static let key = "appearance.theme"
    static let standard = ThemeFamily.native
    var id: String { rawValue }
    var title: String {
        switch self {
        case .native: String(localized: "Native")
        case .graphiteBlue: String(localized: "Graphite Blue")
        case .fjord: String(localized: "Fjord")
        case .paper: String(localized: "Paper")
        }
    }

    var palette: Palette {
        switch self {
        case .native: .native
        case .graphiteBlue: .graphiteBlue
        case .fjord: .fjord
        case .paper: .paper
        }
    }
}

/// One colour role: its colour in light and dark, each also with
/// increased contrast, resolved by AppKit as it draws.
struct Role {
    enum Variant: CaseIterable { case light, dark, highLight, highDark
        var isDark: Bool { self == .dark || self == .highDark }
        var isHigh: Bool { self == .highLight || self == .highDark }
    }

    private let variants: [Variant: NSColor]
    /// For AppKit: follows the appearance it's drawn in.
    let ns: NSColor

    /// A role of fixed colours; the increased-contrast ones default to the plain ones.
    init(_ light: String, _ dark: String, highLight: String? = nil, highDark: String? = nil) {
        let (l, d) = (NSColor(hex: light), NSColor(hex: dark))
        let v: [Variant: NSColor] = [
            .light: l, .dark: d, .highLight: highLight.map(NSColor.init(hex:)) ?? l, .highDark: highDark.map(NSColor.init(hex:)) ?? d,
        ]
        variants = v
        ns = NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: v[.dark]!
            case .accessibilityHighContrastAqua: v[.highLight]!
            case .accessibilityHighContrastDarkAqua: v[.highDark]!
            default: v[.light]!
            }
        }
    }

    /// One of the system's own colours, which adapts by itself.
    init(system: NSColor) {
        ns = system
        func resolved(_ name: NSAppearance.Name) -> NSColor {
            var c = system
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance { c = system.usingColorSpace(.sRGB) ?? system }
            return c
        }
        let (l, d) = (resolved(.aqua), resolved(.darkAqua))
        variants = [.light: l, .dark: d, .highLight: l, .highDark: d]
    }

    var color: Color { Color(nsColor: ns) }

    /// The colour in one appearance, as a fixed sRGB colour.
    func resolved(_ variant: Variant) -> NSColor { variants[variant]! }
}

/// The roles. `accent` fills prominent buttons and selection, with white
/// labels on it; `accentText` is the accent for text and thin marks on the
/// workspace and cards. Each meets its contrast in every appearance (see
/// PaletteTests).
struct Palette {
    let family: ThemeFamily
    let workspace: Role
    let card: Role
    let separator: Role
    let field: Role
    let accent: Role
    let accentText: Role

    // The same in every family: they carry meaning and macOS's own contrast.
    var text: Role { Role(system: .labelColor) }
    var secondaryText: Role { Role(system: .secondaryLabelColor) }
    var focus: Role { Role(system: .keyboardFocusIndicatorColor) }
    var success: Color { .green }
    var warning: Color { .orange }
    var critical: Color { .red }
    /// A selected row: the accent, faint enough for the row's text to stay legible.
    var selection: Color { accent.color.opacity(0.18) }

    /// How opaque a card is over the workspace: faint, unless the user
    /// asked macOS to reduce transparency.
    static func cardOpacity(reduceTransparency: Bool) -> Double { reduceTransparency ? 1 : 0.72 }
}

extension Palette {
    /// The system's own surfaces, with MyMole's teal: deep enough for white
    /// labels on it, and the bright signature teal for text on dark surfaces.
    static let native = Palette(
        family: .native, workspace: Role(system: .windowBackgroundColor), card: Role(system: .controlBackgroundColor),
        separator: Role(system: .separatorColor), field: Role(system: .textBackgroundColor),
        accent: Role("#147073", "#177D81", highLight: "#105A5D"),
        accentText: Role("#136C6F", "#23C0C5", highLight: "#105659", highDark: "#50DBE0"))

    /// Cool greys with a steel blue.
    static let graphiteBlue = Palette(
        family: .graphiteBlue,
        workspace: Role("#F2F4F7", "#1B1E23", highLight: "#FFFFFF", highDark: "#000000"),
        card: Role("#FFFFFF", "#252A31"), separator: Role("#D5DAE1", "#3A414B", highLight: "#8A929E", highDark: "#8A929E"),
        field: Role("#FFFFFF", "#1F242A"),
        accent: Role("#3867A0", "#3E73B3", highLight: "#2D5280"),
        accentText: Role("#36639A", "#90B0D8", highLight: "#2B4F7B", highDark: "#B5CBE5"))

    /// Sea-water surfaces with a green teal.
    static let fjord = Palette(
        family: .fjord,
        workspace: Role("#EDF4F4", "#142221", highLight: "#FFFFFF", highDark: "#000000"),
        card: Role("#F9FCFC", "#1C2E2D"), separator: Role("#C9DCDC", "#2C4544", highLight: "#7F9998", highDark: "#7F9998"),
        field: Role("#FFFFFF", "#182827"),
        accent: Role("#21706E", "#257D7B", highLight: "#1A5A59"),
        accentText: Role("#206C6A", "#38BFBD", highLight: "#195655", highDark: "#7AD8D6"))

    /// Warm paper with ink blue.
    static let paper = Palette(
        family: .paper,
        workspace: Role("#F7F3EA", "#1F1D19", highLight: "#FFFFFF", highDark: "#000000"),
        card: Role("#FFFDF7", "#2A2722"), separator: Role("#E0D8C6", "#3D3930", highLight: "#958C78", highDark: "#958C78"),
        field: Role("#FFFEFA", "#24221E"),
        accent: Role("#3F679A", "#4673AD", highLight: "#32527C"),
        accentText: Role("#3C6395", "#94B0D4", highLight: "#304F76", highDark: "#B8CAE2"))
}

extension NSColor {
    /// "#RRGGBB" in sRGB.
    convenience init(hex: String) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.native
}

extension EnvironmentValues {
    /// The theme family's colours, set once at the root; changing it redraws
    /// the views that use it without making them, or their scans, again.
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

