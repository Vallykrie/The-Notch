import AppKit
import SwiftUI

/// Renders the real notch view offscreen at a series of aperture sizes and writes them to
/// disk as PNGs.
///
/// This exists because the notch cannot be screenshotted from a build agent: the notch band
/// is excluded from screen captures, and an `LSUIElement` app cannot be added to the
/// screen-recording allowlist. Rendering the actual `NotchRootView` is a stronger check than a
/// screenshot anyway — it can sample exact points of the open, including the spring's
/// overshoot, which a screenshot can only catch by luck.
///
/// Activated only by `NOTCH_FRAMES=<output-directory>`; the app exits when the dump finishes.
@MainActor
enum FrameDump {
    static var requestedDirectory: String? {
        ProcessInfo.processInfo.environment["NOTCH_FRAMES"]
    }

    /// `NOTCH_ANIM=<dir>` writes frame *sequences* instead of the stills above, for assembling
    /// into GIFs. Separate from `NOTCH_FRAMES` because it writes a few hundred files and the
    /// still dump is meant to stay fast enough to run after every change.
    static var requestedAnimationDirectory: String? {
        ProcessInfo.processInfo.environment["NOTCH_ANIM"]
    }

    /// One loop of the animation dump. 4.4s is two full turns of the attention ring and four of
    /// the `working` sweep; the states whose periods do not divide it (the cursor's 1.06s, the
    /// question's 2.0s) restart with a visible step at the loop point, which is a property of
    /// the GIF and not of the app.
    private static let animationDuration: Double = 4.4
    private static let animationFrameRate: Double = 25

    /// Renders the real views at a series of pinned instants — see
    /// `EnvironmentValues.debugMotionTime`.
    ///
    /// The notch cannot be screenshotted (see the type comment), so this is the only way to
    /// actually *watch* any of this without being at the machine with the app running: render
    /// the true view tree frame by frame and let something downstream assemble the frames.
    static func runAnimation(directory: String) {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        guard let screen = ScreenGeometry.preferredScreen() else {
            FileHandle.standardError.write(Data("FrameDump: no screen\n".utf8))
            return
        }
        let geometry = ScreenGeometry.resolve(for: screen)
        let frameCount = Int(animationDuration * animationFrameRate)

        for (name, builder) in animationSequences(geometry: geometry) {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            for index in 0 ..< frameCount {
                let time = Double(index) / animationFrameRate
                write(
                    builder(time).environment(\.debugMotionTime, time),
                    to: directory,
                    name: String(format: "%04d.png", index)
                )
            }
        }

        FileHandle.standardError.write(
            Data("FrameDump: wrote \(frameCount) frames per sequence to \(directory)\n".utf8)
        )
    }

    private static func animationSequences(
        geometry: ScreenGeometry
    ) -> [(String, (Double) -> AnyView)] {
        [
            // Every state at once, at three sizes: large enough to see what the motion is, and
            // then at the two sizes it actually ships at. A motion that only reads at 64pt has
            // not solved the problem this indicator exists for.
            ("states", { _ in AnyView(statesSheet) }),
            // The real collapsed notch, blocked on an approval: the attention ring travelling
            // its rim, and the agent shoulder's mark, in the silhouette they really occupy.
            ("collapsed", { _ in
                AnyView(notch(geometry: geometry, state: .collapsed, store: AgentsPreviewData.approvalStore()))
            }),
            // The real expanded panel, with three sessions in three different states — the
            // point being several distinct motions running beside each other, which is the
            // case the old shared pulse could not represent at all.
            ("expanded", { _ in
                AnyView(notch(geometry: geometry, state: .expanded, store: AgentsPreviewData.mixedStatusStore()))
            }),
            // The expanded panel blocked on an approval, where the card outranks the list.
            ("approval", { _ in
                AnyView(notch(geometry: geometry, state: .expanded, store: AgentsPreviewData.approvalStore()))
            }),
        ]
    }

