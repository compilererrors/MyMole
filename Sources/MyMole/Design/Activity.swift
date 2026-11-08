import AppKit
import SwiftUI

// The one way MyMole shows that something is loading or running: a soft
// light that pulses in the colour of whatever is working. Bars, dots and
// whole cards use the same rhythm, so "busy" reads the same everywhere.
//
// The motion runs as Core Animation on plain layers: the window server plays
// it, so it costs the app nothing per frame. SwiftUI animations would
// re-run the view graph and the window layout on every frame. With Reduce
// Motion on, everything holds still.

enum Pulse {
    /// One breath, in seconds.
    static let period: CFTimeInterval = 1.4
}

/// A progress bar that breathes while work is going on. `value` nil means
/// "busy, amount unknown": the bar is full and a light sweeps along it.
struct PulseBar: View {
    var value: Double?
    /// Nil: the theme's accent.
    var tint: Color?
    var active = true
    @Environment(\.palette) private var palette

    var body: some View {
        let tint = tint ?? palette.accentText.color
        GeometryReader { g in
            let fraction = min(max(value ?? 1, 0), 1)
            let filled = max(6, g.size.width * fraction)
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.15))
                Capsule()
                    .fill(tint.opacity(value == nil ? 0.35 : 0.9))
                    .frame(width: filled)
                if active {
                    LayerAnimation(kind: .sweep, tint: NSColor(tint))
                        .frame(width: filled)
                        .clipShape(Capsule())
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.3), value: value)
        .accessibilityElement()
        .accessibilityLabel(value.map { String(localized: "\(Int($0 * 100)) percent") } ?? String(localized: "In progress"))
    }
}

/// A small breathing dot: "this is working", for sidebars, badges, rows.
struct PulseDot: View {
    /// Nil: the theme's accent.
    var tint: Color?
    var size: CGFloat = 8
    @Environment(\.palette) private var palette

    var body: some View {
        LayerAnimation(kind: .dot, tint: tint.map { NSColor($0) } ?? palette.accentText.ns)
            .frame(width: size, height: size)
            .accessibilityLabel("Working")
    }
}

/// The glow of `pulsing`, in the theme's accent unless told otherwise.
private struct PulseGlow: View {
    let tint: Color?
    let cornerRadius: CGFloat
    @Environment(\.palette) private var palette

    var body: some View {
        LayerAnimation(kind: .glow(cornerRadius), tint: tint.map { NSColor($0) } ?? palette.accentText.ns)
            .allowsHitTesting(false)
    }
}

extension View {
    /// A soft light breathing over the view while `active`, in the colour of
    /// what's working: for a card or row whose content is being refreshed.
    func pulsing(_ active: Bool, tint: Color? = nil, cornerRadius: CGFloat = DS.Radius.card) -> some View {
        overlay {
            if active { PulseGlow(tint: tint, cornerRadius: cornerRadius) }
        }
    }
}

/// A whole area that's loading: the pulse with a line saying what.
struct DSLoading: View {
    var text: Phrase

    init(_ text: LocalizedStringResource = "Loading…") { self.text = Phrase(text) }
    @_disfavoredOverload
    init(_ text: String) { self.text = Phrase(verbatim: text) }

    var body: some View {
        VStack(spacing: DS.Space.md) {
            PulseDot(size: 14)
            DSText(phrase: text, .lead)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Core Animation

private struct LayerAnimation: NSViewRepresentable {
    enum Kind: Equatable {
        case dot, sweep
        case glow(CGFloat)
    }

    let kind: Kind
    let tint: NSColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> PulseLayerView {
        PulseLayerView(kind: kind)
    }

    func updateNSView(_ view: PulseLayerView, context: Context) {
        view.update(tint: tint, still: reduceMotion)
    }
}

private final class PulseLayerView: NSView {
    private let kind: LayerAnimation.Kind
    private let core = CALayer()
    private let halo = CALayer()
    private let shine = CAGradientLayer()
    private var tint: NSColor?
    private var still = false
    private var laidOutSize: CGSize = .zero

    init(kind: LayerAnimation.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        switch kind {
        case .dot:
            layer?.addSublayer(halo)
            layer?.addSublayer(core)
        case .sweep:
            layer?.masksToBounds = true
            layer?.addSublayer(shine)
        case .glow:
            layer?.addSublayer(core)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(tint: NSColor, still: Bool) {
        guard tint != self.tint || still != self.still else { return }
        self.tint = tint
        self.still = still
        restart()
    }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        switch kind {
        case .dot:
            core.frame = b
            core.cornerRadius = b.width / 2
            halo.frame = b
            halo.cornerRadius = b.width / 2
        case .sweep:
            let w = max(40, b.width * 0.3)
            shine.frame = CGRect(x: -w, y: 0, width: w, height: b.height)
        case .glow(let r):
            core.frame = b
            core.cornerRadius = r
        }
        CATransaction.commit()
        restart()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restart()
    }

    private func restart() {
        guard let tint else { return }
        core.removeAllAnimations()
        halo.removeAllAnimations()
        shine.removeAllAnimations()
        switch kind {
        case .dot:
            core.backgroundColor = tint.cgColor
            halo.backgroundColor = tint.withAlphaComponent(0.35).cgColor
            guard !still else { halo.opacity = 0; return }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 2.2
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = Pulse.period
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.repeatCount = .infinity
            halo.add(group, forKey: "pulse")
        case .sweep:
            shine.colors = [
                NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.5).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor,
            ]
            shine.startPoint = CGPoint(x: 0, y: 0.5)
            shine.endPoint = CGPoint(x: 1, y: 0.5)
            guard !still, bounds.width > 0 else { return }
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = -shine.bounds.width / 2
            move.toValue = bounds.width + shine.bounds.width / 2
            move.duration = Pulse.period * 1.4
            move.repeatCount = .infinity
            shine.add(move, forKey: "sweep")
        case .glow:
            core.backgroundColor = tint.withAlphaComponent(0.12).cgColor
            guard !still else { core.opacity = 0.5; return }
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.15
            breathe.toValue = 1
            breathe.duration = Pulse.period / 2
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            core.add(breathe, forKey: "glow")
        }
    }
}
