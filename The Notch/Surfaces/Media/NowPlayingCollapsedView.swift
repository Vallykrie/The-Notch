import AppKit
import SwiftUI

/// The artwork square, on its own.
///
/// This used to be one `HStack` of artwork *and* title *and* artist, because media owned a
/// single 128pt shoulder and drew its whole collapsed presentation there. It no longer does:
/// media gets one idea per shoulder, and in `.both` — media playing while an agent runs — the
/// artwork is the *only* thing media gets, because the agent sprite has the other shoulder.
/// Splitting the view is what lets the caller ask for half of it.
@MainActor
struct NowPlayingArtworkView: View {
    let status: NowPlayingStatus

    /// Decoding `status.artwork` on every body pass re-parses the same PNG at the poll
    /// interval; the identity is what tells us the bytes actually changed.
    @State private var cachedArtwork: CachedArtwork?

    var body: some View {
        artwork
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .onAppear(perform: updateArtwork)
            .onChange(of: status.artworkIdentity) { _, _ in updateArtwork() }
    }

    @ViewBuilder
    private var artwork: some View {
        if let cachedArtwork,
           cachedArtwork.identity == status.artworkIdentity {
            Image(nsImage: cachedArtwork.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(
                    width: Theme.Metrics.LiveActivity.artworkSize,
                    height: Theme.Metrics.LiveActivity.artworkSize
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: Theme.Metrics.LiveActivity.artworkCornerRadius,
                        style: .continuous
                    )
                )
        } else {
            // Artwork-less tracks still have to occupy exactly the artwork's footprint, or the
            // shoulder's contents shift sideways the moment a player starts supplying images.
            //
            // The stand-in is the *transport mark*, not the waveform: the waveform now has the
            // opposite shoulder to itself, and drawing it on both would make a track with no
            // cover art look like two identical animations either side of the camera.
            PixelGlyphView(
                glyph: status.isPlaying ? .play : .pause,
                side: Theme.Metrics.glyphCollapsedSize
            )
            .foregroundStyle(
                status.isPlaying
                    ? Theme.Colors.Status.playing
                    : Theme.Colors.textSecondary
            )
            .frame(
                width: Theme.Metrics.LiveActivity.artworkSize,
                height: Theme.Metrics.LiveActivity.artworkSize
            )
        }
    }

    private func updateArtwork() {
        cachedArtwork = status.artwork.flatMap(NSImage.init(data:)).map {
            CachedArtwork(identity: status.artworkIdentity, image: $0)
        }
    }

    /// The artwork carries the whole track's label rather than a bare "Album artwork", because
    /// it is the one piece of media that is on screen in *every* active media case; the
    /// metadata opposite it is absent in `.both`.
    private var accessibilityLabel: String {
        let playbackState = status.isPlaying ? "Playing" : "Paused"
        let trackDescription = "\(playbackState) \(status.title) by \(status.artist)"
        guard let progress = status.progress else { return trackDescription }

        return "\(trackDescription), \(Int((progress * 100).rounded())) percent"
    }

    private struct CachedArtwork {
        let identity: String?
        let image: NSImage
    }
}

/// The playing waveform, on the shoulder opposite the artwork.
///
/// This shoulder used to hold the track title over the artist, and that is what forced the
/// collapsed notch to be 92pt a side and 36pt tall — two lines of 8pt text truncated mid-word,
/// which is a wider silhouette bought with something nobody could actually read. The bars say
/// the one thing the artwork opposite them cannot: that the track is playing *right now*.
///
/// It carries no frame or alignment of its own. The shoulder it lands on owns that, because
/// only the shoulder knows which edge is the outer one — see `CollapsedLiveActivityView`.
@MainActor
struct NowPlayingWaveformView: View {
    let status: NowPlayingStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        bars
            .frame(height: Theme.Metrics.LiveActivity.waveformMaxHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.isPlaying ? "Playing" : "Paused")
    }

    @ViewBuilder
    private var bars: some View {
        if status.isPlaying, !reduceMotion {
            TimelineView(.animation) { context in
                row(at: context.date)
            }
        } else {
            // A paused track is still a track, so the bars stay — frozen and dim. The
            // alternative was a pause glyph here, but that would put the *same* mark on this
            // shoulder that an artwork-less track puts on the leading one, and two identical
            // glyphs either side of the camera housing reads as a rendering fault rather than
            // as a paused song.
            row(at: nil)
        }
    }

    /// One `date` of `nil` means "not animating" rather than a second code path, so the paused
    /// and playing states are laid out by the same function and cannot drift apart in width.
    private func row(at date: Date?) -> some View {
        HStack(spacing: Theme.Metrics.LiveActivity.waveformBarSpacing) {
            ForEach(0 ..< Theme.Metrics.LiveActivity.waveformBarCount, id: \.self) { index in
                RoundedRectangle(
                    cornerRadius: Theme.Metrics.LiveActivity.waveformCornerRadius,
                    style: .continuous
                )
                .fill(tint)
                .frame(
                    width: Theme.Metrics.LiveActivity.waveformBarWidth,
                    height: barHeight(at: date, index: index)
                )
            }
        }
        // Bars grow from the floor, not from the middle. A centre-anchored waveform at this
        // scale reads as a blinking dash; anchored to the baseline it reads as a level meter,
        // which is what it is standing in for.
        .frame(
            height: Theme.Metrics.LiveActivity.waveformMaxHeight,
            alignment: .bottom
        )
    }

    private var tint: Color {
        status.isPlaying ? Theme.Colors.Status.playing : Theme.Colors.textSecondary
    }

    /// A paused row is the wave *frozen at phase zero*, not the wave flattened to its minimum.
    ///
    /// Flattening was tried and rendered as five dots along the floor — which at this scale is
    /// indistinguishable from an ellipsis, and an ellipsis is already this app's "thinking"
    /// mark on the agent shoulder. Freezing keeps the silhouette unmistakably a waveform; the
    /// dimmer tint is what says it has stopped.
    private func barHeight(at date: Date?, index: Int) -> CGFloat {
        let date = date ?? Date(timeIntervalSinceReferenceDate: 0)

        let period = Theme.Motion.waveformPeriod
        let timePhase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        let barPhase = Double(index) / Double(Theme.Metrics.LiveActivity.waveformBarCount)
        let wave = (sin((timePhase + barPhase) * .pi * 2) + 1) / 2
        let range = Theme.Metrics.LiveActivity.waveformMaxHeight
            - Theme.Metrics.LiveActivity.waveformMinHeight
        return Theme.Metrics.LiveActivity.waveformMinHeight + range * wave
    }
}
