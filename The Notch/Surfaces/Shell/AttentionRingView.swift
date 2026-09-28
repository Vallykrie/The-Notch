import SwiftUI

/// A light that travels around the notch's rim while an agent is blocked on the user.
///
/// This replaced an `AngularGradient` stroked around the closed silhouette, which was wrong in
/// three separate ways and looked it:
///
/// 1. **An angular gradient has no idea what shape it is painting.** It sweeps by *angle* about
///    the view's centre, and the resting silhouette is 264x32 — a rectangle eight times wider
///    than it is tall. Angle and arc length are only the same thing on a circle. On this shape
///    the bright band crawled across the two short end walls and then crossed each long edge in
///    a couple of frames, so the "sweep" visibly lurched four times a cycle. It read as a
///    gradient being rotated behind a window, which is exactly what it was.
/// 2. **It painted the top edge**, which is flush with the display bezel and has no screen under
///    it. Nearly half the cycle happened where nobody could see it.
/// 3. **The gradient's stops are a blob, not a comet.** Five stops with a hard 0.9 peak have no
///    direction: the band was as bright behind as in front, so there was nothing to tell the eye
///    which way the light was going.
///
/// The fix for all three is to stop faking it and trim the actual path. `NotchRimShape` is the
/// silhouette minus the invisible top edge, and trimming is parameterised by *arc length* — so a
/// phase advancing linearly is a light moving at genuinely constant speed along the real
/// outline, and phase 0...1 is exactly the part of the outline that is on screen.
///
/// The tail is a run of short trims rather than a gradient, which is what gives it a direction:
/// each step behind the head is dimmer and narrower than the one in front of it.
@MainActor
struct AttentionRingView: View {
    /// The silhouette to trace. Comes from the caller so the ring rides the same animated radii
    /// as the aperture rather than resolving its own.
    let shape: NotchShape
    let tint: Color
    /// Reduce Motion gets the resting rim and no travelling light. The signal still has to be
    /// there — a user who has asked for less motion has not asked to stop being told that an
    /// agent is blocked on them — so the rim brightens instead of animating.
    var isAnimated: Bool = true
    /// Renders one specific point of the travel instead of following the clock. For `FrameDump`
    /// only — see `AgentActivityGlyphView.debugElapsed` for the same reasoning.
    var debugPhase: CGFloat?

    /// Set only when the whole tree is being rendered at a pinned instant — see
    /// `EnvironmentValues.debugMotionTime`.
    @Environment(\.debugMotionTime) private var debugMotionTime

    var body: some View {
        Group {
            if let phase = debugPhase ?? debugMotionTime.map(phase(atElapsed:)) {
                canvas(phase: phase)
            } else if isAnimated {
                // `.animation` ticks with the display, so the sweep is smooth without owning a
                // timer. It only exists while something is actually blocked, so the cost is
                // bounded by the thing the user already wants their attention on.
                TimelineView(.animation) { context in
                    canvas(phase: phase(at: context.date))
                }
            } else {
                canvas(phase: nil)
            }
        }
        // The ring is drawn *outside* the silhouette, and a `Canvas` clips to its own bounds,
        // so the view is grown past the frame the overlay handed it. Only the sides and the
        // bottom: the top edge is flush with the display bezel, where there is no screen to
        // grow into — the same constraint `NotchShape` encodes in its inset.
        .padding(
            EdgeInsets(
                top: .zero,
                leading: -outerMargin,
                bottom: -outerMargin,
                trailing: -outerMargin
            )
        )
        .allowsHitTesting(false)
    }

    /// How far past the silhouette the ring's canvas extends: the stroke's own offset plus the
    /// room its blurred copy needs.
    private var outerMargin: CGFloat {
        Theme.Metrics.Ring.outset + Theme.Metrics.Ring.bleed
    }

