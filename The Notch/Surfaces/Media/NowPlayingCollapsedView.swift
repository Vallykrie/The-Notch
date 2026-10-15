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
/// The bars take the cover's colour (`ArtworkAccent`), the way the Dynamic Island's do, so the
/// two shoulders read as one track rather than as artwork plus an app-coloured meter.
///
/// It carries no frame or alignment of its own. The shoulder it lands on owns that, because
/// only the shoulder knows which edge is the outer one — see `CollapsedLiveActivityView`.
@MainActor
struct NowPlayingWaveformView: View {
    let status: NowPlayingStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The cover's colour, keyed by the artwork it came from so a stale result from the
    /// previous track can never land on the next one.
    @State private var accent: (identity: String?, color: Color)?

    var body: some View {
        // One timeline for both states. It pauses rather than being swapped out, so pausing is
        // the bars *settling* (energy springs to zero over a frozen clock) instead of a view
        // being replaced by a different one mid-frame.
        TimelineView(.animation(minimumInterval: nil, paused: !isAnimating)) { context in
            WaveformBars(date: context.date, energy: isAnimating ? 1 : 0, tint: tint)
        }
        .frame(height: Theme.Metrics.LiveActivity.waveformMaxHeight)
        .animation(Theme.Motion.waveformEnergy, value: isAnimating)
        .animation(Theme.Motion.waveformTint, value: tint)
        .task(id: status.artworkIdentity) { await updateAccent() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.isPlaying ? "Playing" : "Paused")
    }

    private var isAnimating: Bool {
        status.isPlaying && !reduceMotion
    }

    private var tint: Color {
        guard status.isPlaying else { return Theme.Colors.textSecondary }
        guard let accent, accent.identity == status.artworkIdentity else {
            return Theme.Colors.Status.playing
        }
        return accent.color
    }

    private func updateAccent() async {
        guard let artwork = status.artwork else {
            accent = nil
            return
        }
        let identity = status.artworkIdentity
        let extracted = await Task.detached(priority: .utility) {
            ArtworkAccent.extract(from: artwork)
        }.value
        guard !Task.isCancelled else { return }
        accent = extracted.map {
            (identity, Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue))
        }
    }
}

/// The bars themselves, for one instant and one energy.
///
/// `energy` is animatable, which is the whole reason this is its own view: SwiftUI interpolates
/// it between 0 (paused) and 1 (playing), and every frame in between is a real mix of the live
/// wave and the resting silhouette, so play and pause glide instead of cutting.
private struct WaveformBars: View, Animatable {
    let date: Date
    var energy: Double
    let tint: Color

    nonisolated var animatableData: Double {
        get { energy }
        set { energy = newValue }
    }

    private typealias Metrics = Theme.Metrics.LiveActivity

    var body: some View {
        HStack(spacing: Metrics.waveformBarSpacing) {
            ForEach(0 ..< Metrics.waveformBarCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: Metrics.waveformCornerRadius, style: .continuous)
                    .fill(tint)
                    .frame(width: Metrics.waveformBarWidth, height: height(of: index))
            }
        }
        // Bars grow from the floor, not from the middle. A centre-anchored waveform at this
        // scale reads as a blinking dash; anchored to the baseline it reads as a level meter,
        // which is what it is standing in for.
        .frame(height: Metrics.waveformMaxHeight, alignment: .bottom)
    }

    private func height(of index: Int) -> CGFloat {
        let level = Self.restingLevel(index) * (1 - energy) + liveLevel(index) * energy
        return Metrics.waveformMinHeight + (Metrics.waveformMaxHeight - Metrics.waveformMinHeight) * level
    }

    /// The paused silhouette: a fixed, uneven skyline.
    ///
    /// Not the wave flattened to its minimum — that rendered as five dots along the floor,
    /// indistinguishable from an ellipsis, which is already this app's "thinking" mark on the
    /// agent shoulder. And not the wave frozen wherever it happened to stop, which made every
    /// pause look different. One deliberate shape keeps it unmistakably a waveform; the dim
    /// tint is what says it has stopped.
    private static func restingLevel(_ index: Int) -> Double {
        let skyline: [Double] = [0.35, 0.7, 0.5, 0.85, 0.4]
        return skyline[index % skyline.count]
    }

    /// The live wave: each bar its own sum of three sines at incommensurate rates.
    ///
    /// The old wave was one sine travelling along the row, which made the bars a single object
    /// sliding sideways — readable as "animating", never as "music". Giving each bar its own
    /// rates and phases makes the row churn the way a level meter does, and because the rates
    /// share no common period it never visibly loops. The envelope lets the middle bars reach
    /// higher than the outer ones, so the row has a centre of mass instead of five equals.
    private func liveLevel(_ index: Int) -> Double {
        let rates: [(Double, Double, Double)] = [
            (1.00, 2.31, 3.70),
            (1.37, 2.83, 4.13),
            (0.91, 2.05, 3.29),
            (1.21, 2.62, 4.47),
            (1.09, 1.87, 3.91),
        ]
        let phases: [(Double, Double, Double)] = [
            (0.00, 1.90, 4.10),
            (2.40, 0.70, 3.30),
            (4.70, 2.80, 0.50),
            (1.30, 5.20, 2.20),
            (3.60, 3.90, 5.60),
        ]
        let envelope: [Double] = [0.72, 0.9, 1.0, 0.9, 0.72]

        let slot = index % rates.count
        let time = date.timeIntervalSinceReferenceDate * 2 * .pi / Theme.Motion.waveformPeriod
        let mix = 0.55 * sin(time * rates[slot].0 + phases[slot].0)
            + 0.30 * sin(time * rates[slot].1 + phases[slot].1)
            + 0.15 * sin(time * rates[slot].2 + phases[slot].2)
        // `mix` spans -1…1. Never let a playing bar fall all the way to the floor: a bar at
        // its minimum is a dot, and a row that keeps dropping to dots flickers.
        let normalised = (mix + 1) / 2
        return envelope[slot % envelope.count] * (0.18 + 0.82 * normalised)
    }
}
