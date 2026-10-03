import SwiftUI

/// The resting notch when something is live: one idea per shoulder, with the camera housing as
/// the gap between them.
///
/// Every shoulder's *content* is chosen by `LiveActivityLayout` and by nothing else, because
/// `NotchCoordinator.collapsedSize` sizes the silhouette from that same value. When the two
/// were derived separately — the coordinator from "is media active", the view from its own
/// re-reading of the monitors — they disagreed, and a disagreement here is measured in points
/// of content drawn underneath the physical camera.
///
/// | layout       | leading           | trailing            |
/// |--------------|-------------------|---------------------|
/// | `.idle`      | —                 | —                   |
/// | `.mediaOnly` | artwork           | playing waveform    |
/// | `.agentsOnly`| one status sprite | live session count  |
/// | `.both`      | artwork           | one status sprite   |
/// | `.systemHUD` | icon and label    | level bar           |
/// | `.lyrics`    | first half of the sung line | second half |
///
/// Each surface previously rendered its *full* collapsed presentation on its shoulder — media
/// drew artwork and title and artist, agents drew three sprites and a status word — which
/// needed 128pt a side and produced a ~445pt black bar lying across the menu bar. The collapsed
/// notch is a glance that answers *what is live*; the expanded panel answers what is happening.
@MainActor
struct CollapsedLiveActivityView: View {
    let layout: LiveActivityLayout
    @ObservedObject var nowPlaying: NowPlayingMonitor
    @ObservedObject var store: AgentSessionStore
    @ObservedObject var trading: TradingStore
    @ObservedObject var lyrics: LyricsController
    let hudEvent: SystemHUDEvent?

    @Environment(\.notchLayout) private var notchLayout

    var body: some View {
        HStack(spacing: .zero) {
            leadingShoulder
                .padding(.leading, layout.horizontalPadding)
                .padding(.trailing, Theme.Metrics.shoulderInset)
                .frame(width: shoulderWidth, alignment: .leading)
                .clipped()

            housingReservation

            trailingShoulder
                .padding(.trailing, layout.horizontalPadding)
                .padding(.leading, Theme.Metrics.shoulderInset)
                .frame(width: shoulderWidth, alignment: .trailing)
                .clipped()
        }
        .foregroundStyle(Theme.Colors.textPrimary)
        .padding(.vertical, Theme.Metrics.LiveActivity.mediaVerticalPadding)
        .frame(maxHeight: .infinity)
        // One spring, driven by the one enum. This used to be two `.animation` modifiers on two
        // different booleans — one per shoulder — so a HUD arriving over a playing track, which
        // changes both shoulders at once, ran as two independent fades. `layout` changing is a
        // single gesture and animates as one; `sessions.count` is the only other value that
        // rewrites a shoulder without changing the case, and it rides the same token so the
        // count's `.numericText()` transition has a curve to run on.
        .animation(Theme.Motion.shoulders, value: layout)
        .animation(Theme.Motion.shoulders, value: store.sessions.count)
    }

    /// Each shoulder is pinned to exactly the width the coordinator built the silhouette from,
    /// and it is *not* `maxWidth: .infinity`.
    ///
    /// It was, and that put drawn content underneath the camera housing — measured at up to
    /// 45pt of overlap in a rendered frame. An `HStack` does not split flexible space evenly;
    /// it distributes by each child's ideal size and flexibility. So whenever one shoulder was
    /// empty — no media playing, or no agents running, both ordinary states — the other was
    /// free to grow into its share, which slid the fixed housing reservation off the pill's
    /// midpoint while the real hardware stayed centred on the display.
    ///
    /// A fixed width makes the arrangement deterministic regardless of what either side holds,
    /// which is the same reason `NotchCoordinator.collapsedSize` insists the shoulders stay
    /// symmetric. The padding lives *inside* this frame on purpose: the silhouette is exactly
    /// `shoulderWidth + housing + shoulderWidth`, so a shoulder that padded itself from the
    /// outside would push the total past the silhouette and reintroduce the overlap from the
    /// other direction.
    ///
    /// The width is asked of `layout` and not of `Theme` directly, because the HUD's shoulder
    /// is deliberately wider than a live activity's and `NotchCoordinator.collapsedSize` sizes
    /// the silhouette from that same property. Reading a different token here is exactly the
    /// disagreement the whole file is arranged to prevent.
    private var shoulderWidth: CGFloat {
        layout.shoulderWidth
    }