    private static var statesSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(SessionStatus.allCases, id: \.self) { status in
                HStack(spacing: 22) {
                    Text(status.label)
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .frame(width: 150, alignment: .leading)

                    ForEach([90, 30, 20] as [CGFloat], id: \.self) { side in
                        AgentActivityGlyphView(status: status, side: side)
                            .frame(width: 64, alignment: .center)
                    }
                    .foregroundStyle(status.tint)
                }
            }
        }
        .padding(28)
        .background(Theme.Colors.surface)
        .environment(\.colorScheme, .dark)
    }

    private static func notch(
        geometry: ScreenGeometry,
        state: NotchState,
        store: AgentSessionStore
    ) -> some View {
        let coordinator = NotchCoordinator(
            state: state,
            currentSurface: .agents,
            collapsedSize: geometry.collapsedNotchSize,
            hasPhysicalNotch: geometry.hasPhysicalNotch
        )
        let services = SystemServices(
            nowPlaying: MediaPreviewData.inactiveMonitor(),
            systemHUD: .previewIdle()
        )
        coordinator.hasAgentActivity = services.settings.showsAgents(
            sessionCount: store.sessions.count
        )

        return NotchRootView(coordinator: coordinator, store: store, services: services)
            .frame(width: geometry.panelFrame.width, height: geometry.panelFrame.height)
            .background(Color(white: 0.42))
    }

    /// Sampled points along the open. Values above 1 represent the spring's overshoot, which
    /// is where an under-damped curve spends the part of the gesture that sells the stretch.
    private static let progressSamples: [CGFloat] = [0, 0.15, 0.35, 0.6, 0.85, 1.0, 1.06]

    static func run(directory: String, surface: NotchSurface = .media) {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )

        guard let screen = ScreenGeometry.preferredScreen() else {
            FileHandle.standardError.write(Data("FrameDump: no screen\n".utf8))
            return
        }
        let geometry = ScreenGeometry.resolve(for: screen)

        for (index, progress) in progressSamples.enumerated() {
            let coordinator = NotchCoordinator(
                state: .expanded,
                currentSurface: surface,
                collapsedSize: geometry.collapsedNotchSize,
                hasPhysicalNotch: geometry.hasPhysicalNotch
            )
            coordinator.debugApertureOverride = aperture(
                at: progress,
                collapsed: coordinator.collapsedSize
            )

            let view = NotchRootView(
                coordinator: coordinator,
                store: AgentSessionStore(),
                services: SystemServices(nowPlaying: MediaPreviewData.inactiveMonitor(), systemHUD: .previewIdle())
            )
            .frame(width: geometry.panelFrame.width, height: geometry.panelFrame.height)
            // The panel is transparent; a mid-grey ground makes the silhouette's edge and the
            // shadow legible in the dump instead of black-on-black.
            .background(Color(white: 0.42))

            write(view, to: url, name: String(format: "%02d-p%03.0f.png", index, progress * 100))
        }

        let scenarioCount = writeScenarios(to: url, geometry: geometry)
        let sheetCount = writeMotionSheets(to: url, geometry: geometry)

        let total = progressSamples.count + scenarioCount + sheetCount
        FileHandle.standardError.write(
            Data("FrameDump: wrote \(total) frames to \(directory)\n".utf8)
        )
    }

    /// Filmstrips: one row per motion, one column per sampled instant of it.
    ///
    /// The scenario frames above cannot verify an animation, and it is worth being precise about
    /// why, because it is the same trap that let a collapsed layout render underneath the camera
    /// housing through a dozen green builds. A scenario renders the view *now*, and every one of
    /// these motions is phased from the moment its state was entered — so a scenario dump of the
    /// nine agent states renders all nine at elapsed ≈ 0: a blank grid for `done`, a head not yet
    /// on screen for `working`, an unlit cell for `waitingForInput`. Every frame would look
    /// plausible and the sheet would prove nothing at all, which is worse than not checking.
    ///
    /// Sampling explicit phases across a full cycle is what makes a still able to answer the
    /// question these were built for: does the motion read as the verb, and does it read at
    /// `Agents.mascotCollapsedSize` and not only at twice that.
    private static func writeMotionSheets(to directory: URL, geometry: ScreenGeometry) -> Int {
        let samples = 12

        let agents = VStack(alignment: .leading, spacing: 10) {
            ForEach(SessionStatus.allCases, id: \.self) { status in
                HStack(spacing: 10) {
                    Text(status.label)
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .frame(width: 120, alignment: .leading)

                    ForEach(0 ..< samples, id: \.self) { index in
                        let elapsed = Double(index) / Double(samples) * 2.2
                        VStack(spacing: 6) {
                            AgentActivityGlyphView(
                                status: status,
                                side: Theme.Metrics.Agents.activityGlyphSize,
                                debugElapsed: elapsed
                            )
                            // The collapsed size beside the expanded one, because a motion that
                            // reads at 30pt and dissolves at 20 is a motion that works only
                            // where the user is already looking.
                            AgentActivityGlyphView(
                                status: status,
                                side: Theme.Metrics.Agents.mascotCollapsedSize,
                                debugElapsed: elapsed
                            )
                        }
                        .frame(width: 40)
                        .foregroundStyle(status.tint)
                    }
                }
            }
        }
        .padding(20)
        .background(Theme.Colors.surface)
        .environment(\.colorScheme, .dark)

        write(agents, to: directory, name: "motion-agents.png")

        let ringSamples = 8
        let collapsed = geometry.collapsedNotchSize
        let ring = VStack(spacing: 12) {
            ForEach(0 ..< ringSamples, id: \.self) { index in
                AttentionRingView(
                    shape: NotchShape(
                        topCornerRadius: Theme.Metrics.collapsedTopCornerRadius,
                        bottomCornerRadius: Theme.Metrics.collapsedBottomCornerRadius
                    ),
                    tint: Theme.Colors.Status.needsApproval,
                    debugPhase: CGFloat(index) / CGFloat(ringSamples)
                )
                .frame(width: collapsed.width + 80, height: collapsed.height)
            }
        }
        .padding(20)
        // Mid-grey behind the silhouette, so the glow outside the rim is legible instead of
        // being black light on a black ground.
        .background(Color(white: 0.18))
        .environment(\.colorScheme, .dark)

        write(ring, to: directory, name: "motion-ring.png")

        return 2
    }

    /// The resting states, which the progress sweep above cannot reach: it pins the coordinator
    /// to `.expanded` and only varies the aperture, so it renders expanded content squeezed into
    /// a collapsed box rather than the collapsed surface itself. These are also the frames worth
    /// eyeballing after a visual change, since the pill is what is on screen ~all of the time.
    private static func writeScenarios(to directory: URL, geometry: ScreenGeometry) -> Int {
        let scenarios: [(
            name: String,
            surface: NotchSurface,
            state: NotchState,
            store: AgentSessionStore,
            services: SystemServices,
            showsSettings: Bool
        )] = [
            // Nothing live. The silhouette must be exactly the hardware cutout here — this is
            // the frame that catches a resting notch that has quietly grown wider.
            (
                "collapsed-idle",
                .media,
                .collapsed,
                AgentsPreviewData.emptyStore(),
                SystemServices(nowPlaying: MediaPreviewData.inactiveMonitor(), systemHUD: .previewIdle()),
                false
            ),
            (
                "collapsed-agents",
                .agents,
                .collapsed,
                AgentsPreviewData.concurrentStore(),
                SystemServices(nowPlaying: MediaPreviewData.inactiveMonitor(), systemHUD: .previewIdle()),
                false
            ),
            (
                "collapsed-approval",
                .agents,
                .collapsed,
                AgentsPreviewData.approvalStore(),
                SystemServices(nowPlaying: MediaPreviewData.inactiveMonitor(), systemHUD: .previewIdle()),
                false
            ),
            (
                "expanded-working",
                .agents,
                .expanded,
                AgentsPreviewData.workingStore(),
                SystemServices(nowPlaying: MediaPreviewData.inactiveMonitor(), systemHUD: .previewIdle()),
                false
            ),
            (
                "expanded-agents",
                .agents,
                .expanded,
                AgentsPreviewData.concurrentStore(),
                SystemServices(nowPlaying: MediaPreviewData.inactiveMonitor(), systemHUD: .previewIdle()),
                false
            ),
            (
                "expanded-approval",
                .agents,
                .expanded,
                AgentsPreviewData.approvalStore(),
                SystemServices(nowPlaying: MediaPreviewData.inactiveMonitor(), systemHUD: .previewIdle()),
                false
            ),
            // The same surface with a *nested* tool input and an elapsed label that has rolled
            // past an hour. This is the frame that would have caught the card rendering raw
            // JSON and hanging its buttons off the bottom curve — the scenario above could not,
            // because its preview input was a plain string.
            (
                "expanded-approval-question",
                .agents,
                .expanded,
                AgentsPreviewData.questionApprovalStore(),
                SystemServices(nowPlaying: MediaPreviewData.inactiveMonitor(), systemHUD: .previewIdle()),
                false
            ),
            // A session with subagents under it. See `AgentsPreviewData.subagentStore`.
            (
                "expanded-subagents",
                .agents,
                .expanded,
                AgentsPreviewData.subagentStore(),
                SystemServices(nowPlaying: MediaPreviewData.inactiveMonitor(), systemHUD: .previewIdle()),
                false
            ),
            (
                "collapsed-media-playing",
                .media,
                .collapsed,
                AgentsPreviewData.emptyStore(),
                SystemServices(nowPlaying: MediaPreviewData.playingMonitor(), systemHUD: .previewIdle()),
                false
            ),
            (
                "collapsed-media-and-agents",
                .media,
                .collapsed,
                AgentsPreviewData.concurrentStore(),
                SystemServices(nowPlaying: MediaPreviewData.playingMonitor(), systemHUD: .previewIdle()),
                false
            ),
            // Was `collapsed-media-long-title`, back when the trailing shoulder held the title
            // and the longest one on record was the worst case for the housing. The shoulder
            // holds the waveform now, so title length cannot collide with anything; what *can*
            // is the paused state, which swaps both shoulders' marks at once.
            (
                "collapsed-media-paused",
                .media,
                .collapsed,
                AgentsPreviewData.emptyStore(),
                SystemServices(nowPlaying: MediaPreviewData.pausedMonitor(), systemHUD: .previewIdle()),
                false
            ),
            // The HUD borrows the same shoulders, so it is subject to the same housing rule as
            // every live activity — and it is the one surface the user summons deliberately,
            // which makes a collision here the most visible kind.
            (
                "collapsed-hud-volume",
                .media,
                .collapsed,
                AgentsPreviewData.emptyStore(),
                SystemServices(
                    nowPlaying: MediaPreviewData.inactiveMonitor(),
                    systemHUD: .preview(.volume(level: 0.68, isMuted: false))
                ),
                false
            ),
            (
                "collapsed-hud-brightness",
                .media,
                .collapsed,
                AgentsPreviewData.emptyStore(),
                SystemServices(
                    nowPlaying: MediaPreviewData.inactiveMonitor(),
                    systemHUD: .preview(.brightness(level: 0.42))
                ),
                false
            ),
            // A HUD arriving over a playing track. The HUD outranks the live activity, so this
            // must render as the HUD alone — a frame with artwork *and* a level bar on the same
            // shoulder is the defect.
            (
                "collapsed-hud-over-media",
                .media,
                .collapsed,
                AgentsPreviewData.concurrentStore(),
                SystemServices(
                    nowPlaying: MediaPreviewData.playingMonitor(),
                    systemHUD: .preview(.volume(level: 0.15, isMuted: true))
                ),
                false
            ),
            (
                "expanded-media-playing",
                .media,
                .expanded,
                AgentsPreviewData.emptyStore(),
                SystemServices(nowPlaying: MediaPreviewData.playingMonitor(), systemHUD: .previewIdle()),
                false
            ),
            (
                "expanded-media-paused",
                .media,
                .expanded,
                AgentsPreviewData.emptyStore(),
                SystemServices(nowPlaying: MediaPreviewData.pausedMonitor(), systemHUD: .previewIdle()),
                false
            ),
            (
                "expanded-media-empty",
                .media,
                .expanded,
                AgentsPreviewData.emptyStore(),
                SystemServices(nowPlaying: MediaPreviewData.inactiveMonitor(), systemHUD: .previewIdle()),
                false
            ),
            // No sessions, with a mix of connected, failed and missing agents — the provider
            // lines are what has to fit under the head row without reaching the bottom curve.
            (
                "expanded-agents-empty",
                .agents,
                .expanded,
                AgentsPreviewData.emptyStore(),
                {
                    let services = SystemServices(nowPlaying: MediaPreviewData.inactiveMonitor(), systemHUD: .previewIdle())
                    #if DEBUG
                    services.integrations.seedPreviewStatuses(AgentsPreviewData.detectedIntegrations().statuses)
                    #endif
                    return services
                }(),
                false
            ),
            // The tightest vertical budget in the app: every preference the app has, laid out
            // inside the same 190pt panel as everything else, with no scroll view to overflow
            // into. This frame is the check that it still fits — a preference added without
            // retiring one shows up here as a clipped bottom row and nowhere else.
            (
                "expanded-settings",
                .agents,
                .expanded,
                AgentsPreviewData.concurrentStore(),
                SystemServices(nowPlaying: MediaPreviewData.playingMonitor(), systemHUD: .previewIdle()),
                true
            ),
        ]

        let tradingScenarios: [(name: String, surface: NotchSurface, state: NotchState, store: AgentSessionStore, services: SystemServices, showsSettings: Bool)] = [
            ("expanded-trading-empty", .trading, .expanded, AgentsPreviewData.emptyStore(), SystemServices(nowPlaying: MediaPreviewData.inactiveMonitor(), systemHUD: .previewIdle()), false),
            ("expanded-trading-watchlist", .trading, .expanded, AgentsPreviewData.emptyStore(), SystemServices(nowPlaying: MediaPreviewData.inactiveMonitor(), systemHUD: .previewIdle(), trading: TradingPreviewData.populatedStore()), false),
            ("collapsed-trading", .trading, .collapsed, AgentsPreviewData.emptyStore(), SystemServices(nowPlaying: MediaPreviewData.inactiveMonitor(), systemHUD: .previewIdle(), trading: TradingPreviewData.populatedStore()), false),
        ]
        for scenario in scenarios + tradingScenarios {
            let coordinator = NotchCoordinator(
                state: scenario.state,
                currentSurface: scenario.surface,
                collapsedSize: geometry.collapsedNotchSize,
                hasPhysicalNotch: geometry.hasPhysicalNotch
            )

            // Seeded here, deliberately, and not left to `NotchRootView.onAppear`.
            //
            // `ImageRenderer` does not run `onAppear`, so the flags the root view normally
            // sets there stay false — which now means `liveActivityLayout` reports `.idle` and
            // every collapsed scenario renders an empty pill. The housing check would then
            // pass on all of them for the worst possible reason: there is no ink to collide.
            // A silent pass is worse than a failure, so the dump seeds what the running app
            // would have observed.
            //
            // Seeded through `NotchSettings`, not from the monitors directly. The two answers
            // are no longer the same: a *paused* player is `isActive` but does not earn a
            // shoulder, so reading the monitor here would render a widened silhouette for a
            // state the running app draws as a bare notch — and the housing check would then be
            // verifying a frame that cannot occur.
            let settings = scenario.services.settings
            coordinator.hasMediaActivity = settings.showsMedia(
                scenario.services.nowPlaying.status
            )
            coordinator.hasAgentActivity = settings.showsAgents(
                sessionCount: scenario.store.sessions.count
            )
            coordinator.hasSystemHUD = settings.replaceSystemHUD
                && scenario.services.systemHUD.event != nil
            coordinator.hasTradingActivity = scenario.services.trading.wantsShoulder
            coordinator.agentNeedsAttention = !scenario.store.pendingApprovals.isEmpty || scenario.store.sessions.contains { $0.status.demandsAttention }

            let view = NotchRootView(
                coordinator: coordinator,
                store: scenario.store,
                services: scenario.services,
                debugShowsSettings: scenario.showsSettings
            )
            .frame(width: geometry.panelFrame.width, height: geometry.panelFrame.height)
            .background(Color(white: 0.42))

            write(view, to: directory, name: "scenario-\(scenario.name).png")
        }

        return scenarios.count + tradingScenarios.count
    }

    private static func aperture(at progress: CGFloat, collapsed: CGSize) -> CGSize {
        let expanded = Theme.Metrics.expandedNotchSize
        return CGSize(
            width: collapsed.width + (expanded.width - collapsed.width) * progress,
            height: collapsed.height + (expanded.height - collapsed.height) * progress
        )
    }

    private static func write(_ view: some View, to directory: URL, name: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            FileHandle.standardError.write(Data("FrameDump: render failed for \(name)\n".utf8))
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: directory.appendingPathComponent(name))
    }
}
