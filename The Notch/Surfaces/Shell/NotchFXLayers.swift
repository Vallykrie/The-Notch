import SwiftUI

/// The canvases that draw `NotchFX`, one per depth.
///
/// Three rather than one because the effects live at three depths relative to the crisp notch:
/// liquid *behind* it (so a drop grows out from under the edge), stars and pixels *inside* it
/// (clipped by the springing silhouette), and sparks, rings and the lyric pill's words *in
/// front of* everything. Each canvas runs on the display link only while it has something to
/// draw, and is otherwise a paused, empty view.

/// Behind the notch: the metaball pass. Blurring the black shapes and thresholding the alpha
/// back to a hard edge is what turns overlapping circles into one body of liquid — the shapes
/// merge where their blurs overlap, and pull apart into separate drops where they do not.
struct NotchLiquidLayer: View {
    let fx: NotchFX

    var body: some View {
        TimelineView(.animation(paused: !fx.needsLiquidFrames)) { timeline in
            Canvas { context, _ in
                let t = timeline.date.timeIntervalSinceReferenceDate
                fx.pill.step(to: t, pointer: fx.pointer(), reduceMotion: fx.reduceMotion)
                context.addFilter(.alphaThreshold(min: Theme.Metrics.Liquid.threshold, color: Theme.Colors.surface))
                context.addFilter(.blur(radius: Theme.Metrics.Liquid.blur))
                context.drawLayer { layer in
                    fx.drawLiquid(in: &layer, at: t)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Inside the notch. Sized to the whole panel and laid over the aperture, so the aperture's clip
/// is what bounds it: stars and pixels are uncovered by the notch opening, not drawn over it.
struct NotchInnerFXLayer: View {
    let fx: NotchFX

    var body: some View {
        TimelineView(.animation(paused: !fx.needsInnerFrames)) { timeline in
            Canvas { context, _ in
                fx.drawInner(in: &context, at: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// In front of everything, unclipped: what flies out of the notch onto the desktop.
struct NotchOuterFXLayer: View {
    let fx: NotchFX

    var body: some View {
        TimelineView(.animation(paused: !fx.needsOuterFrames)) { timeline in
            Canvas { context, _ in
                let t = timeline.date.timeIntervalSinceReferenceDate
                fx.pill.step(to: t, pointer: fx.pointer(), reduceMotion: fx.reduceMotion)
                fx.drawOuter(in: &context, at: t)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Light running along the notch's edge: a pulse for a prompt, a sweep for a finished run.
/// Drawn as an overlay on the aperture, so it follows the silhouette while it springs.
struct NotchRimFlashView: View {
    let fx: NotchFX
    let shape: NotchShape

    var body: some View {
        TimelineView(.animation(paused: !fx.needsRimFrames)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Array(fx.rims.enumerated()), id: \.offset) { _, rim in
                    rimLayer(rim, at: t)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func rimLayer(_ rim: NotchFX.Rim, at t: TimeInterval) -> some View {
        let p = min(1, max(0, (t - rim.born) / rim.life))
        let width = Theme.Metrics.Attention.rimWidth
        switch rim.mode {
        case .pulse:
            NotchRimShape(shape, inset: width / 2)
                .stroke(rim.tint.opacity(0.9 * (1 - p)), lineWidth: width)
        case .sweep:
            // A bright window travelling left to right across the rim.
            let head = Track.glide(p)
            NotchRimShape(shape, inset: width / 2)
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: rim.tint.opacity(0), location: max(0, head - 0.12)),
                            .init(color: rim.tint, location: head),
                            .init(color: rim.tint.opacity(0), location: min(1, head + 0.12)),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: width
                )
        }
    }
}
