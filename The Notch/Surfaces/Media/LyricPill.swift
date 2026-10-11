import AppKit
import SwiftUI

/// The sung line, floating under the notch in a pill made of liquid.
///
/// It used to be split across the camera housing on the collapsed shoulders. That widened the
/// silhouette for as long as the song played, and reading a line that jumps a camera halfway
/// through is work. A pill under the notch holds the whole line at a readable size without
/// changing the notch at all.
///
/// The cost of floating is that it covers whatever is under it — usually a tab bar or a window
/// title, which is exactly what the pointer is heading for. So the pill is liquid: when the
/// pointer comes near, it splashes apart into drops that get out of the way, and when the
/// pointer leaves they flow back together. It never takes a click; the panel is click-through
/// everywhere outside the notch.
///
/// The pill is a row of overlapping drops drawn into the same metaball pass as the notch
/// (`NotchFX.drawLiquid`), which is what lets it merge, split and re-merge like one body of
/// liquid. Unlike the other effects it is simulated rather than closed-form, because it answers
/// the pointer; `step(to:pointer:)` advances it once per frame however many canvases draw it.
@MainActor
final class LyricPill {
    private enum Phase {
        case hidden
        /// A single drop forming under the notch and falling to where the pill will be.
        case dripping(start: TimeInterval)
        case floating
        /// The drops gathering into one, which then rises back into the notch.
        case leaving(start: TimeInterval)
    }

    private struct Drop {
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat = 0
        var vy: CGFloat = 0
        var radius: CGFloat
        var targetRadius: CGFloat
        /// Splashed loose: drifts and is pushed by the pointer instead of springing home.
        var isFree = false
        /// When a drop on its way home starts moving, so the pill re-forms from one end.
        var releaseAt: TimeInterval = 0
    }

    private var phase: Phase = .hidden
    private var drops: [Drop] = []
    private var isSplashed = false
    private var leftNearSince: TimeInterval?
    private var lastStep: TimeInterval?

    private(set) var line = ""
    private var previousLine = ""
    private var lineChangedAt: TimeInterval = 0
    private var width = Track(Theme.Metrics.LyricPill.minWidth)
    /// The silhouette the pill drips from and goes home to.
    private var attachment = NotchFX.Attachment(rect: .zero, topRadius: 0, bottomRadius: 0)
    private var notch: CGRect { attachment.rect }
    /// The line's type size: the body size, shrunk for a line too long for the widest pill.
    private var fontSize = Typography.bodySize

    private var metrics: Theme.Metrics.LyricPill.Type { Theme.Metrics.LyricPill.self }
    private var radius: CGFloat { metrics.height / 2 }
    private var center: CGPoint { CGPoint(x: notch.midX, y: notch.maxY + metrics.drop) }

    var isShowing: Bool {
        switch phase {
        case .dripping, .floating: true
        case .hidden, .leaving: false
        }
    }

    func reset() {
        phase = .hidden
        drops = []
        isSplashed = false
        line = ""
        previousLine = ""
    }

    func show(line: String, under notch: NotchFX.Attachment, at now: TimeInterval) {
        attachment = notch
        self.line = line
        fontSize = Self.fontSize(for: line)
        previousLine = ""
        lineChangedAt = now
        width = Track(metrics.minWidth)
        isSplashed = false
        phase = .dripping(start: now)
    }

    func setLine(_ newLine: String, at now: TimeInterval) {
        guard newLine != line else { return }
        previousLine = line
        previousFontSize = fontSize
        line = newLine
        fontSize = Self.fontSize(for: newLine)
        lineChangedAt = now
        width.rebase(at: now)
        width.retarget(targetWidth(for: newLine), at: now, .damped(Theme.Motion.Liquid.pillWidth))
    }

    func hide(at now: TimeInterval) {
        guard isShowing else { return }
        phase = .leaving(start: now)
        isSplashed = false
        for index in drops.indices {
            drops[index].isFree = false
            drops[index].releaseAt = now
            drops[index].targetRadius = radius
        }
        width.rebase(at: now)
        width.retarget(0, at: now, .bezier(Theme.Motion.Liquid.glide, Theme.Motion.Liquid.pillLeave * 0.5))
    }

    private var previousFontSize = Typography.bodySize

