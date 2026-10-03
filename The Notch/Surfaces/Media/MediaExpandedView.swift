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

    /// The playing state itself, drawn as a skeleton: the same artwork slot (holding the
    /// spinning record), title, subtitle, scrubber and transport row, at the same sizes, so a
    /// track starting fills the panel in rather than rearranging it — the way a loading
    /// skeleton becomes the page it stood in for.
    ///
    /// Everything that needs a track is dimmed exactly as the playing state dims a control it
    /// cannot use. The one live control is play, which opens the player: pressing play is the
    /// thing someone looking at an empty player already reaches for.
    private var emptyState: some View {
        HStack(spacing: Theme.Metrics.MediaPanel.columnSpacing) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(
                    cornerRadius: Theme.Metrics.MediaPanel.artworkCornerRadius,
                    style: .continuous
                )
                .fill(Theme.Colors.textPrimary.opacity(Theme.Metrics.MediaPanel.primaryFillOpacity))

                PixelVinylView(side: Theme.Metrics.MediaPanel.vinylSize)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(
                width: Theme.Metrics.MediaPanel.artworkSize,
                height: Theme.Metrics.MediaPanel.artworkSize
            )

            VStack(alignment: .leading, spacing: Theme.Metrics.MediaPanel.rowSpacing) {
                Text("Nothing playing")
                    .font(Theme.Text.title)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)

                Text(emptySubtitle)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                emptyScrubber
                emptyTransportControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The player play would open: Spotify when it is installed, then Music.
    private var preferredPlayer: (player: NowPlayingStatus.Player, url: URL)? {
        Self.installedPlayers.first
    }

    private var emptySubtitle: String {
        guard let preferredPlayer else { return "Spotify or Music shows up here when it plays." }
        return "Press play to open \(sourceBadgeLabel(for: preferredPlayer.player))."
    }

    /// The scrubber at zero: a bare track between two `0:00`s, the shape it has the instant a
    /// track loads.
    private var emptyScrubber: some View {
        HStack(spacing: Theme.Metrics.MediaPanel.scrubberSpacing) {
            timeLabel(.zero, alignment: .leading)

            RoundedRectangle(cornerRadius: Theme.Metrics.MediaPanel.scrubberCornerRadius)
                .fill(Theme.Colors.textPrimary.opacity(Theme.Metrics.MediaPanel.scrubberTrackOpacity))
                .frame(height: Theme.Metrics.MediaPanel.scrubberHeight)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Metrics.MediaPanel.scrubberHitHeight)

            timeLabel(.zero, alignment: .trailing)
        }
        .accessibilityHidden(true)
    }

    private var emptyTransportControls: some View {
        HStack(spacing: Theme.Metrics.MediaPanel.transportSpacing) {
            decorativeControl(glyph: .heart, label: "Favorite")
            decorativeControl(glyph: .skipBack, label: "Previous track")

            Button {
                guard let preferredPlayer else { return }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: preferredPlayer.url, configuration: configuration)
            } label: {
                ZStack {
                    Circle()
                        .fill(Theme.Colors.textPrimary.opacity(Theme.Metrics.MediaPanel.primaryFillOpacity))
                    PixelGlyphView(glyph: .play, side: Theme.Metrics.MediaPanel.primaryTransportGlyphSize)
                }
                .foregroundStyle(Theme.Colors.textPrimary)
                .frame(
                    width: Theme.Metrics.MediaPanel.primaryTransportHitSize,
                    height: Theme.Metrics.MediaPanel.primaryTransportHitSize
                )
                .contentShape(Circle())
            }
            .disabled(preferredPlayer == nil)
            .opacity(preferredPlayer == nil ? Theme.Metrics.MediaPanel.disabledOpacity : 1)
            .help(preferredPlayer.map { "Open \(sourceBadgeLabel(for: $0.player))" } ?? "")
            .accessibilityLabel(preferredPlayer.map { "Open \(sourceBadgeLabel(for: $0.player))" } ?? "Play")
            .transportButtonStyle()

            decorativeControl(glyph: .skipForward, label: "Next track")
            decorativeControl(glyph: .repeatTrack, label: "Repeat")
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Looked up once. Installing a player while the app runs is rare enough that the
    /// button appearing on next launch is fine, and Launch Services is not free to query on
    /// every render.
    private static let installedPlayers: [(player: NowPlayingStatus.Player, url: URL)] = {
        let candidates: [(NowPlayingStatus.Player, String)] = [
            (.spotify, "com.spotify.client"),
            (.music, "com.apple.Music"),
        ]
        return candidates.compactMap { player, bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
                .map { (player, $0) }
        }
    }()

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

/// A record drawn on the same pixel grid as every other sprite, for the empty media panel.
///
/// It does not rotate. Rotating a grid of square cells by anything but a right angle puts
/// every cell between pixels, and the record turns into a grey smudge. Instead the grid holds
/// still and a glint steps around the grooves an eighth of a turn at a time, which reads as a
/// spinning record the way a marquee reads as moving lights.
private struct PixelVinylView: View {
    let side: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.debugMotionTime) private var debugMotionTime

    var body: some View {
        Group {
            if reduceMotion || debugMotionTime != nil {
                record(step: 1)
            } else {
                TimelineView(.periodic(from: .now, by: Theme.Motion.vinylStep)) { context in
                    record(step: Int(context.date.timeIntervalSinceReferenceDate / Theme.Motion.vinylStep))
                }
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private func record(step: Int) -> some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let grid = Theme.Metrics.MediaPanel.vinylGrid
            let cell = max(1, (min(size.width, size.height) / CGFloat(grid)).rounded(.down))
            let origin = CGPoint(
                x: ((size.width - cell * CGFloat(grid)) / 2).rounded(.down),
                y: ((size.height - cell * CGFloat(grid)) / 2).rounded(.down)
            )
            let gap = cell >= 2 ? Self.cellGap / 2 : 0
            let radius = Double(grid - 1) / 2
            let glint = Double(step % Self.glintSteps) * 2 * .pi / Double(Self.glintSteps)

            for row in 0 ..< grid {
                for column in 0 ..< grid {
                    let dx = Double(column) - radius
                    let dy = Double(row) - radius
                    guard let alpha = Self.alpha(
                        distance: hypot(dx, dy),
                        angle: atan2(dy, dx),
                        glint: glint,
                        radius: radius
                    ) else { continue }

                    context.opacity = alpha
                    context.fill(
                        Path(CGRect(
                            x: origin.x + CGFloat(column) * cell + gap,
                            y: origin.y + CGFloat(row) * cell + gap,
                            width: cell - gap * 2,
                            height: cell - gap * 2
                        )),
                        with: .style(.foreground)
                    )
                }
            }
        }
    }

    /// The brightness of one cell, or `nil` for a cell that is not part of the record.
    private static func alpha(distance d: Double, angle: Double, glint: Double, radius: Double) -> Double? {
        if d > radius + 0.5 || d < spindleRadius { return nil }
        if d <= labelRadius { return labelAlpha }

        let onGroove = grooveFractions.contains { abs(d - radius * $0) < 0.5 }
        if onGroove {
            let offset = abs(remainder(angle - glint, 2 * .pi))
            return offset < .pi / Double(glintSteps) ? glintAlpha : grooveAlpha
        }
        return d > radius - 0.5 ? rimAlpha : discAlpha
    }

    // Opacities of a single white sprite on black. These give the record its depth the way
    // `AgentActivityGlyphView`'s highlight and shadow mixes give the mascot its volume, and they
    // are kept beside the drawing for the same reason those are.
    private static let discAlpha = 0.12
    private static let rimAlpha = 0.28
    private static let grooveAlpha = 0.22
    private static let glintAlpha = 0.7
    private static let labelAlpha = 0.5

    private static let spindleRadius = 0.9
    private static let labelRadius = 3.2
    private static let grooveFractions = [0.5, 0.75]
    private static let glintSteps = 8
    /// Same hairline as the mascot's cells, so the two read as one pixel language.
    private static let cellGap: CGFloat = 0.5
}
