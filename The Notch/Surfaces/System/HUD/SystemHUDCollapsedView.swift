import SwiftUI

/// The HUD's left shoulder: what is being changed.
///
/// Neither of the two views here takes a frame of its own. The collapsed shell pins them into
/// fixed-width shoulders that are symmetric about the camera housing, and a view that also sizes
/// itself fights that — an intrinsic width here is what pushed content under the housing the last
/// time a shoulder tried to be self-sizing.
@MainActor
struct SystemHUDLeadingView: View {
    let event: SystemHUDEvent

    var body: some View {
        HStack(spacing: Theme.Metrics.HUD.contentSpacing) {
            PixelGlyphView(glyph: event.glyph, side: Theme.Metrics.HUD.glyphSize)
                .foregroundStyle(event.hudTint)

            Text(event.label)
                .font(Theme.Text.caption)
                .foregroundStyle(event.hudTint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(event.accessibilityDescription))
    }
}

/// The HUD's right shoulder: how much of it there is.
@MainActor
struct SystemHUDTrailingView: View {
    let event: SystemHUDEvent

    var body: some View {
        ZStack(alignment: .leading) {
            bar.fill(
                event.hudTint.opacity(Theme.Metrics.HUD.barTrackOpacity)
            )

            bar.fill(event.hudTint)
                .frame(width: fillWidth)
        }
        .frame(
            width: Theme.Metrics.HUD.barWidth,
            height: Theme.Metrics.HUD.barHeight
        )
        // The level is a continuous quantity being dragged as often as it is tapped, so the fill
        // interpolates instead of stepping. This is the shared content curve rather than the
        // shoulder spring: the silhouette is not moving, only the ink inside it.
        .animation(Theme.Motion.content, value: event.level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(event.accessibilityDescription))
    }

    private var bar: some Shape {
        RoundedRectangle(
            cornerRadius: Theme.Metrics.HUD.barCornerRadius,
            style: .continuous
        )
    }

    /// A zero level still draws a stub. A bar that vanishes at silence reads as a rendering bug
    /// rather than as "muted", and it also removes the only cue that the empty track *is* a
    /// track — the user needs to see what the level is measured against.
    private var fillWidth: CGFloat {
        let fraction = max(CGFloat(event.level), Theme.Metrics.HUD.barMinimumFraction)
        return Theme.Metrics.HUD.barWidth * fraction
    }
}

private extension SystemHUDEvent {
    @MainActor
    var hudTint: Color {
        if case .volume(_, true) = self { return Theme.Colors.hudMuted }
        return Theme.Colors.textPrimary
    }

    /// Both shoulders carry the whole sentence. VoiceOver reaches them as two separate elements
    /// on opposite sides of the notch, and a bare "62 percent" with no subject is useless if the
    /// user lands on the level first.
    var accessibilityDescription: String {
        let percentage = Int((level * 100).rounded())
        switch self {
        case let .volume(_, isMuted) where isMuted:
            return "Volume muted, \(percentage) percent"
        default:
            return "\(label) \(percentage) percent"
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        let events: [SystemHUDEvent] = [
            .volume(level: 0.62, isMuted: false),
            .volume(level: 0, isMuted: true),
            .brightness(level: 0.35),
        ]

        ForEach(events.indices, id: \.self) { index in
            HStack(spacing: 40) {
                SystemHUDLeadingView(event: events[index])
                SystemHUDTrailingView(event: events[index])
            }
        }
    }
    .padding()
    .background(Theme.Colors.surface)
}
