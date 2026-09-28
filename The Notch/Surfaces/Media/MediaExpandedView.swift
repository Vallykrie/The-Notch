import AppKit
import SwiftUI

@MainActor
struct MediaExpandedView: View {
    @ObservedObject var nowPlaying: NowPlayingMonitor

    @State private var decodedArtwork: NSImage?
    @State private var draggedProgress: Double?
    @State private var isDraggingScrubber = false
    @State private var isAwaitingSeekRefresh = false

    private static let timeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()

    var body: some View {
        Group {
            if nowPlaying.status.isActive {
                activeContent
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Theme.Metrics.expandedHorizontalPadding)
        .padding(.bottom, Theme.Metrics.expandedVerticalPadding)
        .onAppear(perform: refreshArtwork)
        .onChange(of: nowPlaying.status.artworkIdentity) { _, _ in
            refreshArtwork()
        }
        .onChange(of: nowPlaying.status) { _, _ in
            // A seek stays visually pinned until the monitor publishes again; immediately
            // returning to its pre-seek value makes the thumb appear to reject the gesture.
            guard isAwaitingSeekRefresh, !isDraggingScrubber else { return }
            draggedProgress = nil
            isAwaitingSeekRefresh = false
        }
    }

    private var activeContent: some View {
        HStack(spacing: Theme.Metrics.MediaPanel.columnSpacing) {
            artwork

            VStack(alignment: .leading, spacing: Theme.Metrics.MediaPanel.rowSpacing) {
                Text(nowPlaying.status.title)
                    .font(Theme.Text.title)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(nowPlaying.status.artist)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                scrubber
                transportControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: Theme.Metrics.MediaPanel.artworkCornerRadius,
                style: .continuous
            )
            .fill(
                Theme.Colors.textPrimary.opacity(
                    Theme.Metrics.MediaPanel.scrubberTrackOpacity
                )
            )

            if let decodedArtwork {
                Image(nsImage: decodedArtwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(
                        width: Theme.Metrics.MediaPanel.artworkSize,
                        height: Theme.Metrics.MediaPanel.artworkSize
                    )
                    .clipped()
                    .id(nowPlaying.status.artworkIdentity)
            } else {
                PixelGlyphView(
                    glyph: .play,
                    side: Theme.Metrics.glyphExpandedSize
                )
                .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .frame(
            width: Theme.Metrics.MediaPanel.artworkSize,
            height: Theme.Metrics.MediaPanel.artworkSize
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: Theme.Metrics.MediaPanel.artworkCornerRadius,
                style: .continuous
            )
        )
        .overlay(alignment: .bottomTrailing) {
            sourceBadge
        }
        .animation(Theme.Motion.content, value: nowPlaying.status.artworkIdentity)
    }

    @ViewBuilder
    private var sourceBadge: some View {
        if let player = nowPlaying.status.player {
            Circle()
                .fill(Theme.Colors.surface)
                .frame(
                    width: Theme.Metrics.MediaPanel.sourceBadgeSize,
                    height: Theme.Metrics.MediaPanel.sourceBadgeSize
                )
                .overlay {
                    PixelGlyphView(
                        glyph: .musicNote,
                        side: Theme.Metrics.glyphCollapsedSize
                    )
                    .foregroundStyle(sourceBadgeTint(for: player))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(sourceBadgeLabel(for: player))
        }
    }

    private var scrubber: some View {
        HStack(spacing: Theme.Metrics.MediaPanel.scrubberSpacing) {
            timeLabel(nowPlaying.status.elapsedPosition, alignment: .leading)

            GeometryReader { geometry in
                let progress = displayedProgress

                ZStack(alignment: .leading) {
                    RoundedRectangle(
                        cornerRadius: Theme.Metrics.MediaPanel.scrubberCornerRadius
                    )
                    .fill(
                        Theme.Colors.textPrimary.opacity(
                            Theme.Metrics.MediaPanel.scrubberTrackOpacity
                        )
                    )

                    RoundedRectangle(
                        cornerRadius: Theme.Metrics.MediaPanel.scrubberCornerRadius
                    )
                    .fill(Theme.Colors.Status.playing)
                    .frame(width: geometry.size.width * CGFloat(progress))
                }
                .frame(height: Theme.Metrics.MediaPanel.scrubberHeight)
                // The drawn bar is 4pt; the thing you can grab is `scrubberHitHeight`.
                // Centring the bar inside the taller hit frame keeps the row's visual
                // rhythm while giving the drag somewhere to land — this panel's top edge is
                // against the menu bar, so a 4pt target is effectively unhittable.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    scrubberGesture(width: geometry.size.width),
                    including: nowPlaying.status.duration == nil ? .none : .all
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Playback position")
                .accessibilityValue(progress.formatted(.percent))
            }
            .frame(height: Theme.Metrics.MediaPanel.scrubberHitHeight)

            timeLabel(nowPlaying.status.duration, alignment: .trailing)
        }
    }

    private var transportControls: some View {
        HStack(spacing: Theme.Metrics.MediaPanel.transportSpacing) {
            decorativeControl(glyph: .heart, label: "Favorite")

            Button {
                nowPlaying.previousTrack()
            } label: {
                PixelGlyphView(
                    glyph: .skipBack,
                    side: Theme.Metrics.MediaPanel.transportGlyphSize
                )
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(
                    width: Theme.Metrics.MediaPanel.transportHitSize,
                    height: Theme.Metrics.MediaPanel.transportHitSize
                )
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Previous track")
            .transportButtonStyle()

            Button {
                nowPlaying.playPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            Theme.Colors.textPrimary.opacity(
                                Theme.Metrics.MediaPanel.primaryFillOpacity
                            )
                        )

                    if nowPlaying.status.isPlaying {
                        PixelGlyphView(
                            glyph: .pause,
                            side: Theme.Metrics.MediaPanel.primaryTransportGlyphSize
                        )
                        .transition(.opacity)
                    } else {
                        PixelGlyphView(
                            glyph: .play,
                            side: Theme.Metrics.MediaPanel.primaryTransportGlyphSize
                        )
                        .transition(.opacity)
                    }
                }
                .foregroundStyle(Theme.Colors.textPrimary)
                .frame(
                    width: Theme.Metrics.MediaPanel.primaryTransportHitSize,
                    height: Theme.Metrics.MediaPanel.primaryTransportHitSize
                )
                .contentShape(Circle())
                .animation(Theme.Motion.content, value: nowPlaying.status.isPlaying)
            }
            .accessibilityLabel(nowPlaying.status.isPlaying ? "Pause" : "Play")
            .transportButtonStyle()

            Button {
                nowPlaying.nextTrack()
            } label: {
                PixelGlyphView(
                    glyph: .skipForward,
                    side: Theme.Metrics.MediaPanel.transportGlyphSize
                )
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(
                    width: Theme.Metrics.MediaPanel.transportHitSize,
                    height: Theme.Metrics.MediaPanel.transportHitSize
                )
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Next track")
            .transportButtonStyle()

            decorativeControl(glyph: .repeatTrack, label: "Repeat")
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Metrics.expandedContentSpacing) {
            PixelGlyphView(glyph: .play, side: Theme.Metrics.glyphExpandedSize)
                .foregroundStyle(Theme.Colors.textTertiary)

            Text("Nothing playing")
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Colors.textSecondary)

            Text("Start Spotify or Music")
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var displayedProgress: Double {
        min(max(draggedProgress ?? nowPlaying.status.progress ?? .zero, .zero), 1)
    }

    private func scrubberGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: .zero)
            .onChanged { value in
                guard width > .zero else { return }
                isDraggingScrubber = true
                draggedProgress = clampedFraction(for: value.location.x, width: width)
            }
            .onEnded { value in
                guard width > .zero else {
                    isDraggingScrubber = false
                    return
                }

                let fraction = clampedFraction(for: value.location.x, width: width)
                draggedProgress = fraction
                isDraggingScrubber = false
                isAwaitingSeekRefresh = true
                nowPlaying.seek(toFraction: fraction)
            }
    }

    private func clampedFraction(for position: CGFloat, width: CGFloat) -> Double {
        Double(min(max(position / width, .zero), 1))
    }

    private func timeLabel(_ time: TimeInterval?, alignment: Alignment) -> some View {
        Text(formattedTime(time))
            .font(Theme.Text.caption)
            .foregroundStyle(Theme.Colors.textTertiary)
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: Theme.Metrics.MediaPanel.timeColumnWidth, alignment: alignment)
    }

    private func formattedTime(_ time: TimeInterval?) -> String {
        guard let time, time.isFinite else { return "--:--" }
        guard let formatted = Self.timeFormatter.string(from: max(time, .zero)) else {
            return "--:--"
        }

        let zeroHourPrefix = "00:"
        let hourTrimmed = formatted.hasPrefix(zeroHourPrefix)
            ? String(formatted.dropFirst(zeroHourPrefix.count))
            : formatted
        let leadingZero = "0"
        guard hourTrimmed.hasPrefix(leadingZero) else { return hourTrimmed }
        return String(hourTrimmed.dropFirst(leadingZero.count))
    }

    private func decorativeControl(glyph: PixelGlyph, label: String) -> some View {
        Button {} label: {
            PixelGlyphView(
                glyph: glyph,
                side: Theme.Metrics.MediaPanel.transportGlyphSize
            )
            .foregroundStyle(Theme.Colors.textTertiary)
            .frame(
                width: Theme.Metrics.MediaPanel.transportHitSize,
                height: Theme.Metrics.MediaPanel.transportHitSize
            )
            .contentShape(Rectangle())
        }
        .opacity(Theme.Metrics.MediaPanel.disabledOpacity)
        .disabled(true)
        .accessibilityLabel(label)
        .transportButtonStyle()
    }

    private func sourceBadgeTint(for player: NowPlayingStatus.Player) -> Color {
        switch player {
        case .spotify:
            Theme.Colors.Status.playing
        case .music:
            Theme.Colors.textPrimary
        }
    }

    private func sourceBadgeLabel(for player: NowPlayingStatus.Player) -> String {
        switch player {
        case .spotify:
            "Spotify"
        case .music:
            "Music"
        }
    }

    private func refreshArtwork() {
        decodedArtwork = nowPlaying.status.artwork.flatMap(NSImage.init(data:))
    }
}

private struct MediaTransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed
                    ? Theme.Metrics.MediaPanel.pressedScale
                    : 1
            )
            .animation(Theme.Motion.content, value: configuration.isPressed)
    }
}

private extension View {
    /// Deliberately *only* the custom style. Applying `.plain` as well — which is what this
    /// originally did — silently killed the press feedback: `.plain` is a
    /// `PrimitiveButtonStyle`, and the style nearest the `Button` wins, so the outer
    /// `MediaTransportButtonStyle` was never consulted and every transport control pressed
    /// with no acknowledgement at all. A custom `ButtonStyle` already replaces the default
    /// chrome, so `.plain` was never needed here in the first place.
    func transportButtonStyle() -> some View {
        buttonStyle(MediaTransportButtonStyle())
    }
}
