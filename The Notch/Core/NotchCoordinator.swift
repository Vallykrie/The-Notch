import Combine
import SwiftUI

@MainActor
final class NotchCoordinator: ObservableObject {
    @Published private(set) var state: NotchState
    @Published private(set) var currentSurface: NotchSurface
    /// The hardware notch, or the faux pill on displays that have none. This is the silhouette
    /// at rest — never the size content is laid out in.
    @Published private(set) var physicalNotchSize: CGSize
    @Published private(set) var hasPhysicalNotch: Bool
    /// Whether a media player is currently playing or paused.
    @Published var hasMediaActivity: Bool = false {
        didSet {
            guard hasMediaActivity != oldValue else { return }
            stateDidChange?(state)
        }
    }

    /// Whether any agent session is alive. Deliberately *not* "is an approval pending":
    /// gating the agent surface on approvals meant a working, thinking or compacting agent —
    /// the overwhelmingly normal case — never appeared in the notch at all, which is the whole
    /// feature the app exists for.
    @Published var hasAgentActivity: Bool = false {
        didSet {
            guard hasAgentActivity != oldValue else { return }
            stateDidChange?(state)
        }
    }

    /// Whether a brightness or volume readout is on screen. It outranks both live activities
    /// and earns shoulders on its own — the user pressed a key and is owed an answer even if
    /// nothing else is running.
    @Published var hasSystemHUD: Bool = false {
        didSet {
            guard hasSystemHUD != oldValue else { return }
            stateDidChange?(state)
        }
    }

    @Published var hasTradingActivity = false {
        didSet { if oldValue != hasTradingActivity { stateDidChange?(state) } }
    }
    /// The intro's closing moment, while its mascot sits on the shoulder — see
    /// `LiveActivityLayout.welcome`.
    @Published var isWelcoming = false {
        didSet { if oldValue != isWelcoming { stateDidChange?(state) } }
    }
    @Published var agentNeedsAttention = false {
        didSet { if oldValue != agentNeedsAttention { stateDidChange?(state) } }
    }

    /// Holds the panel open regardless of where the pointer is.
    ///
    /// Set while the settings surface is showing, and for nothing else. Settings is the one
    /// surface the user *operates* rather than reads, and hover-to-open/leave-to-close is
    /// actively hostile to that: flipping four switches means keeping the cursor inside a strip
    /// at the top of the screen for the whole time, and one overshoot past the grace ring closes
    /// the panel mid-task. Every other surface is a glance and collapses on exit as before.
    ///
    /// Releasing the pin is itself a change the hosting view has to see — the pointer may
    /// already be outside, in which case nothing else will ever tell it to collapse — so this
    /// announces through `stateDidChange` like the geometry-affecting properties above.
    @Published private(set) var isPinnedOpen: Bool = false

    /// The first-launch intro is playing. The expanded silhouette is the wider onboarding band
    /// while this is set, and the panel is pinned open so the pointer leaving cannot cut the
    /// consent question off half-asked.
    @Published private(set) var isOnboarding = false

    /// The most recent thing that wants the user's eye. `NotchRootView` turns each cue into a
    /// gesture — a pop, a drip, a breath — and the id is what makes two identical cues in a row
    /// two gestures rather than one.
    @Published private(set) var attentionCue: AttentionCue?

    /// Set to play the first-launch intro. A fresh id each time, so "replay" from settings works
    /// even after the intro has already played once this launch.
    @Published private(set) var onboardingRequest: UUID?


    /// Where the pointer is, in the panel's own top-left-origin space, and whether it is over
    /// the live region. Written by the hosting view on every pointer move; deliberately not
    /// published, so a moving mouse never re-renders the notch. The lyric pill and the
    /// takeover choreography read them when they need to.
    var pointerLocation: CGPoint?
    var pointerIsInsideLiveRegion = false

    var stateDidChange: ((NotchState) -> Void)?

    init(
        state: NotchState = .collapsed,
        currentSurface: NotchSurface = .media,
        collapsedSize: CGSize? = nil,
        hasPhysicalNotch: Bool = false
    ) {
        self.state = state
        self.currentSurface = currentSurface
        self.physicalNotchSize = collapsedSize ?? Theme.Metrics.fauxNotchSize
        self.hasPhysicalNotch = hasPhysicalNotch
    }

    /// What the collapsed notch is showing. Everything about collapsed geometry derives from
    /// this one value, so the coordinator and the view can never disagree about where the
    /// housing sits.
    ///
    /// Note this does not consult `currentSurface`. Collapsed, media and agents can both be on
    /// screen at once on opposite shoulders — the tab only selects what the *expanded* panel
    /// elaborates, so either activity alone earns the shoulders.
    var liveActivityLayout: LiveActivityLayout {
        LiveActivityLayout(
            hasMedia: hasMediaActivity,
            hasAgents: hasAgentActivity,
            hasHUD: hasSystemHUD,
            hasTrading: hasTradingActivity,
            agentNeedsAttention: agentNeedsAttention,
            isWelcoming: isWelcoming
        )
    }

    var wantsShoulders: Bool {
        liveActivityLayout.wantsShoulders
    }

