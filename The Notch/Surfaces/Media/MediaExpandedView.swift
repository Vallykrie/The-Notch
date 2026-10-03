import AppKit
import SwiftUI

@MainActor
struct MediaExpandedView: View {
    @ObservedObject var nowPlaying: NowPlayingMonitor
    /// Shared with the collapsed notch, which shows the sung line while lyrics are on.
    @ObservedObject var lyrics: LyricsController

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

    /// The playing panel and its lyrics mode are one layout, not two.
    ///
    /// The scrubber and the transport buttons are the *same views* in both: what changes is
    /// the container around them — stacked under the title, or laid in one strip along the
    /// bottom — and their size. Because their identity survives the switch, SwiftUI moves them
    /// rather than swapping them, so turning lyrics on reads as the controls sliding down and
    /// shrinking out of the way while the words take their place. The title rows and the
    /// lyrics are the only things that genuinely appear and disappear, and they cross-fade.
    private var activeContent: some View {
        let stage = lyrics.isEnabled
        return HStack(spacing: Theme.Metrics.MediaPanel.columnSpacing) {
            artwork

            VStack(
                alignment: .leading,
                spacing: stage ? Theme.Metrics.MediaPanel.stageSpacing : Theme.Metrics.MediaPanel.rowSpacing
            ) {
                if stage {
                    Text("\(nowPlaying.status.title) · \(nowPlaying.status.artist)")
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .transition(.opacity)

                    lyricsBody
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .transition(.opacity)
                } else {
                    Text(nowPlaying.status.title)
                        .font(Theme.Text.title)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .transition(.opacity)

                    Text(nowPlaying.status.artist)
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .transition(.opacity)
                }

                controls(stage: stage)
            }
            .frame(maxWidth: .infinity, maxHeight: stage ? .infinity : nil, alignment: .topLeading)
        }
    }

