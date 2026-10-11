import AppKit
import Combine
import SwiftUI

@MainActor
struct NotchRootView: View {
    @ObservedObject private var coordinator: NotchCoordinator
    @ObservedObject private var store: AgentSessionStore
    @ObservedObject private var nowPlaying: NowPlayingMonitor
    @ObservedObject private var systemHUD: SystemHUDMonitor
    @ObservedObject private var settings: NotchSettings
    @ObservedObject private var trading: TradingStore
    @ObservedObject private var lyrics: LyricsController
    private let services: SystemServices
    @Namespace private var contentNamespace
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Mirrors `coordinator.state` synchronously from its projected publisher, so the aperture
    /// springs without waiting for the coordinator's coalesced render pass. See `onReceive`.
    @State private var animatedState: NotchState = .collapsed
    /// Mirrors the resting silhouette for the same transaction-lifetime reason as
    /// `animatedState`. Live activity changes this size without changing the notch state.
    @State private var animatedCollapsedSize: CGSize
    /// Surface fades need their own value mirrors rather than an `.animation` modifier on the
    /// views they paint. A value-scoped animation modifier also owns the resolved geometry of
    /// its subtree; putting `surfaceFade` on the shadow shape or lift gradient therefore pulled
    /// those layers off the aperture spring and let a full-size silhouette arrive early.
    @State private var shadowStrength: CGFloat = .zero
    /// Whether the expanded panel is showing settings instead of the selected surface.
    ///
    /// Local view state rather than a third `NotchSurface`. Settings is not a live activity and
    /// must never appear on a collapsed shoulder, must not be reachable from the tab bar, and
    /// must not survive a collapse — three exceptions that would have to be written into every
    /// `switch` over `NotchSurface` if it were a case there.
    @State private var isShowingSettings = false

    /// Every drawn effect — liquid, stars, pixels in flight, sparks, the lyric pill.
    @State private var fx = NotchFX()
    /// Added to the aperture for the attention gestures: negative for the inhale before a pop,
    /// positive for a nudge or a finished run's breath. Zero at rest.
    @State private var flex: CGSize = .zero
    /// The bottom edge's bow — see `NotchShape.belly`. Zero at rest.
    @State private var belly: CGFloat = .zero
    /// The animation the next state change should use instead of plain `open`/`close`. Set by
    /// the choreography just before it changes the state, and consumed by the state mirror.
    @State private var nextStateAnimation: Animation?
    /// Why the notch opened itself, if it did. A takeover is closed again by the choreography
    /// when what it was for goes away; an opening the user asked for is never closed for them.
    @State private var takeover: Takeover?
    /// Where the card's mascot was when the prompt it stood for was answered, so it can fly home
    /// from there even though the card has already been taken down.
    @State private var homecomingFrom: CGRect?
    @State private var choreography: Task<Void, Never>?
    @State private var nudger: Task<Void, Never>?
    @State private var onboarding: OnboardingDirector?

    /// `debugShowsSettings` is for `FrameDump` and nothing else. The settings surface is local
    /// view state by design (see `isShowingSettings`), and `ImageRenderer` cannot press a
    /// button — so the one surface with the tightest vertical budget in the app would otherwise
    /// be the only one the frame dump could never render.
    init(
        coordinator: NotchCoordinator,
        store: AgentSessionStore,
        services: SystemServices,
        debugShowsSettings: Bool = false
    ) {
        self.coordinator = coordinator
        self.store = store
        self.services = services
        _nowPlaying = ObservedObject(wrappedValue: services.nowPlaying)
        _systemHUD = ObservedObject(wrappedValue: services.systemHUD)
        _settings = ObservedObject(wrappedValue: services.settings)
        _trading = ObservedObject(wrappedValue: services.trading)
        _lyrics = ObservedObject(wrappedValue: services.lyrics)
        _animatedCollapsedSize = State(initialValue: coordinator.collapsedSize)
        _isShowingSettings = State(initialValue: debugShowsSettings)
    }

    var body: some View {
        observingActivity(aperture)
            .environment(fx)
    }