    var collapsedSize: CGSize {
        let layout = liveActivityLayout
        guard layout.wantsShoulders else { return physicalNotchSize }

        // Symmetric, and it has to stay symmetric. Asymmetric shoulders were tried and
        // abandoned: the aperture and the AppKit hit region are both centred on the
        // silhouette's midpoint, so unequal sides push the drawn shape off-centre from the
        // real camera housing, and the only way back is to offset the whole silhouette against
        // the display. A visibly lopsided notch is a worse defect than an underused shoulder.
        //
        // The height never grows. It used to, for the one case that carried two lines of text
        // (title over artist); that text is gone and every collapsed case is now a glyph-sized
        // mark that fits the hardware notch's own height. So the notch only ever grows
        // sideways, which is much quieter in peripheral vision than a shape that also drops
        // below the menu bar — that reads as a panel opening rather than as hardware.
        //
        // The width is per-layout: the live activities are compact and the HUD is wider. See
        // `LiveActivityLayout.shoulderWidth`.
        return CGSize(
            width: layout.housingWidth(physicalWidth: physicalNotchSize.width, hasPhysicalNotch: hasPhysicalNotch) + layout.shoulderWidth * 2,
            height: physicalNotchSize.height
        )
    }

    var layout: NotchLayout {
        NotchLayout(
            hasPhysicalNotch: hasPhysicalNotch,
            physicalNotchSize: physicalNotchSize
        )
    }

    /// Debug-only: pins the aperture to an arbitrary size so a mid-animation frame can be
    /// rendered offscreen. Never set outside `FrameDump`.
    var debugApertureOverride: CGSize?

    var notchSize: CGSize {
        if let debugApertureOverride { return debugApertureOverride }
        switch state {
        case .collapsed:
            return collapsedSize
        case .expanded:
            return expandedSize
        }
    }

    /// The expanded silhouette: the onboarding band during the intro, the panel otherwise.
    var expandedSize: CGSize {
        isOnboarding ? Theme.Metrics.onboardingBandSize : Theme.Metrics.expandedNotchSize
    }

    var topCornerRadius: CGFloat {
        switch state {
        case .collapsed:
            Theme.Metrics.collapsedTopCornerRadius
        case .expanded:
            isOnboarding ? Theme.Metrics.onboardingTopCornerRadius : Theme.Metrics.expandedTopCornerRadius
        }
    }

    var bottomCornerRadius: CGFloat {
        switch state {
        case .collapsed:
            Theme.Metrics.collapsedBottomCornerRadius
        case .expanded:
            isOnboarding ? Theme.Metrics.onboardingBottomCornerRadius : Theme.Metrics.expandedBottomCornerRadius
        }
    }

    func raiseAttention(_ kind: AttentionCue.Kind) {
        attentionCue = AttentionCue(kind: kind)
    }

    func requestOnboarding() {
        onboardingRequest = UUID()
    }

    func setOnboarding(_ onboarding: Bool) {
        guard isOnboarding != onboarding else { return }
        isOnboarding = onboarding
        isPinnedOpen = onboarding
        stateDidChange?(state)
    }

    func setState(_ newState: NotchState) {
        guard state != newState else { return }
        state = newState
        stateDidChange?(newState)
    }

    func setPinnedOpen(_ pinned: Bool) {
        guard isPinnedOpen != pinned else { return }
        isPinnedOpen = pinned
        stateDidChange?(state)
    }

    func show(_ surface: NotchSurface) {
        guard currentSurface != surface else { return }
        currentSurface = surface
        // The surface decides whether the resting silhouette has shoulders, so the hit region
        // and tracking area are stale until they are rebuilt.
        stateDidChange?(state)
    }

    func updateGeometry(collapsedSize: CGSize, hasPhysicalNotch: Bool) {
        physicalNotchSize = collapsedSize
        self.hasPhysicalNotch = hasPhysicalNotch
    }
}

/// Something an agent did that the notch should make the user notice.
struct AttentionCue: Equatable {
    enum Kind: Equatable {
        /// A permission prompt arrived: the notch pops open.
        case approval
        /// A question arrived: a drop forms under the notch and the notch gulps it.
        case question
        /// The prompt was answered or withdrawn while the notch was holding itself open for it.
        case resolved
        /// A run finished: the notch breathes out and drops confetti. It does not open.
        case finished(sessionID: String)
    }

    let id = UUID()
    let kind: Kind
}

/// What the surfaces need to know about the display they are drawing on. Content must never
/// land under the camera housing, so every collapsed layout consults this.
struct NotchLayout: Equatable {
    var hasPhysicalNotch: Bool
    var physicalNotchSize: CGSize

    static let none = NotchLayout(
        hasPhysicalNotch: false,
        physicalNotchSize: .zero
    )
}

private struct NotchLayoutKey: EnvironmentKey {
    static let defaultValue = NotchLayout.none
}

extension EnvironmentValues {
    var notchLayout: NotchLayout {
        get { self[NotchLayoutKey.self] }
        set { self[NotchLayoutKey.self] = newValue }
    }
}