    /// Scrubber over buttons, or scrubber beside buttons. `AnyLayout` keeps both children's
    /// identity across the switch, which is what makes the move animatable.
    private func controls(stage: Bool) -> some View {
        let layout = stage
            ? AnyLayout(HStackLayout(spacing: Theme.Metrics.MediaPanel.miniSpacing))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Metrics.MediaPanel.rowSpacing))
        return layout {
            scrubber
            transportControls(stage: stage)
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

    /// The transport row, at full size under the scrubber or folded beside it. The favourite
    /// mark only exists at full size; it is decorative, and the strip has no room for it.
    private func transportControls(stage: Bool) -> some View {
        HStack(spacing: stage ? Theme.Metrics.MediaPanel.miniSpacing : Theme.Metrics.MediaPanel.transportSpacing) {
            if !stage {
                decorativeControl(glyph: .heart, label: "Favorite")
                    .transition(.opacity)
            }

            transportButton(.skipBack, label: "Previous track", stage: stage) {
                nowPlaying.previousTrack()
            }

            playPauseButton(stage: stage)

            transportButton(.skipForward, label: "Next track", stage: stage) {
                nowPlaying.nextTrack()
            }

            transportButton(
                .lyrics,
                label: stage ? "Hide lyrics" : "Show lyrics",
                stage: stage,
                tint: stage ? Theme.Colors.Status.playing : Theme.Colors.textSecondary,
                action: toggleLyrics
            )
        }
        .frame(maxWidth: stage ? nil : .infinity, alignment: .center)
    }

    /// The glyph is always drawn at full size and *scaled* into the strip. Pixel glyphs are
    /// rendered for a given side and do not animate between sizes; a scale does, so the
    /// buttons shrink on the same spring that moves them.
    private func transportButton(
        _ glyph: PixelGlyph,
        label: String,
        stage: Bool,
        tint: Color = Theme.Colors.textSecondary,
        action: @escaping () -> Void
    ) -> some View {
        let metrics = Theme.Metrics.MediaPanel.self
        let hit = stage ? metrics.miniHitSize : metrics.transportHitSize
        return Button(action: action) {
            PixelGlyphView(glyph: glyph, side: metrics.transportGlyphSize)
                .scaleEffect(stage ? metrics.miniGlyphSize / metrics.transportGlyphSize : 1)
                .foregroundStyle(stage && tint == Theme.Colors.textSecondary ? Theme.Colors.textPrimary : tint)
                .frame(width: hit, height: hit)
                .contentShape(Rectangle())
        }
        .help(label)
        .accessibilityLabel(label)
        .transportButtonStyle()
    }

    /// The round play button. In the strip its disc fades out and its glyph shrinks to the
    /// size of the others, so the four buttons read as one row.
    private func playPauseButton(stage: Bool) -> some View {
        let metrics = Theme.Metrics.MediaPanel.self
        let hit = stage ? metrics.miniHitSize : metrics.primaryTransportHitSize
        return Button {
            nowPlaying.playPause()
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.Colors.textPrimary.opacity(metrics.primaryFillOpacity))
                    .opacity(stage ? 0 : 1)

                Group {
                    if nowPlaying.status.isPlaying {
                        PixelGlyphView(glyph: .pause, side: metrics.primaryTransportGlyphSize)
                            .transition(.opacity)
                    } else {
                        PixelGlyphView(glyph: .play, side: metrics.primaryTransportGlyphSize)
                            .transition(.opacity)
                    }
                }
                .scaleEffect(stage ? metrics.miniGlyphSize / metrics.primaryTransportGlyphSize : 1)
            }
            .foregroundStyle(Theme.Colors.textPrimary)
            .frame(width: hit, height: hit)
            .contentShape(Circle())
            .animation(Theme.Motion.content, value: nowPlaying.status.isPlaying)
        }
        .accessibilityLabel(nowPlaying.status.isPlaying ? "Pause" : "Play")
        .transportButtonStyle()
    }

    // MARK: Lyrics

    private func toggleLyrics() {
        withAnimation(Theme.Motion.lyricsMode) { lyrics.isEnabled.toggle() }
    }

    @ViewBuilder
    private var lyricsBody: some View {
        switch lyrics.lookup {
        case nil:
            lyricsMessage("Looking up lyrics…")
        case .notFound:
            lyricsMessage("No lyrics found for this track.")
        case .failed:
            lyricsMessage("Couldn't reach the lyrics service.")
        case let .found(found) where found.isSynced:
            syncedLyrics(found)
        case let .found(found) where found.isInstrumental && found.plain.isEmpty:
            lyricsMessage("♪ Instrumental")
        case let .found(found):
            plainLyrics(found)
        }
    }

    private func lyricsMessage(_ text: String) -> some View {
        Text(text)
            .font(Theme.Text.body)
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Re-reads the position a few times a second while playing — only to notice the next
    /// line starting; nothing moves between line changes — and stops when the track pauses.
    private func syncedLyrics(_ found: Lyrics) -> some View {
        TimelineView(.animation(
            minimumInterval: Theme.Metrics.MediaPanel.lyricsTick,
            paused: !nowPlaying.status.isPlaying
        )) { context in
            LyricsReel(lyrics: found, focus: found.lineIndex(at: lyrics.position(at: context.date)) ?? -1)
        }
    }

    /// Lyrics without timestamps cannot follow the song, so they are shown as text to read,
    /// scrolled by hand, with a note saying why they do not move.
    private func plainLyrics(_ found: Lyrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Not synced to the song")
                    .font(Theme.Text.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
                ForEach(Array(found.plain.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
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

                playerLinks

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

    /// The artist row's slot, holding a way to each player instead: `Open ↗ Spotify ↗ Apple
    /// Music`. Only the players installed on this Mac; a link to an app that is not here would
    /// do nothing.
    @ViewBuilder
    private var playerLinks: some View {
        let players = Self.installedPlayers
        HStack(spacing: Theme.Metrics.collapsedContentSpacing * 2) {
            if players.isEmpty {
                Text("Spotify or Apple Music shows up here when it plays.")
                    .foregroundStyle(Theme.Colors.textSecondary)
            } else {
                Text("Open")
                    .foregroundStyle(Theme.Colors.textTertiary)
                ForEach(players, id: \.player) { entry in
                    Button {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        NSWorkspace.shared.openApplication(at: entry.url, configuration: configuration)
                    } label: {
                        HStack(spacing: 4) {
                            PixelGlyphView(glyph: .openWindow, side: Theme.Metrics.glyphCollapsedSize)
                                .foregroundStyle(sourceBadgeTint(for: entry.player))
                            Text(sourceBadgeLabel(for: entry.player))
                                .foregroundStyle(Theme.Colors.textPrimary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(sourceBadgeLabel(for: entry.player))")
                }
            }
        }
        .font(Theme.Text.body)
        .lineLimit(1)
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
            "Apple Music"
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

/// The synced lyrics as a reel: every line in a column, the sung one centred in white, the
/// rest scaled down and fading with distance from it.
///
/// Lines wrap onto a second row rather than truncating, so they are not one height. The
/// placement is a `Layout` rather than a fixed pitch for that reason: it measures each line at
/// the column's width and offsets the column so the sung line's own centre is the reel's
/// centre. Being a layout, it is also synchronous — the first frame is already placed, which a
/// preference-and-state round trip is not (and `ImageRenderer` never runs the second pass).
///
/// Lines keep their identity across steps, so when the sung line changes SwiftUI moves the
/// same views: the column glides up, the new line grows as the old one shrinks. All of it
/// rides the one `lyricsAdvance` spring, keyed to the line index.
struct LyricsReel: View {
    let lyrics: Lyrics
    /// The sung line, or -1 during the intro, when a note holds the centre.
    let focus: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Metrics = Theme.Metrics.MediaPanel

    var body: some View {
        ReelLayout(focus: focus + 1, spacing: Metrics.lyricsLineSpacing) {
            ForEach(-1 ..< lyrics.synced.count, id: \.self) { index in
                line(index)
            }
        }
        .clipped()
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: Metrics.lyricsEdgeFade)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: Metrics.lyricsEdgeFade)
            }
        }
        .animation(reduceMotion ? nil : Theme.Motion.lyricsAdvance, value: focus)
    }

    private func text(_ index: Int) -> String {
        guard lyrics.synced.indices.contains(index) else { return "♪" }
        let text = lyrics.synced[index].text
        return text.isEmpty ? "♪" : text
    }

    private func line(_ index: Int) -> some View {
        let distance = abs(index - focus)
        let fades = Metrics.lyricsFadeByDistance
        let isSung = distance == 0
        return Text(text(index))
            .font(Theme.Text.title)
            .foregroundStyle(isSung ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(isSung ? 1 : Metrics.lyricsNeighbourScale, anchor: .leading)
            .opacity(fades[min(distance, fades.count - 1)])
    }
}

/// Stacks its children top to bottom at their wrapped heights, then shifts the whole stack so
/// the `focus` child is centred in the bounds. Children outside the bounds are still placed —
/// that is what lets them glide in rather than appear.
struct ReelLayout: Layout {
    var focus: Int
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = ProposedViewSize(width: bounds.width, height: nil)
        let heights = subviews.map { $0.sizeThatFits(width).height }
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for height in heights {
            tops.append(y)
            y += height + spacing
        }
        let focused = min(max(focus, 0), subviews.count - 1)
        let offset = bounds.height / 2 - (tops[focused] + heights[focused] / 2)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + tops[index] + offset),
                proposal: ProposedViewSize(width: bounds.width, height: heights[index])
            )
        }
    }
}
