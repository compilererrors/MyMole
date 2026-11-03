import SwiftUI

/// The one way the charts write a name onto a colored block. A name is drawn
/// whole or not at all: it may wrap at its break points (`/ - _ .` and
/// spaces), but a word is never cut and never runs out of its block. The
/// size goes on the line below when there's room. Text is black or white,
/// whichever reads better on the fill.
enum ChartLabel {
    /// Where the text sits in its rect: top-left (blocks), centered (slices),
    /// or vertically centered against the left or right edge (pie labels
    /// beside a leader line).
    enum Placement { case topLeading, center, leading, trailing }

    /// Draws the label in `rect`; returns false (and draws nothing) when the
    /// name can't fit whole.
    @discardableResult
    static func draw(
        _ name: String, detail: String? = nil, in rect: CGRect, on fill: Color,
        placement: Placement = .topLeading, emphasis: Bool = true, large: Bool = false,
        ctx: GraphicsContext
    ) -> Bool {
        guard rect.width > 8, rect.height > 8 else { return false }
        let dark = prefersDarkInk(on: fill, ctx.environment)
        let ink: Color = dark ? .black.opacity(0.82) : .white
        let font: Font = (large ? Font.subheadline : .caption).weight(emphasis ? .semibold : .medium)

        // Every unbreakable piece of the name must fit the width on its own,
        // or the text system would split it mid-word.
        let broken = Breakable.text(name)
        let pieces = broken.split(whereSeparator: { $0 == "\u{200B}" || $0 == " " })
        for piece in pieces {
            let w = ctx.resolve(Text(String(piece)).font(font)).measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width
            if w > rect.width { return false }
        }
        let title = ctx.resolve(Text(broken).font(font).foregroundStyle(ink))
        let titleSize = title.measure(in: CGSize(width: rect.width, height: CGFloat.greatestFiniteMagnitude))
        guard titleSize.height <= rect.height else { return false }

        var sub: GraphicsContext.ResolvedText?
        var subSize = CGSize.zero
        if let detail {
            let r = ctx.resolve(Text(detail).font(large ? .caption : .caption2).monospacedDigit().foregroundStyle(ink.opacity(0.8)))
            let s = r.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            if s.width <= rect.width, titleSize.height + s.height <= rect.height {
                sub = r
                subSize = s
            }
        }

        let block = CGSize(width: max(titleSize.width, subSize.width), height: titleSize.height + subSize.height)
        let origin =
            switch placement {
            case .topLeading: rect.origin
            case .center: CGPoint(x: rect.midX - block.width / 2, y: rect.midY - block.height / 2)
            case .leading: CGPoint(x: rect.minX, y: rect.midY - block.height / 2)
            case .trailing: CGPoint(x: rect.maxX - block.width, y: rect.midY - block.height / 2)
            }
        var c = ctx
        if !dark { c.addFilter(.shadow(color: .black.opacity(0.45), radius: 1)) }
        func x(_ width: CGFloat) -> CGFloat {
            switch placement {
            case .topLeading, .leading: origin.x
            case .center: origin.x + (block.width - width) / 2
            case .trailing: origin.x + block.width - width
            }
        }
        c.draw(title, in: CGRect(origin: CGPoint(x: x(titleSize.width), y: origin.y), size: titleSize))
        if let sub {
            c.draw(sub, in: CGRect(origin: CGPoint(x: x(subSize.width), y: origin.y + titleSize.height), size: subSize))
        }
        return true
    }

    /// Black text when the fill (laid over the window background, for
    /// translucent fills) is lighter than the point where black and white
    /// have equal contrast.
    static func prefersDarkInk(on fill: Color, _ env: EnvironmentValues) -> Bool {
        let f = fill.resolve(in: env)
        let bg = Color(nsColor: .windowBackgroundColor).resolve(in: env)
        let a = f.opacity
        func lum(_ c: Color.Resolved) -> Float { 0.2126 * c.linearRed + 0.7152 * c.linearGreen + 0.0722 * c.linearBlue }
        let l = lum(f) * a + lum(bg) * (1 - a)
        return l > 0.18
    }
}