    /// The camera housing: a real reservation, not a spacer and not padding. Drawn content
    /// crossing the hardware is the worst outcome available to this view. Displays without a
    /// notch have no hardware to avoid, so the faux pill simply holds its two shoulders apart.
    @ViewBuilder
    private var housingReservation: some View {
        if notchLayout.hasPhysicalNotch || layout == .trading || layout.isLyrics {
            Color.clear
                .frame(width: layout.housingWidth(physicalWidth: notchLayout.physicalNotchSize.width, hasPhysicalNotch: notchLayout.hasPhysicalNotch))
        } else {
            Spacer(minLength: .zero)
        }
    }

    /// The `Color.clear` fallbacks below are load-bearing and must not be dropped back to an
    /// implicit empty branch. `EmptyView` is special-cased by SwiftUI to produce *no layout node
    /// at all*, so `.frame(width:)` on it does nothing and the shoulder collapses to zero. The
    /// `HStack` then measured 317pt inside a 445pt silhouette and centred itself, sliding the
    /// whole arrangement 64pt sideways — which put the *populated* shoulder underneath the
    /// camera housing whenever the other one was idle. `Color.clear` is a real, flexible view
    /// and holds the shoulder open.
    @ViewBuilder
    private var leadingShoulder: some View {
        switch layout {
        case .trading:
            TradingCollapsedView(store: trading, leading: true)
        case .lyrics:
            LyricsCollapsedView(lyrics: lyrics, half: .leading)
                .transition(.opacity)
        case .mediaOnly, .both:
            NowPlayingArtworkView(status: nowPlaying.status)
                .transition(.opacity)
        case .agentsOnly:
            AgentsCollapsedView(store: store)
                .transition(.opacity)
        case .systemHUD:
            hudShoulder { SystemHUDLeadingView(event: $0) }
        case .idle:
            Color.clear
        }
    }

    /// The trailing shoulder is the one that changes identity between cases: media's metadata,
    /// the agent count, the agent sprite, or the HUD's level bar. See `leadingShoulder` for why
    /// the idle branch is `Color.clear`.
    @ViewBuilder
    private var trailingShoulder: some View {
        switch layout {
        case .trading:
            TradingCollapsedView(store: trading, leading: false)
        case .lyrics:
            LyricsCollapsedView(lyrics: lyrics, half: .trailing)
                .transition(.opacity)
        case .mediaOnly:
            // The waveform, not the title and artist that used to live here. Two lines of 8pt
            // text truncated mid-word are not information — they are the reason the silhouette
            // had to be 92pt a shoulder and 36pt tall. The animated bars say the one thing the
            // artwork opposite them cannot: that the track is *playing*, right now. Everything
            // nameable about it is one hover away in the expanded panel.
            NowPlayingWaveformView(status: nowPlaying.status)
                .transition(.opacity)
        case .agentsOnly:
            AgentsCountCollapsedView(store: store)
                .transition(.opacity)
        case .both:
            // Media has the artwork opposite, so agents get the sprite and no text. With both
            // live, the pair of glyphs is the whole message — a title squeezed in beside them
            // is what made this silhouette 445pt wide.
            AgentsCollapsedView(store: store)
                .transition(.opacity)
        case .systemHUD:
            hudShoulder { SystemHUDTrailingView(event: $0) }
        case .idle:
            Color.clear
        }
    }

    /// `.systemHUD` is only ever derived from a non-nil event, but the layout and the event
    /// arrive as two separate values and there is one frame either side of a change where they
    /// could disagree. Falling back to `Color.clear` keeps that frame a blank shoulder rather
    /// than a collapsed one.
    @ViewBuilder
    private func hudShoulder(
        @ViewBuilder _ content: (SystemHUDEvent) -> some View
    ) -> some View {
        if let hudEvent {
            content(hudEvent)
                .transition(.opacity)
        } else {
            Color.clear
        }
    }
}