    /// The silhouette, its content and the spring that opens it.
    ///
    /// Split out of `body` along with `observingActivity(_:)`: as one expression, the whole
    /// chain was more than CI's compiler would type-check in reasonable time.
    private var aperture: some View {
        ZStack(alignment: .top) {
            Color.clear

            NotchLiquidLayer(fx: fx)

            shellContent
                // Content is laid out at its *destination* size immediately and never
                // animates its own layout — otherwise it reflows and squeezes for the whole
                // gesture, which reads as a fade rather than the notch stretching open.
                .frame(
                    width: contentSize.width,
                    height: contentSize.height,
                    alignment: .top
                )
                .animation(nil, value: coordinator.state)
                // Only this frame animates. It is the aperture: the content sits still behind
                // it and is uncovered as the silhouette springs open.
                .frame(
                    width: apertureSize.width,
                    height: apertureSize.height,
                    alignment: .top
                )
                .background(alignment: .top) { apertureBackground }
                .clipShape(currentShape)
                .overlay(attentionRing)
                .overlay(NotchRimFlashView(fx: fx, shape: currentShape))
                .contentShape(currentShape)
                .compositingGroup()
                .background(surfaceShadow)

            NotchOuterFXLayer(fx: fx)
        }
        .coordinateSpace(.named(NotchFX.space))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            fx.panelSize = size
        }
        // The aperture animates off local view state, not off the coordinator.
        //
        // `NotchCoordinator` is an `ObservableObject`. A `@Published` change emits
        // `objectWillChange` from `willSet`, and SwiftUI coalesces that invalidation into a
        // later render pass — by which point the `withAnimation` transaction that caused it has
        // closed. The size jumped straight to its final value no matter how long the spring
        // was; measured against the running app with a 4s spring, it was fully open within one
        // frame. Attaching `.animation(_:value:)` to the published property did not help
        // either, for the same reason: there is no transaction left to attach to.
        //
        // The projected `$state` publisher is different: it delivers the incoming value
        // synchronously from `willSet`, before the coalesced object invalidation asks SwiftUI
        // for another body pass. Mutating the mirror from that delivery puts the change inside
        // a SwiftUI-owned animation transaction immediately, preserving the spring without the
        // extra render pass that `onChange` paid. The collapsed width needs its own mirror: live
        // activity can add or remove shoulders while `state` remains `.collapsed`, so the state
        // mirror alone never receives a change to animate.
        .onReceive(coordinator.$state.dropFirst()) { newState in
            let animation = nextStateAnimation ?? Theme.Motion.forState(newState)
            nextStateAnimation = nil
            stateWillChange(to: newState)
            withAnimation(animation) {
                animatedState = newState
                // An inhale or a breath is always given back by the gesture that follows it.
                flex = .zero
            }
            // These mutations deliberately live in a second transaction. The values fade on
            // `surfaceFade`, while every view that consumes them continues resolving its
            // bounds and shape from the aperture's transaction above.
            withAnimation(Theme.Motion.surfaceFade) {
                shadowStrength = newState == .expanded
                    ? Theme.Metrics.shadowOpacity
                    : .zero
            }
            // Settings do not survive a collapse. The pin normally prevents one while they are
            // open, but a display change or a screen-parameter reposition can still close the
            // panel — and reopening on settings, minutes later, with no memory of having left
            // them there, is not what the next hover was asking for.
            if newState == .collapsed, isShowingSettings {
                isShowingSettings = false
                coordinator.setPinnedOpen(false)
            }
        }
    }

    /// Which sessions currently demand attention, as its own typed value so the `onChange`
    /// that watches it does not make the compiler infer a closure inside the modifier chain.
    private var attentionFlags: [Bool] {
        store.sessions.map { $0.status.demandsAttention }
    }

    private func observingInputs(_ content: some View) -> some View {
        content
        // Every input to the collapsed silhouette funnels through one handler.
        //
        // These used to be three, one per activity, each recomputing its own flag from its own
        // monitor. Once preferences arrived that could switch an activity off — and once a
        // *paused* player stopped counting as media — each of those handlers needed the same
        // two settings, and the flag a handler did not own kept whatever value it had from
        // whichever monitor last fired. `refreshActivity` recomputes all three from the current
        // state of everything, so no ordering of events can leave the pair inconsistent.
        //
        // The HUD is the one collapsed surface the user *triggered*, so it rides the same
        // `Theme.Motion.shoulders` spring as the rest rather than snapping in: a volume tap over
        // a playing track reads as the silhouette morphing, not as one island replacing another.
        .onChange(of: nowPlaying.status) { _, _ in refreshActivity() }
        .onChange(of: store.sessions.count) { _, _ in refreshActivity() }
        .onChange(of: systemHUD.event) { _, _ in refreshActivity() }
        .onChange(of: settings.revision) { _, _ in refreshActivity() }
        .onChange(of: trading.wantsShoulder) { _, _ in refreshActivity() }
        .onChange(of: attentionFlags) { _, _ in refreshActivity() }
        .onChange(of: store.pendingApprovals.count) { _, _ in refreshActivity() }
        .onChange(of: tradingPanelVisible) { _, value in trading.setPanelVisible(value) }
    }

    /// The choreography's inputs, in a chain of their own: appended to the one above, the whole
    /// thing was more than CI's compiler would type-check in reasonable time.
    private func observingAttention(_ content: some View) -> some View {
        content
            .onChange(of: coordinator.isWelcoming) { _, _ in refreshActivity() }
            .onChange(of: pillLine) { old, new in updatePill(from: old, to: new) }
            .onReceive(coordinator.$attentionCue.compactMap { $0 }) { cue in handleAttention(cue) }
            .onReceive(coordinator.$onboardingRequest.compactMap { $0 }) { _ in beginOnboarding() }
    }

    private func observingActivity(_ content: some View) -> some View {
        observingAttention(observingInputs(content))
        .onChange(of: coordinator.currentSurface) { _, _ in
            withAnimation(Theme.Motion.shoulders) {
                animatedCollapsedSize = coordinator.collapsedSize
            }
        }
        .onAppear {
            animatedState = coordinator.state
            shadowStrength = coordinator.state == .expanded
                ? Theme.Metrics.shadowOpacity
                : .zero
            fx.pointer = { [coordinator] in coordinator.pointerLocation }
            fx.reduceMotion = reduceMotion
            refreshActivity(animated: false)
            trading.setPanelVisible(tradingPanelVisible)
            updatePill(from: nil, to: pillLine)
        }
        .onChange(of: reduceMotion) { _, value in fx.reduceMotion = value }
        // Fills the panel, which is deliberately larger than the notch so the shadow and the
        // hover grace zone are not clipped away.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.notchLayout, coordinator.layout)
        // `preferredColorScheme` is a *scene* modifier and does not reach a view hosted in an
        // `NSHostingView`, so every `.secondary`/`.tertiary` style was resolving against the
        // light scheme — dark grey text on a black panel, effectively invisible. The panel is
        // always black, so the scheme is pinned outright.
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    /// Where the content is laid out, which is always its finished size — never the animating
    /// aperture. The aperture reveals it; it does not resize with it. This deliberately reads
    /// the coordinator, not `animatedState`: content must be at its destination size on the
    /// very first frame of the gesture.
    private var contentSize: CGSize {
        switch coordinator.state {
        case .collapsed: coordinator.collapsedSize
        case .expanded: coordinator.expandedSize
        }
    }

    /// The animating silhouette. Reads `animatedState` so it interpolates, plus whatever the
    /// attention gestures are borrowing — and a positive belly is paid for in height, so the
    /// bowed edge stays inside the frame the fill and the clip are drawn in.
    private var apertureSize: CGSize {
        let base = switch animatedState {
        case .collapsed: animatedCollapsedSize
        case .expanded: coordinator.expandedSize
        }
        return CGSize(
            width: max(.zero, base.width + flex.width),
            height: max(.zero, base.height + flex.height + max(belly, .zero))
        )
    }

    /// The black of the notch, with the star field and pixels in flight drawn into it. The
    /// canvas is the size of the whole panel and is clipped by the aperture like everything
    /// else, which is what makes the stars appear *inside* the notch as it opens.
    private var apertureBackground: some View {
        ZStack(alignment: .top) {
            Theme.Colors.surface
            NotchInnerFXLayer(fx: fx)
                .frame(width: fx.panelSize.width, height: fx.panelSize.height, alignment: .top)
        }
    }

    /// A light that travels around the silhouette while an agent is blocked on the user.
    ///
    /// This is the only thing on screen when the notch is at rest and something needs a
    /// decision, so it has to be noticeable from peripheral vision without being a flashing
    /// alert. Reduce Motion gets a static ring rather than nothing — the signal matters more
    /// than the animation. `AttentionRingView` carries the shape and motion reasoning.
    @ViewBuilder
    private var attentionRing: some View {
        if let attentionTint {
            AttentionRingView(
                shape: currentShape,
                tint: attentionTint,
                isAnimated: !reduceMotion
            )
        }
    }

    /// The hue of whatever is blocking, or `nil` when nothing is.
    ///
    /// Two things changed here. It used to test `pendingApprovals` alone, while
    /// `SessionStatus.demandsAttention` — whose doc comment says in as many words that it is
    /// "whether this state should light the attention ring around the collapsed silhouette" —
    /// was consulted by nothing that draws the ring. A session sitting on an unanswered
    /// question lit no ring at all, which is half of what the ring is for.
    ///
    /// And it used to hardcode the approval amber regardless of which state was blocking, so on
    /// the one occasion the ring did appear for a question it appeared in the wrong colour.
    /// Approval outranks a question when both are live, for the same reason it does on the
    /// collapsed shoulder: it is the one that is holding an agent's hook open.
    private var attentionTint: Color? {
        guard settings.showAttentionRing, coordinator.state == .collapsed else { return nil }
        // A pending *question* is still a pending approval on the wire, and lighting the rim
        // amber for one put the ring, the shoulder mascot and the card in three different
        // colours for the same event.
        if let blocking = store.pendingApprovals.min(by: { $0.requestedAt < $1.requestedAt }) {
            return blocking.question == nil
                ? Theme.Colors.Status.needsApproval
                : Theme.Colors.Status.question
        }
        guard let blocked = store.sessions.first(where: { $0.status.demandsAttention }) else {
            return nil
        }
        return blocked.status.tint
    }

    /// Kept on its own layer so it inherits the aperture's live bounds. `shadowStrength` is
    /// animated at the mutation site rather than here: an animation modifier on this subtree
    /// would replace the spring for the shape and recreate the early full-size silhouette.
    private var surfaceShadow: some View {
        currentShape
            .fill(Theme.Colors.surface)
            .shadow(
                color: Theme.Colors.surface,
                radius: Theme.Metrics.shadowRadius,
                y: Theme.Metrics.shadowYOffset
            )
            .opacity(shadowStrength)
    }

    @ViewBuilder
    private var shellContent: some View {
        // Both destinations stay mounted for the whole gesture. Removing the expanded branch
        // when the coordinator flipped to `.collapsed` deleted its contents before the local
        // aperture state had moved, leaving an empty full-size silhouette to deflate.
        //
        // The alignment and the per-child frames are both load-bearing. A `ZStack` sizes itself
        // to its largest child, so once the expanded panel stayed mounted the stack became
        // 620x160 even at rest — and a default-centred stack then laid the collapsed strip out
        // 620pt wide and centred 80pt down, entirely outside the 32pt aperture. The notch went
        // wide and drew nothing at all. Each child is pinned to its own destination size and to
        // the top; both are centred on the housing, so the horizontal centring agrees.
        ZStack(alignment: .top) {
            collapsedContent
                .frame(
                    width: coordinator.collapsedSize.width,
                    height: coordinator.collapsedSize.height,
                    alignment: .top
                )
                .opacity(animatedState == .collapsed ? 1 : .zero)
                .animation(
                    animatedState == .collapsed
                        ? Theme.Motion.contentEnter
                        : Theme.Motion.contentExit,
                    value: animatedState
                )

            expandedContent
                .frame(
                    width: coordinator.expandedSize.width,
                    height: coordinator.expandedSize.height,
                    alignment: .top
                )
                .scaleEffect(
                    animatedState == .expanded
                        ? 1
                        : Theme.Metrics.contentEntryScale,
                    anchor: .top
                )
                .blur(
                    radius: animatedState == .expanded
                        ? .zero
                        : Theme.Metrics.contentEntryBlur
                )
                // Modifier order is load-bearing here. `contentEntry` is inside the opacity
                // animation, so it replaces that outer transaction for the scale and blur
                // above it; opacity sits outside this boundary and receives only the
                // direction-aware enter/exit curve below. Putting one animation after all
                // three effects made the blur finish with the fast fade while the aperture
                // edge was still cutting across content.
                .animation(Theme.Motion.contentEntry, value: animatedState)
                .opacity(animatedState == .expanded ? 1 : .zero)
                .animation(
                    animatedState == .expanded
                        ? Theme.Motion.contentEnter
                        : Theme.Motion.contentExit,
                    value: animatedState
                )
        }
    }

    private var collapsedContent: some View {
        CollapsedLiveActivityView(
            layout: coordinator.liveActivityLayout,
            nowPlaying: nowPlaying,
            store: store,
            trading: trading,
            hudEvent: systemHUD.event
        )
    }

    @ViewBuilder
    private var expandedContent: some View {
        if let onboarding, coordinator.isOnboarding {
            OnboardingView(director: onboarding, integrations: services.integrations)
        } else {
            panelContent
        }
    }

    private var panelContent: some View {
        // `alignment: .leading`, not the default centre. Centred, the tab bar sat directly
        // beneath the camera housing — the one strip of the panel the user physically cannot
        // see, which made the app's only piece of directly-operated chrome invisible.
        VStack(alignment: .leading, spacing: Theme.Metrics.expandedHeaderSpacing) {
            if showsHeader {
                header
                    .padding(.horizontal, Theme.Metrics.expandedHorizontalPadding)
                    .padding(.top, Theme.Metrics.expandedTopContentInset)
            }

            Group {
                if isShowingSettings {
                    SettingsExpandedView(
                        settings: settings,
                        mediaKeys: services.mediaKeys,
                        integrations: services.integrations,
                        store: store,
                        onReplayIntro: { coordinator.requestOnboarding() }
                    )
                } else {
                    switch coordinator.currentSurface {
                    case .media:
                        MediaExpandedView(nowPlaying: nowPlaying, lyrics: services.lyrics)
                    case .agents:
                        AgentsExpandedView(
                            store: store,
                            integrations: services.integrations,
                            namespace: contentNamespace,
                            showsModel: settings.showAgentModel
                        )
                    case .trading:
                        TradingExpandedView(store: trading, isVisible: tradingPanelVisible) { editing in
                            if !isShowingSettings { coordinator.setPinnedOpen(editing) }
                        }
                    }
                }
            }
            .transition(.opacity)
            .animation(Theme.Motion.content, value: coordinator.currentSurface)
            .animation(Theme.Motion.content, value: isShowingSettings)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Whether the tab bar shows. Not while a prompt card is up: the card is the whole panel,
    /// and tabs are no use while an agent is blocked on the user. The card has its own dismiss.
    private var showsHeader: Bool {
        isShowingSettings || coordinator.currentSurface != .agents || store.pendingApprovals.isEmpty
    }

    /// The tab bar at the leading edge, the gear at the trailing edge, and whatever actions the
    /// current surface offers between them.
    ///
    /// Both ends, and nothing in the middle: the centre of the header sits behind the physical
    /// camera housing. `NotchTabBar` carries the same constraint and the longer explanation.
    private var header: some View {
        HStack(spacing: Theme.Metrics.TabBar.spacing) {
            NotchTabBar(
                selection: Binding(
                    get: { coordinator.currentSurface },
                    set: { surface in
                        // Picking a tab is also how you leave settings. Otherwise the tab bar
                        // stays live under an open settings panel and changes a selection the
                        // user cannot see the result of.
                        isShowingSettings = false
                        coordinator.setPinnedOpen(false)
                        coordinator.show(surface)
                    }
                ),
                activeSurfaces: activeSurfaces
            )

            Spacer(minLength: Theme.Metrics.expandedContentSpacing)

            headerActions

            NotchGearButton(isActive: isShowingSettings) {
                withAnimation(Theme.Motion.content) {
                    isShowingSettings.toggle()
                }
                // Hover-to-open and leave-to-close is right for a surface you glance at and
                // wrong for one you operate: flipping four switches means keeping the cursor
                // inside a strip at the top of the screen the whole time, and one overshoot
                // past the grace ring would close the panel mid-task.
                coordinator.setPinnedOpen(isShowingSettings)
            }
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        if isShowingSettings {
            NotchHeaderActionButton(
                title: "Restore Defaults",
                isEnabled: !settings.isAtDefaults
            ) {
                settings.restoreDefaults()
            }

            NotchHeaderActionButton(title: "Quit") {
                NSApp.terminate(nil)
            }
        } else if coordinator.currentSurface == .agents, hasHideableSessions {
            // The bulk form of the per-row hide control. Only offered when it would actually do
            // something, because a button that is present and inert is worse than an absent one.
            NotchHeaderActionButton(title: "Clear Idle") {
                withAnimation(Theme.Motion.content) {
                    _ = store.hideRestingSessions()
                }
            }
        }
    }

    private var hasHideableSessions: Bool {
        store.sessions.contains { session in
            !session.status.isBusy
                && !session.status.demandsAttention
                && store.canHide(sessionID: session.id)
        }
    }

    private var activeSurfaces: Set<NotchSurface> {
        var surfaces: Set<NotchSurface> = []
        surfaces.insert(.trading)
        if settings.showsMedia(nowPlaying.status) {
            surfaces.insert(.media)
        }
        if settings.showsAgents(sessionCount: store.sessions.count) {
            surfaces.insert(.agents)
        }
        return surfaces
    }

    /// Recomputes all three collapsed-activity flags from the live state of the monitors and the
    /// preferences, then re-derives the resting silhouette from them.
    ///
    /// The single entry point for anything that can change what the collapsed notch shows. See
    /// the comment above the `onChange` handlers for why there is exactly one of these.
    private func refreshActivity(animated: Bool = true) {
        let apply = {
            coordinator.hasMediaActivity = settings.showsMedia(nowPlaying.status)
            coordinator.hasAgentActivity = settings.showsAgents(
                sessionCount: store.sessions.count
            )
            coordinator.hasSystemHUD = settings.replaceSystemHUD && systemHUD.event != nil
            coordinator.hasTradingActivity = trading.wantsShoulder
            coordinator.agentNeedsAttention = !store.pendingApprovals.isEmpty || store.sessions.contains { $0.status.demandsAttention }
            animatedCollapsedSize = coordinator.collapsedSize
            fx.collapsedSize = coordinator.collapsedSize
        }

        if animated {
            withAnimation(Theme.Motion.shoulders, apply)
        } else {
            apply()
        }
    }

    // The tab is the user's. It used to be re-picked on every collapse — forced to Crypto
    // whenever the ticker had a shoulder, or moved off a surface that had gone empty — so the
    // next hover opened somewhere the user had not left it. Every surface now has a real empty
    // state, so the last tab chosen is always a fine place to reopen. The one exception is an
    // approval, which `AgentBridgeController` switches to agents because the agent is stalled.

    private var tradingPanelVisible: Bool {
        coordinator.state == .expanded && coordinator.currentSurface == .trading && !isShowingSettings
    }

    /// Radii come from `animatedState` so the corners open with the aperture. `NotchShape`
    /// is animatable on both radii; driving it from the coordinator meant they snapped to their
    /// final values on frame one while the silhouette was still meant to be growing.
    private var currentShape: NotchShape {
        switch animatedState {
        case .collapsed:
            NotchShape(
                topCornerRadius: Theme.Metrics.collapsedTopCornerRadius,
                bottomCornerRadius: Theme.Metrics.collapsedBottomCornerRadius,
                displayScale: displayScale,
                belly: belly
            )
        case .expanded:
            NotchShape(
                topCornerRadius: coordinator.isOnboarding
                    ? Theme.Metrics.onboardingTopCornerRadius
                    : Theme.Metrics.expandedTopCornerRadius,
                bottomCornerRadius: coordinator.isOnboarding
                    ? Theme.Metrics.onboardingBottomCornerRadius
                    : Theme.Metrics.expandedBottomCornerRadius,
                displayScale: displayScale,
                belly: belly
            )
        }
    }

    /// The sole animated mutation for shell expansion. Width, height, radii, and promoted
    /// content all read the same state change from the same transaction.
    ///
    /// Open and close use different springs — see `Theme.Motion`. Driving both directions from
    /// one curve is what made the close read as a rubber-band snap.
    static func transition(_ coordinator: NotchCoordinator, to state: NotchState) {
        withAnimation(Theme.Motion.forState(state)) {
            coordinator.setState(state)
        }
    }
}

// MARK: - Attention choreography
//
// What the notch does, physically, when an agent wants the user. Each moment has its own
// gesture so it can be told apart out of the corner of the eye without reading anything: a
// permission prompt *pops* (an inhale, then an under-damped open with shock rings), a question
// *drips* (a drop forms under the notch and the notch gulps it), and a finished run *breathes
// out* (the shoulders widen, a light runs along the rim, confetti spills onto the desktop).
//
// Everything here lives in this file rather than an extension elsewhere because it drives the
// view's own `@State` — the aperture's flex and belly — and those have to be mutated inside the
// same transactions as the state mirror above for the gestures to stay one motion.

/// Why the notch opened itself.
enum Takeover: Equatable {
    case approval
    case question
}

extension NotchRootView {
    private var attention: Theme.Motion.Attention.Type { Theme.Motion.Attention.self }

    func handleAttention(_ cue: AttentionCue) {
        guard !coordinator.isOnboarding else { return }
        switch cue.kind {
        case .approval: present(.approval)
        case .question: present(.question)
        case .resolved: resolveTakeover()
        case let .finished(sessionID): celebrate(sessionID: sessionID)
        }
    }

    /// A prompt arrived. Already open: the notch only flashes, because yanking an open panel
    /// around under the pointer is worse than a missed flourish. Closed: the full gesture.
    private func present(_ kind: Takeover) {
        let tint = kind == .approval ? Theme.Colors.Status.needsApproval : Theme.Colors.Status.question
        takeover = kind

        if coordinator.state == .expanded {
            coordinator.show(.agents)
            if !reduceMotion {
                fx.rim(tint, mode: .pulse)
                fx.rings(around: coordinator.expandedSize, topRadius: Theme.Metrics.expandedTopCornerRadius, bottomRadius: Theme.Metrics.expandedBottomCornerRadius, tint: tint, count: 1)
            }
            startNudging(kind)
            return
        }

        choreography?.cancel()
        choreography = Task { @MainActor in
            coordinator.show(.agents)
            guard !reduceMotion else {
                change(to: .expanded, with: Theme.Motion.open)
                startNudging(kind)
                return
            }
            let expanded = coordinator.expandedSize
            if kind == .approval {
                withAnimation(Theme.Motion.inhale) {
                    flex = CGSize(width: -attention.inhaleWidth, height: -attention.inhaleHeight)
                }
                try? await Task.sleep(for: Theme.Motion.inhaleHold)
                guard !Task.isCancelled else { return }
                change(to: .expanded, with: Theme.Motion.pop)
                kickBelly(attention.popBelly)
                fx.rings(around: expanded, topRadius: Theme.Metrics.expandedTopCornerRadius, bottomRadius: Theme.Metrics.expandedBottomCornerRadius, tint: tint, count: 2)
                fx.sparks(off: fx.body(expanded, topRadius: Theme.Metrics.expandedTopCornerRadius), tint: tint)
                fx.rim(tint, mode: .pulse)
            } else {
                fx.hangDrop(under: fx.attachment(coordinator.collapsedSize, expanded: false), radius: attention.questionDrop.radius, hang: attention.questionDrop.hang)
                try? await Task.sleep(for: attention.dropForm + attention.dropHang)
                guard !Task.isCancelled else { return }
                change(to: .expanded, with: Theme.Motion.open)
                kickBelly(attention.popBelly * 0.7)
                fx.gulp(depth: expanded.height * 0.7)
            }
            startNudging(kind)
        }
    }

    /// Re-asks, gently, while a takeover sits unanswered and the user is not looking at it.
    private func startNudging(_ kind: Takeover) {
        nudger?.cancel()
        nudger = Task { @MainActor in
            for _ in 0 ..< attention.maxNudges {
                try? await Task.sleep(for: kind == .approval ? attention.approvalNudge : attention.questionNudge)
                guard !Task.isCancelled, takeover == kind, coordinator.state == .expanded,
                      !store.pendingApprovals.isEmpty else { return }
                // Someone reading the card does not need to be told it is there.
                guard !coordinator.pointerIsInsideLiveRegion else { continue }
                nudge(kind)
            }
        }
    }

    private func nudge(_ kind: Takeover) {
        let tint = kind == .approval ? Theme.Colors.Status.needsApproval : Theme.Colors.Status.question
        guard !reduceMotion else {
            fx.rim(tint, mode: .pulse)
            return
        }
        if kind == .approval {
            kick(width: attention.nudgeWidth)
            kickBelly(attention.nudgeBelly)
            fx.rings(around: coordinator.expandedSize, topRadius: Theme.Metrics.expandedTopCornerRadius, bottomRadius: Theme.Metrics.expandedBottomCornerRadius, tint: tint, count: 1)
            fx.rim(tint, mode: .pulse)
        } else {
            fx.hangDrop(under: fx.attachment(coordinator.expandedSize, expanded: true), radius: attention.nudgeDrop.radius, hang: attention.nudgeDrop.hang, life: attention.nudgeDropLife)
        }
    }

    /// The prompt was answered. If the notch only opened because of it and the user is not
    /// inside it, it goes home on its own — and the mascot with it.
    private func resolveTakeover() {
        guard takeover == .approval || takeover == .question else { return }
        homecomingFrom = fx.anchors[.card]
        takeover = nil
        nudger?.cancel()
        guard coordinator.state == .expanded, !coordinator.pointerIsInsideLiveRegion, !coordinator.isPinnedOpen else {
            homecomingFrom = nil
            return
        }
        change(to: .collapsed, with: Theme.Motion.homecoming)
    }

    /// A run finished: the shoulders breathe out with a light along the rim and confetti spills
    /// onto the desktop. Nothing opens — a finished run asks nothing of the user, so it gets a
    /// flourish rather than a takeover.
    private func celebrate(sessionID: String) {
        guard settings.celebrateFinishedRuns, store.pendingApprovals.isEmpty, takeover == nil,
              store.sessionsByID[sessionID] != nil, !reduceMotion else { return }
        let tint = Theme.Colors.Status.done
        guard coordinator.state == .collapsed else {
            fx.rim(tint, mode: .sweep)
            return
        }

        choreography?.cancel()
        choreography = Task { @MainActor in
            withAnimation(Theme.Motion.breathOut) { flex.width = attention.breathWidth }
            fx.rim(tint, mode: .sweep)
            let breathed = CGSize(width: coordinator.collapsedSize.width + attention.breathWidth, height: coordinator.collapsedSize.height)
            fx.confetti(from: fx.body(breathed, topRadius: Theme.Metrics.collapsedTopCornerRadius))
            try? await Task.sleep(for: attention.breathHold)
            guard !Task.isCancelled else { return }
            withAnimation(Theme.Motion.breathIn) { flex = .zero }
        }
    }

    // MARK: Transitions

    /// Changes the notch's state on a specific animation rather than plain open/close.
    private func change(to state: NotchState, with animation: Animation) {
        guard coordinator.state != state else { return }
        nextStateAnimation = animation
        coordinator.setState(state)
    }

    /// Runs on every state change, before the aperture starts moving: the mascot's pixels fly
    /// between the shoulder and whichever card the panel is about to show or take down.
    func stateWillChange(to newState: NotchState) {
        switch newState {
        case .expanded:
            fx.hidePill()
            flyMascotIn()
        case .collapsed:
            flyMascotHome()
            nudger?.cancel()
            if takeover != nil { takeover = nil }
            fx.fadeStars()
            fx.clearDrops()
            if belly != .zero { belly = .zero }
        }
    }

    /// Whether the panel that is opening will show a card with a mascot on it.
    private var cardStatus: SessionStatus? {
        guard !coordinator.isOnboarding, !isShowingSettings, coordinator.currentSurface == .agents else { return nil }
        if let approval = store.pendingApprovals.min(by: { $0.requestedAt < $1.requestedAt }) {
            return approval.question == nil ? .needsApproval : .waitingForAnswer
        }
        return nil
    }

    private func flyMascotIn() {
        guard !reduceMotion, let status = cardStatus else { return }
        let expanded = fx.silhouette(coordinator.expandedSize)
        fx.spawnStars(attention.cardStars, in: expanded.insetBy(dx: 12, dy: 8), opacity: attention.cardStarOpacity, appearOver: 0.6)
        guard let shoulder = fx.anchors[.shoulder], shoulder.height > 0 else { return }
        let cardPixel = (Theme.Metrics.Prompt.mascotSize / CGFloat(AgentActivityGlyph.rows)).rounded(.down)
        fx.hidden.insert(.card)
        fx.transit(
            cells: AgentActivityGlyph.cells(for: status, elapsed: 0),
            from: (shoulder.origin, shoulder.height / CGFloat(AgentActivityGlyph.rows)),
            to: .card,
            fallback: (CGPoint(x: expanded.minX + Theme.Metrics.expandedHorizontalPadding + 12, y: expanded.minY + 44), cardPixel),
            tint: status.tint,
            upward: false
        )
        Task { @MainActor in
            try? await Task.sleep(for: attention.transitArrival)
            fx.hidden.remove(.card)
        }
    }

    private func flyMascotHome() {
        let from = homecomingFrom ?? (cardStatus == nil ? nil : fx.anchors[.card])
        homecomingFrom = nil
        guard !reduceMotion, let from, from.height > 0,
              let leading = store.leadingSession, coordinator.liveActivityLayout.showsAgentMascot else { return }
        let collapsed = fx.silhouette(coordinator.collapsedSize)
        let shoulderPixel = (Theme.Metrics.Agents.mascotCollapsedSize / CGFloat(AgentActivityGlyph.rows)).rounded(.down)
        fx.hidden.insert(.shoulder)
        fx.transit(
            cells: AgentActivityGlyph.cells(for: leading.status, elapsed: 0),
            from: (from.origin, from.height / CGFloat(AgentActivityGlyph.rows)),
            to: .shoulder,
            fallback: (CGPoint(x: collapsed.minX + 10, y: collapsed.minY + 6), shoulderPixel),
            tint: leading.status.tint,
            upward: true
        )
        Task { @MainActor in
            try? await Task.sleep(for: attention.homecomingArrival)
            fx.hidden.remove(.shoulder)
        }
    }

    // MARK: Kicks

    /// A push and a wobbly settle on the bottom edge.
    private func kickBelly(_ amount: CGFloat) {
        withAnimation(Theme.Motion.kickOut) {
            belly = amount
        } completion: {
            withAnimation(Theme.Motion.kickSettle) { belly = .zero }
        }
    }

    /// The same, sideways.
    private func kick(width amount: CGFloat) {
        withAnimation(Theme.Motion.kickOut) {
            flex.width = amount
        } completion: {
            withAnimation(Theme.Motion.kickSettle) { flex.width = .zero }
        }
    }

    // MARK: The lyric pill

    /// The line the pill should be showing, or `nil` when there should be no pill: lyrics on,
    /// synced, playing, and the notch at rest. An instrumental break keeps the pill with a note.
    private var pillLine: String? {
        guard settings.showsMedia(nowPlaying.status), lyrics.showsOnNotch,
              coordinator.state == .collapsed, !coordinator.isOnboarding else { return nil }
        let line = lyrics.currentLine ?? ""
        return line.isEmpty ? "♪" : line
    }

    private func updatePill(from old: String?, to new: String?) {
        switch (old, new) {
        case (_, nil): fx.hidePill()
        case let (nil, line?): fx.showPill(line: line)
        case let (_, line?): fx.setPillLine(line)
        }
    }

    // MARK: Onboarding

    private func beginOnboarding() {
        guard onboarding == nil else { return }
        choreography?.cancel()
        nudger?.cancel()
        let director = OnboardingDirector(
            fx: fx,
            coordinator: coordinator,
            integrations: services.integrations,
            settings: settings,
            reduceMotion: reduceMotion,
            stage: OnboardingDirector.Stage(
                change: { state, animation in change(to: state, with: animation) },
                kickBelly: { kickBelly($0) }
            )
        )
        onboarding = director
        Task { @MainActor in
            await director.run()
            onboarding = nil
        }
    }
}
