import AppKit
import Testing

@testable import MyMole

/// Contrast as WCAG 2 computes it, of colours resolved the way AppKit draws
/// them in each appearance, with translucent colours laid over what's under them.
@MainActor
@Suite struct PaletteTests {
    typealias RGB = (r: Double, g: Double, b: Double)

    func rgb(_ role: Role, _ v: Role.Variant, over base: RGB = (1, 1, 1), opacity: Double = 1) -> RGB {
        let c = role.resolved(v).usingColorSpace(.sRGB)!
        let a = Double(c.alphaComponent) * opacity
        return (Double(c.redComponent) * a + base.r * (1 - a), Double(c.greenComponent) * a + base.g * (1 - a),
                Double(c.blueComponent) * a + base.b * (1 - a))
    }

    func luminance(_ c: RGB) -> Double {
        func ch(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
    }

    func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func check(_ value: Double, _ least: Double, _ what: String) {
        #expect(value >= least, "\(what): \((value * 100).rounded() / 100) < \(least)")
    }

    @Test(arguments: ThemeFamily.allCases)
    func everyRoleIsLegibleInEveryAppearance(_ family: ThemeFamily) {
        let p = family.palette
        let white: RGB = (1, 1, 1)
        for v in Role.Variant.allCases {
            let what = "\(family) \(v)"
            let workspace = rgb(p.workspace, v)
            let accentText = rgb(p.accentText, v)
            // A card is laid over the workspace, faint or, with reduced transparency, opaque.
            for reduce in [false, true] {
                let card = rgb(p.card, v, over: workspace, opacity: Palette.cardOpacity(reduceTransparency: reduce))
                check(contrast(accentText, card), v.isHigh ? 7 : 4.5, "\(what) accent text on a card")
                check(contrast(rgb(p.text, v, over: card), card), 7, "\(what) text on a card")
            }
            check(contrast(white, rgb(p.accent, v)), v == .highLight ? 7 : 4.5, "\(what) white label on the accent")
            check(contrast(rgb(p.accent, v), workspace), 3, "\(what) accent fill on the workspace")
            check(contrast(accentText, workspace), v.isHigh ? 7 : 4.5, "\(what) accent text")
            check(contrast(rgb(p.text, v, over: workspace), workspace), 7, "\(what) text")
            check(contrast(rgb(p.secondaryText, v, over: workspace), workspace), 3.5, "\(what) secondary text")
        }
    }

    @Test func eachFamilyIsItsOwnAndNativeKeepsTheSystemSurfaces() {
        #expect(Set(ThemeFamily.allCases.map(\.palette.family)) == Set(ThemeFamily.allCases))
        #expect(Palette.native.workspace.ns == .windowBackgroundColor && Palette.native.card.ns == .controlBackgroundColor)
        #expect(AppearanceMode.system.nsAppearance == nil && AppearanceMode.dark.nsAppearance?.name == .darkAqua)
    }

    @Test func chartLabelsReachTheirContrastOnEveryFill() {
        for step in 0...100 {
            let l = Double(step) / 100
            let (dark, title, detail) = ChartLabel.ink(on: l)
            let ink = dark ? 0.0 : 1.0
            func shown(_ opacity: Double) -> Double { ink * opacity + l * (1 - opacity) }
            let best = max((l + 0.05) / 0.05, 1.05 / (l + 0.05))
            // Softened only while that still reads at 4.5:1; otherwise as strong as black or white gets.
            for opacity in [title, detail] {
                let c = (max(shown(opacity), l) + 0.05) / (min(shown(opacity), l) + 0.05)
                #expect(c >= min(4.5, best) - 0.001, "fill \(l) opacity \(opacity): \(c)")
            }
        }
        #expect(ChartLabel.ink(on: 0.9).dark && !ChartLabel.ink(on: 0.02).dark)
    }
}