    /// Measured with the real font. It was estimated from the character count at half the point
    /// size per character, and Departure Mono is wider than that, so long lines ran past the
    /// ends of the pill and were cut off.
    private static func textWidth(_ line: String, size: CGFloat) -> CGFloat {
        let font = NSFont(name: Typography.postScriptName, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        return ceil((line as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The body size, unless the line would not fit the widest pill — then just small enough
    /// that it does, never below `minimumScale` of the body.
    private static func fontSize(for line: String) -> CGFloat {
        let metrics = Theme.Metrics.LyricPill.self
        let available = metrics.maxWidth - metrics.horizontalPadding * 2
        let natural = textWidth(line, size: Typography.bodySize)
        guard natural > available else { return Typography.bodySize }
        return max(Typography.bodySize * metrics.minimumScale, Typography.bodySize * available / natural)
    }

    private func targetWidth(for line: String) -> CGFloat {
        let text = Self.textWidth(line, size: Self.fontSize(for: line))
        return min(max(text + metrics.horizontalPadding * 2, metrics.minWidth), metrics.maxWidth)
    }

    // MARK: Simulation

    /// Advances the drops to `t`. Idempotent per instant: the liquid canvas and the text canvas
    /// both draw every frame, and stepping twice would run the pill at double speed.
    func step(to t: TimeInterval, pointer: CGPoint?, reduceMotion: Bool) {
        defer { lastStep = t }
        guard let last = lastStep, t > last else { return }
        let dt = CGFloat(min(t - last, 1.0 / 30))

        switch phase {
        case .hidden:
            return
        case let .dripping(start):
            let liquid = Theme.Motion.Liquid.self
            guard t - start >= liquid.pillDripForm + liquid.pillDripFall else { return }
            // The drop has landed: it becomes the pill, every drop starting at its centre and
            // springing out to its place, so the pill visibly spreads into its width.
            drops = (0 ..< metrics.dropCount).map { _ in
                Drop(x: center.x + .random(in: -2 ... 2), y: center.y, radius: radius, targetRadius: radius)
            }
            width = Track(metrics.minWidth * 0.4)
            width.retarget(targetWidth(for: line), at: t, .damped(Theme.Motion.Liquid.pillWidth))
            phase = .floating
        case .floating, .leaving:
            break
        }

        if case .floating = phase { updateSplash(at: t, pointer: pointer, reduceMotion: reduceMotion) }

        let spring = Theme.Motion.Liquid.pillGather
        let k = CGFloat(pow(2 * Double.pi / spring.response, 2))
        let c = CGFloat(4 * Double.pi * spring.damping / spring.response)
        let floor = notch.maxY + metrics.notchClearance
        for index in drops.indices {
            var drop = drops[index]
            if drop.isFree {
                let drag = max(0, 1 - CGFloat(Theme.Motion.Liquid.splashDrag) * dt)
                drop.vx *= drag
                drop.vy *= drag
                if let pointer {
                    let dx = drop.x - pointer.x
                    let dy = drop.y - pointer.y
                    let distance = max(hypot(dx, dy), 0.001)
                    if distance < metrics.pushRadius {
                        let push = CGFloat(Theme.Motion.Liquid.splashPush) * (1 - distance / metrics.pushRadius)
                        drop.vx += dx / distance * push * dt
                        drop.vy += dy / distance * push * dt
                    }
                }
                // Kept clear of the notch: a drop touching it would merge into the silhouette
                // and read as the notch leaking.
                if drop.y < floor { drop.vy += (floor - drop.y) * 60 * dt }
            } else if t >= drop.releaseAt {
                let home = self.home(index, at: t)
                drop.vx += (-k * (drop.x - home.x) - c * drop.vx) * dt
                drop.vy += (-k * (drop.y - home.y) - c * drop.vy) * dt
            }
            drop.x += drop.vx * dt
            drop.y += drop.vy * dt
            drop.radius += (drop.targetRadius - drop.radius) * min(1, dt * 7)
            drops[index] = drop
        }

        if case let .leaving(start) = phase, t - start >= Theme.Motion.Liquid.pillLeave {
            phase = .hidden
            drops = []
        }
    }

    private func updateSplash(at t: TimeInterval, pointer: CGPoint?, reduceMotion: Bool) {
        let distance = pointer.map { distanceToPill($0, at: t) } ?? .infinity
        if !isSplashed, distance < metrics.nearDistance {
            isSplashed = true
            leftNearSince = nil
            splash(from: pointer ?? center, at: t, reduceMotion: reduceMotion)
        } else if isSplashed {
            if distance > metrics.farDistance {
                leftNearSince = leftNearSince ?? t
                if t - (leftNearSince ?? t) > Theme.Motion.Liquid.regatherDelay { regather(at: t) }
            } else {
                leftNearSince = nil
            }
        }
    }

    /// Throws every drop away from the pointer. Reduce Motion gets a quieter version: the drops
    /// shrink away where they are, which still uncovers what was underneath.
    private func splash(from origin: CGPoint, at t: TimeInterval, reduceMotion: Bool) {
        for index in drops.indices {
            var drop = drops[index]
            drop.isFree = true
            if reduceMotion {
                drop.targetRadius = 0
                drop.vx = 0
                drop.vy = 0
            } else {
                let dx = drop.x - origin.x
                let dy = drop.y - origin.y
                let distance = max(hypot(dx, dy), 0.001)
                let speed = CGFloat.random(in: metrics.splashSpeed) * (1.25 - min(1, distance / 240))
                drop.vx = dx / distance * speed + .random(in: -60 ... 60)
                drop.vy = dy / distance * speed + .random(in: -110 ... 110)
                if abs(dy) < 8 { drop.vy += (Bool.random() ? -1 : 1) * .random(in: 70 ... 170) }
                if drop.vy < 0 { drop.vy *= 0.3 }
                drop.targetRadius = .random(in: metrics.splashRadius)
            }
            drops[index] = drop
        }
    }

    /// Calls the drops home, nearest first, so the pill re-forms from where most of it already
    /// is rather than all at once.
    private func regather(at t: TimeInterval) {
        isSplashed = false
        leftNearSince = nil
        let order = drops.indices.sorted {
            hypot(drops[$0].x - home($0, at: t).x, drops[$0].y - home($0, at: t).y)
                < hypot(drops[$1].x - home($1, at: t).x, drops[$1].y - home($1, at: t).y)
        }
        let spread = Theme.Motion.Liquid.regatherSpread
        for (rank, index) in order.enumerated() {
            drops[index].isFree = false
            drops[index].releaseAt = t + Double(rank) / Double(max(order.count, 1)) * spread
            drops[index].targetRadius = radius
        }
    }

    private func home(_ index: Int, at t: TimeInterval) -> CGPoint {
        let span = max(0, width.value(at: t) - metrics.height)
        let fraction = drops.count > 1 ? CGFloat(index) / CGFloat(drops.count - 1) : 0.5
        return CGPoint(x: center.x - span / 2 + span * fraction, y: center.y)
    }

    private func pillRect(at t: TimeInterval) -> CGRect {
        let w = max(width.value(at: t), metrics.height)
        return CGRect(x: center.x - w / 2, y: center.y - radius, width: w, height: metrics.height)
    }

    private func distanceToPill(_ point: CGPoint, at t: TimeInterval) -> CGFloat {
        let rect = pillRect(at: t)
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    /// How far the drops are from forming the pill, on average. The words fade with it.
    private func dispersion(at t: TimeInterval) -> CGFloat {
        guard !drops.isEmpty else { return 0 }
        var total: CGFloat = 0
        for index in drops.indices {
            let home = home(index, at: t)
            total += hypot(drops[index].x - home.x, drops[index].y - home.y)
        }
        return total / CGFloat(drops.count)
    }

    // MARK: Drawing

    /// The silhouette the drip hangs from, while it is attached.
    func attach(at t: TimeInterval) -> NotchFX.Attachment? {
        switch phase {
        case .dripping: attachment
        case let .leaving(start) where t - start > Theme.Motion.Liquid.pillLeave * 0.45: attachment
        default: nil
        }
    }

    func blobs(at t: TimeInterval) -> [(center: CGPoint, radius: CGFloat)] {
        let liquid = Theme.Motion.Liquid.self
        switch phase {
        case .hidden:
            return []
        case let .dripping(start):
            // One drop: forms against the bottom edge, then falls to the pill's centre.
            let elapsed = t - start
            let grow = Track.damped(from: 0, to: radius, spring: Theme.Motion.Liquid.dropGrow, elapsed: elapsed)
            let fall = UnitBezier(liquid.accelerate).solve((elapsed - liquid.pillDripForm) / liquid.pillDripFall)
            let y = notch.maxY - 2 + (center.y - notch.maxY + 2) * CGFloat(elapsed > liquid.pillDripForm ? fall : 0)
            return [(CGPoint(x: center.x, y: y), grow)]
        case .floating:
            return drops.map { (CGPoint(x: $0.x, y: $0.y), $0.radius) }
        case let .leaving(start):
            // The drops gather for the first half; then the gathered drop rises into the notch.
            let p = (t - start) / liquid.pillLeave
            guard p > 0.45 else { return drops.map { (CGPoint(x: $0.x, y: $0.y), $0.radius) } }
            let rise = CGFloat(Track.glide((p - 0.45) / 0.55))
            let y = center.y + (notch.maxY - 4 - center.y) * rise
            return [(CGPoint(x: center.x, y: y), radius * (1 - rise * 0.9))]
        }
    }

    /// The words, clipped to the pill, gliding up as each new line arrives and fading as the
    /// drops scatter.
    func drawText(in context: inout GraphicsContext, at t: TimeInterval) {
        guard case .floating = phase else { return }
        let opacity = Double(max(0, 1 - dispersion(at: t) / 10))
        guard opacity > 0.01 else { return }
        let glide = Track.decelerate(min(1, (t - lineChangedAt) / Theme.Motion.Liquid.lineGlide))
        let offset = metrics.lineGlideOffset
        let rect = pillRect(at: t)
        var clipped = context
        clipped.clip(to: Path(roundedRect: rect, cornerRadius: radius))
        if !previousLine.isEmpty, glide < 1 {
            draw(previousLine, size: previousFontSize, in: &clipped, at: CGPoint(x: rect.midX, y: rect.midY - offset * CGFloat(glide)), opacity: opacity * (1 - glide))
        }
        draw(line, size: fontSize, in: &clipped, at: CGPoint(x: rect.midX, y: rect.midY + offset * CGFloat(1 - glide)), opacity: opacity * glide)
    }

    private func draw(_ text: String, size: CGFloat, in context: inout GraphicsContext, at point: CGPoint, opacity: Double) {
        guard opacity > 0.01 else { return }
        context.drawLayer { layer in
            layer.opacity = opacity
            layer.draw(
                Text(text).font(Typography.font(size: size)).foregroundStyle(Theme.Colors.textPrimary),
                at: point,
                anchor: .center
            )
        }
    }
}
