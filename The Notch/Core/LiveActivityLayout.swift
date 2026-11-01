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
    /// The pinned crypto price, on both shoulders. While a pair is pinned it is the *only* thing
    /// the closed notch shows — a price moving is the one live value that is worth more than
    /// any other, so media, agents and the focus timer all wait in the expanded panel. Only the
    /// HUD, which answers a key the user just pressed and is gone in a second, goes over it.
    case trading
    /// A focus timer with nothing else live: the focus mascot on the left, the countdown on
    /// the right.
    case focus
    /// Focus while media plays: the artwork on the left, the countdown on the right.
    case focusWithMedia
    /// Focus while an agent works — with or without media: the agent's own sprite on the left,
    /// the countdown on the right. Media gives way, because what an agent is doing (or needs)
    /// matters more than what is playing, and the countdown has the other shoulder.
    case focusWithAgents
    /// The end of the first-launch intro: the mascot that just flew down from the band on one
    /// shoulder, and "ready" on the other. It lasts as long as the hint pill does and then the
    /// notch goes back to whatever is actually live — usually nothing, so a bare cutout.
    case welcome

    init(
        hasMedia: Bool,
        hasAgents: Bool,
        hasHUD: Bool,
        hasTrading: Bool = false,
        hasFocus: Bool = false,
        isWelcoming: Bool = false
    ) {
        if hasHUD {
            self = .systemHUD
        } else if isWelcoming {
            self = .welcome
        } else if hasTrading {
            self = .trading
        } else if hasFocus {
            self = hasAgents ? .focusWithAgents : hasMedia ? .focusWithMedia : .focus
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
    /// Whether a shoulder is showing an agent's mascot, so a card's mascot has somewhere to fly
    /// home to.
    var showsAgentMascot: Bool {
        self == .agentsOnly || self == .both || self == .focusWithAgents
    }

    /// Whether the trailing shoulder is the focus countdown.
    var showsFocus: Bool {
        self == .focus || self == .focusWithMedia || self == .focusWithAgents
    }

    var wantsShoulders: Bool {
        self != .idle
    }

}