    /// One `Canvas` rather than a stack of `Shape` views, and the reason is the tail's banding.
    ///
    /// The tail is a brightness ramp built from discrete strokes, so the number of strokes *is*
    /// its bit depth. At fourteen — which is as many `Shape` views as it is reasonable to lay in
    /// a `ZStack` and re-evaluate every frame — the steps near the head are about 13% of full
    /// brightness apart, and the rendered filmstrip showed exactly what that looks like: a tail
    /// that reads as a dashed line. It is not seams between the strokes, and chasing it as
    /// seams is a dead end. Butt caps against round caps, and overlapping against abutting,
    /// only ever trade a dark artefact for a bright one; the staircase survives all four
    /// combinations because the staircase is the alpha, not the geometry.
    ///
    /// The only real fix is more steps, and a `Canvas` is what makes more steps affordable:
    /// these are `GraphicsContext` strokes of one prebuilt `Path`, not forty-eight views with
    /// identity, layout and animatable data of their own. At `tailSegments` the step is under
    /// 4% and the ramp resolves as smooth.
    private func canvas(phase: CGFloat?) -> some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let path = rim.path(in: CGRect(origin: .zero, size: size))

            context.stroke(
                path,
                with: .color(
                    tint.opacity(
                        phase == nil
                            ? Theme.Metrics.Ring.staticOpacity
                            : Theme.Metrics.Ring.restingOpacity
                    )
                ),
                style: strokeStyle(width: Theme.Metrics.Ring.lineWidth)
            )

            guard let phase else { return }

