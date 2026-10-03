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
        _animatedCollapsedSize = State(initialValue: coordinator.collapsedSize)
        _isShowingSettings = State(initialValue: debugShowsSettings)
    }

    var body: some View {
        observingActivity(aperture)
    }

    /// The silhouette, its content and the spring that opens it.
    ///
    /// Split out of `body` along with `observingActivity(_:)`: as one expression, the whole
    /// chain was more than CI's compiler would type-check in reasonable time.
    private var aperture: some View {
        ZStack(alignment: .top) {
            Color.clear

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
                .background(Theme.Colors.surface)
                .clipShape(currentShape)
                .overlay(attentionRing)
                .contentShape(currentShape)
                .compositingGroup()
                .background(surfaceShadow)
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
            withAnimation(Theme.Motion.forState(newState)) {
                animatedState = newState
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

    private func observingActivity(_ content: some View) -> some View {
        observingInputs(content)
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
            refreshActivity(animated: false)
            trading.setPanelVisible(tradingPanelVisible)
        }
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
        case .expanded: Theme.Metrics.expandedNotchSize
        }
    }

    /// The animating silhouette. Reads `animatedState` so it interpolates.
    private var apertureSize: CGSize {
        switch animatedState {
        case .collapsed: animatedCollapsedSize
        case .expanded: Theme.Metrics.expandedNotchSize
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
                    width: Theme.Metrics.expandedNotchSize.width,
                    height: Theme.Metrics.expandedNotchSize.height,
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

    private var expandedContent: some View {
        // `alignment: .leading`, not the default centre. Centred, the tab bar sat directly
        // beneath the camera housing — the one strip of the panel the user physically cannot
        // see, which made the app's only piece of directly-operated chrome invisible.
        VStack(alignment: .leading, spacing: Theme.Metrics.expandedHeaderSpacing) {
            header
                .padding(.horizontal, Theme.Metrics.expandedHorizontalPadding)
                .padding(.top, Theme.Metrics.expandedTopContentInset)

            Group {
                if isShowingSettings {
                    SettingsExpandedView(settings: settings, mediaKeys: services.mediaKeys, integrations: services.integrations, store: store)
                } else {
                    switch coordinator.currentSurface {
                    case .media:
                        MediaExpandedView(nowPlaying: nowPlaying)
                    case .agents:
                        AgentsExpandedView(store: store, integrations: services.integrations, namespace: contentNamespace, showsModel: settings.showAgentModel)
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
        } else if coordinator.currentSurface == .agents, !store.pendingApprovals.isEmpty {
            // An approval card covers the rows, so a bulk action on them would act on things the
            // user cannot see. The slot says how many prompts are queued behind this one instead.
            Text("\(store.pendingApprovals.count) waiting")
                .font(Theme.Text.micro)
                .foregroundStyle(
                    store.pendingApprovals.contains { $0.question == nil }
                        ? Theme.Colors.Status.needsApproval
                        : Theme.Colors.Status.question
                )
                .lineLimit(1)
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
                displayScale: displayScale
            )
        case .expanded:
            NotchShape(
                topCornerRadius: Theme.Metrics.expandedTopCornerRadius,
                bottomCornerRadius: Theme.Metrics.expandedBottomCornerRadius,
                displayScale: displayScale
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
