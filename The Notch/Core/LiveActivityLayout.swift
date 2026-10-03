import Foundation

/// What the collapsed notch is showing, and therefore how wide and how tall it is.
///
/// This is the single source of truth for collapsed geometry. `NotchCoordinator.collapsedSize`
/// and `CollapsedLiveActivityView` both derive from it and nothing else may compute shoulder
/// geometry independently — when they disagreed, content was measured drawing up to 45pt
/// underneath the physical camera housing.
///
/// The collapsed notch answers *what is live*. The expanded panel answers *what is happening*.
/// That division is why each case below puts exactly **one** idea on each shoulder: the
/// previous layout drew media's artwork, title and artist on one side and three agent sprites
/// plus a status word on the other, which needed a ~445pt silhouette to hold and read as a bar
/// lying across the menu bar rather than as the hardware notch.
enum LiveActivityLayout: Equatable {
    /// Nothing is live. The silhouette is exactly the hardware cutout — no shoulders at all.
    case idle
    /// Artwork on the left, the playing waveform on the right.
    case mediaOnly
    /// One status sprite on the left, the live session count on the right.
    case agentsOnly
    /// Artwork on the left, one status sprite on the right. Neither surface gets text: with
    /// both live, the pair of glyphs is the whole message.
    case both
    /// A brightness or volume level, which outranks everything above for as long as it lasts.
    case systemHUD
    case trading
    /// The sung line, split across the camera housing. Lyrics on, synced lyrics found, and the
    /// track playing — see `LyricsController.showsOnNotch`.
    ///
    /// The only case whose width is not a constant: it carries the width the current line needs
    /// (see `LyricsCollapsedView.shoulderWidth(for:)`), so a short line does not sit in a slab
    /// of black. Carried *in* the case so the silhouette and the drawn shoulders still read the
    /// same one value — the rule this whole type exists to enforce.
    case lyrics(shoulderWidth: CGFloat)

    var isLyrics: Bool {
        if case .lyrics = self { return true }
        return false
    }

    init(
        hasMedia: Bool,
        hasAgents: Bool,
        hasHUD: Bool,
        hasTrading: Bool = false,
        agentNeedsAttention: Bool = false,
        hasLyrics: Bool = false,
        lyricsShoulderWidth: CGFloat = Theme.Metrics.LiveActivity.lyricsShoulderWidth
    ) {
        if hasHUD {
            self = .systemHUD
        } else if hasLyrics && !agentNeedsAttention {
            // Above trading: lyrics are on because the user turned them on, for this song.
            // An agent that needs the user still wins — it is stalled until they answer.
            self = .lyrics(shoulderWidth: lyricsShoulderWidth)
        } else if hasTrading && agentNeedsAttention {
            self = .agentsOnly
        } else if hasTrading {
            self = .trading
        } else {
            switch (hasMedia, hasAgents) {
            case (false, false): self = .idle
            case (true, false): self = .mediaOnly
            case (false, true): self = .agentsOnly
            case (true, true): self = .both
            }
        }
    }

    /// Whether the resting silhouette widens past the hardware cutout.
    ///
    /// Shoulders are *earned*. An always-widened silhouette was tried so the shell could show a
    /// battery glyph at rest, and it was a black bar covering the menu bar all day that
    /// swallowed clicks across its whole width. At rest the notch must be indistinguishable
    /// from the hardware.
    var wantsShoulders: Bool {
        self != .idle
    }

}