            // The soft copy under the crisp one. This is the part that reads as light rather
            // than as ink; without it the comet is a coloured line that happens to move.
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: Theme.Metrics.Ring.glowBlur))
                drawComet(
                    in: &layer,
                    path: path,
                    phase: phase,
                    widthScale: Theme.Metrics.Ring.glowWidthScale,
                    opacityScale: Theme.Metrics.Ring.glowOpacity
                )
            }

            drawComet(in: &context, path: path, phase: phase, widthScale: 1, opacityScale: 1)
        }
    }

    /// The travelling light: a bright head with a tapering tail behind it.
    ///
    /// `.lighten` rather than the default source-over. Where two steps overlap, light takes the
    /// brighter of the two instead of accumulating both — which is both what light does and what
    /// keeps a generous overlap from beading. The overlap in turn is what guarantees no
    /// antialiased seam can open between neighbours.
    private func drawComet(
        in context: inout GraphicsContext,
        path: Path,
        phase: CGFloat,
        widthScale: CGFloat,
        opacityScale: CGFloat
    ) {
        let count = Theme.Metrics.Ring.tailSegments
        let step = Theme.Metrics.Ring.cometLength / CGFloat(count)
        context.blendMode = .lighten

        for index in 0 ..< count {
            // 0 at the head, 1 at the end of the tail.
            let distance = CGFloat(index) / CGFloat(count)
            let trailing = phase - CGFloat(index) * step
            let leading = trailing - step * (1 + Theme.Metrics.Ring.segmentOverlap)
            // Squared, not linear. A linear ramp spends half the tail's length above 50%
            // brightness, which makes the tail a band with a slightly brighter end rather than
            // a comet; squaring puts the falloff where the eye reads it as speed.
            let strength = pow(1 - distance, 2) * opacityScale
            let width = Theme.Metrics.Ring.lineWidth
                * widthScale
                * (1 - distance * Theme.Metrics.Ring.tailNarrowing)

            for span in spans(from: leading, to: trailing) {
                context.stroke(
                    path.trimmedPath(from: span.from, to: span.to),
                    with: .color(tint.opacity(strength * edgeFalloff(at: span.midpoint))),
                    // Round only on the head — it is the one end meant to look like the front
                    // of something. Everywhere else a cap is a half-disc drawn past the step's
                    // end, which is a bump of doubled width the taper has to fight.
                    style: strokeStyle(width: width, cap: index == 0 ? .round : .butt)
                )
            }
        }
    }

    /// Splits a step into the one or two runs of `0...1` it actually covers.
    ///
    /// The rim is an open path, so a step running off the top-right end has to reappear at the
    /// top-left one. Both halves are drawn, and `edgeFalloff` fades each of them by *its own*
    /// position rather than by the head's — so the head dims as it reaches the bezel while the
    /// tail behind it is still at full strength in the middle of the rim, and the two ends of
    /// the cycle overlap into each other instead of cutting.
    private func spans(from leading: CGFloat, to trailing: CGFloat) -> [Span] {
        // Both ends live in an unwrapped space that can run outside 0...1; shifting by whole
        // turns is what puts them back on the path.
        let candidates = leading < 0
            ? [
                Span(from: leading + 1, to: min(trailing + 1, 1)),
                Span(from: 0, to: max(trailing, 0)),
            ]
            : [Span(from: leading, to: trailing)]
        return candidates.filter(\.isDrawable)
    }

    /// A run of the rim to stroke.
    private struct Span {
        let from: CGFloat
        let to: CGFloat

        /// A wrapped step that has not actually crossed the end yet produces an empty second
        /// span. Trimming and stroking an empty range is not free, so these are dropped.
        var isDrawable: Bool { to > from }
        var midpoint: CGFloat { (from + to) / 2 }
    }

    /// How bright the light is allowed to be at a given point along the rim.
    ///
    /// 1 across the middle, falling to 0 at both ends. The ends are the top corners, where the
    /// silhouette meets the bezel — so the light does not stop there, it goes *behind* the
    /// bezel, and comes back out the other side. That is what removes the restart: at no frame
    /// is there a bright head appearing or vanishing in open screen.
    private func edgeFalloff(at position: CGFloat) -> CGFloat {
        let fade = Theme.Metrics.Ring.edgeFade
        guard fade > 0 else { return 1 }
        let distanceToEnd = min(position, 1 - position)
        guard distanceToEnd < fade else { return 1 }
        // Smoothstep, so the light does not arrive with a corner in its brightness.
        let t = max(.zero, distanceToEnd / fade)
        return t * t * (3 - 2 * t)
    }

    /// The path the light travels.
    ///
    /// The canvas is `outset + bleed` larger than the silhouette on both sides and the bottom,
    /// so insetting the rim by `bleed` alone puts its centreline exactly `outset` points
    /// *outside* the real edge — with `bleed` left over as the margin the glow blurs into.
    private var rim: NotchRimShape {
        // Radii grow with the offset, or the ring would only be parallel to the silhouette
        // along the straight runs and bulge away from it around every corner: a fixed radius
        // on a larger rectangle is a translated arc, not an offset one.
        let offset = Theme.Metrics.Ring.outset
        let outsetShape = NotchShape(
            topCornerRadius: shape.topCornerRadius + offset,
            bottomCornerRadius: shape.bottomCornerRadius + offset,
            inset: shape.inset
        )
        return NotchRimShape(outsetShape, inset: Theme.Metrics.Ring.bleed)
    }

    private func strokeStyle(width: CGFloat, cap: CGLineCap = .round) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: cap, lineJoin: .round)
    }

    private func phase(at date: Date) -> CGFloat {
        phase(atElapsed: date.timeIntervalSinceReferenceDate)
    }

    private func phase(atElapsed elapsed: Double) -> CGFloat {
        let period = Theme.Motion.ringPeriod
        return CGFloat(elapsed.truncatingRemainder(dividingBy: period) / period)
    }
}

#Preview {
    ZStack {
        Color(white: 0.3)
        AttentionRingView(
            shape: NotchShape(topCornerRadius: 6, bottomCornerRadius: 14),
            tint: Theme.Colors.Status.needsApproval
        )
        .frame(width: 264, height: 32)
        .background(Color.black)
    }
    .frame(width: 500, height: 200)
}
