import SwiftUI

/// The first-launch intro, as a script.
///
/// It plays entirely inside the notch: the notch melts, opens into a band of drifting stars,
/// the stars gather into the mascot, the mascot says hello and asks before touching anyone's
/// agent config, and then comes apart and rebuilds itself, tiny, on the shoulder while the band
/// closes. A drop falls off the notch and becomes a hint about how to open it.
///
/// The ask is the point; the rest earns the user's attention for it. Until the user answers,
/// nothing is written to `~/.claude/settings.json` or anywhere else — see
/// `NotchSettings.agentHookConsent`. The copy says what is touched, that other hooks stay, and
/// that a backup is made, because that is the promise `HookInstaller` actually keeps.
///
/// One beat after another in a single `async` function, so the timing reads top to bottom and
/// every wait is a named token in `Theme.Motion.Onboarding`.
@Observable
@MainActor
final class OnboardingDirector {
    /// What the director needs from the root view that only the root view can do: change the
    /// notch's state on a particular animation, and kick the bottom edge.
    struct Stage {
        let change: (NotchState, Animation) -> Void
        let kickBelly: (CGFloat) -> Void
    }

    enum Beat: Equatable {
        case intro
        case greeting
        case consent
        case leaving
    }

    struct Row: Identifiable {
        let agent: AgentCLI
        var isOn: Bool
        /// Already hooked up before the intro asked — by an older version, or by hand.
        let wasConnected: Bool
        var connectedAt: TimeInterval?
        var error: String?
        var id: String { agent.rawValue }
    }

    private(set) var beat: Beat = .intro
    private(set) var greetingAt: TimeInterval?
    private(set) var subtitleAt: TimeInterval?
    private(set) var rows: [Row] = []
    private(set) var afterword: String?
    private(set) var afterwordAt: TimeInterval = 0
    private(set) var afterwordIsGood = true
    private(set) var hasAnswered = false

    private let fx: NotchFX
    private let coordinator: NotchCoordinator
    private let integrations: AgentIntegrationManager
    private let settings: NotchSettings
    private let reduceMotion: Bool
    private let stage: Stage
    private var answer: CheckedContinuation<Bool, Never>?

    init(
        fx: NotchFX,
        coordinator: NotchCoordinator,
        integrations: AgentIntegrationManager,
        settings: NotchSettings,
        reduceMotion: Bool,
        stage: Stage
    ) {
        self.fx = fx
        self.coordinator = coordinator
        self.integrations = integrations
        self.settings = settings
        self.reduceMotion = reduceMotion
        self.stage = stage
    }

    // MARK: Layout

    private var band: CGSize { Theme.Metrics.onboardingBandSize }
    private var layout: Theme.Metrics.Onboarding.Type { Theme.Metrics.Onboarding.self }

    /// A point in the band's own coordinates, in the panel's.
    private func panelPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: fx.centerX - band.width / 2 + point.x, y: point.y)
    }

    /// Whether the rows are split into two columns because there are too many for one.
    var isTwoColumn: Bool { rows.count > layout.singleColumnRows }

    /// The top-left of row `index`, in the band's coordinates. Shared with `OnboardingView`, so
    /// the pixels stream into exactly the checkbox the view drew.
    func rowOrigin(_ index: Int) -> CGPoint {
        let perColumn = isTwoColumn ? (rows.count + 1) / 2 : max(rows.count, 1)
        return CGPoint(
            x: layout.consentLeading + CGFloat(index / perColumn) * layout.columnWidth,
            y: layout.rowsTop + CGFloat(index % perColumn) * layout.rowHeight
        )
    }

    /// Where row `index`'s checkbox is, in panel space — where its stream of pixels lands.
    private func checkboxCenter(_ index: Int) -> CGPoint {
        let origin = rowOrigin(index)
        return panelPoint(CGPoint(x: origin.x + layout.checkboxSize / 2, y: origin.y + layout.rowHeight / 2))
    }

    private func moveMascot(to point: CGPoint) {
        guard var mascot = fx.bigMascot else { return }
        let now = NotchFX.now
        let target = panelPoint(point)
        mascot.x.rebase(at: now)
        mascot.y.rebase(at: now)
        mascot.x.retarget(target.x, at: now, .damped(Theme.Motion.Liquid.mascotSlide))
        mascot.y.retarget(target.y, at: now, .damped(Theme.Motion.Liquid.mascotSlide))
        fx.bigMascot = mascot
    }

    // MARK: The answer

    func toggle(_ row: Row) {
        guard !hasAnswered, !row.wasConnected, let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        rows[index].isOn.toggle()
    }

    func connect() {
        guard !hasAnswered else { return }
        hasAnswered = true
        answer?.resume(returning: true)
        answer = nil
    }

    func notNow() {
        guard !hasAnswered else { return }
        hasAnswered = true
        answer?.resume(returning: false)
        answer = nil
    }

    /// Whether the main button connects anything, or just carries on: when every detected
    /// agent is already hooked up there is nothing to agree to.
    var hasSomethingToConnect: Bool {
        rows.contains { !$0.wasConnected } || rows.isEmpty
    }

    // MARK: The script

    func run() async {
        let beats = Theme.Motion.Onboarding.self
        fx.reset()
        if coordinator.state == .expanded {
            stage.change(.collapsed, Theme.Motion.close)
            await pause(beats.toConsent)
        }
        // Detection only. Nothing is installed until the user says yes below.
        Task { await integrations.refresh() }
        await pause(beats.settle)

        // The notch melts: drops bead off its bottom edge.
        if !reduceMotion {
            fx.melt(from: fx.attachment(coordinator.collapsedSize, expanded: false))
            await pause(beats.melt)
        }

        // It swallows them and opens into the band, full of drifting stars.
        coordinator.setOnboarding(true)
        stage.change(.expanded, reduceMotion ? Theme.Motion.open : Theme.Motion.band)
        let bandRect = fx.silhouette(band).insetBy(dx: layout.starInset.width, dy: layout.starInset.height)
        if !reduceMotion {
            stage.kickBelly(Theme.Motion.Attention.popBelly)
            fx.swallowDrops(into: band.height * 0.56)
            fx.spawnStars(beats.starCount, in: bandRect, opacity: 0.35 ... 0.9, appearOver: 0.8)
            await pause(beats.starsIn)
        }

        // The stars gather into the mascot.
        let pixel = layout.mascotPixel
        let center = panelPoint(layout.mascotCenter)
        let origin = CGPoint(
            x: center.x - CGFloat(AgentActivityGlyph.columns) * pixel / 2,
            y: center.y - CGFloat(AgentActivityGlyph.rows) * pixel / 2
        )
        if !reduceMotion {
            fx.gatherStars(into: fx.cellCenters(of: NotchFX.restingCells, origin: origin, pixel: pixel), cellSize: pixel, tint: Theme.Colors.ink)
            await pause(beats.gather)
            fx.dropGatheredStars()
        }
        let now = NotchFX.now
        fx.bigMascot = NotchFX.BigMascot(
            x: Track(center.x),
            y: Track(center.y),
            hop: Track(0),
            pixel: pixel,
            tint: Theme.Colors.ink,
            born: now,
            flashAt: now
        )
        if !reduceMotion { fx.hopBigMascot() }
        SoundEffects.shared.play(.sessionFinished)
        await pause(beats.lookAround)
        fx.bigMascot?.followsPointer = true

        // Hello.
        beat = .greeting
        greetingAt = NotchFX.now
        await pause(beats.greetLine)
        subtitleAt = NotchFX.now
        await pause(beats.greetHold)

        // The ask.
        rows = integrations.detected.map { status in
            Row(
                agent: status.provider,
                isOn: !settings.declinedAgentHooks.contains(status.provider.rawValue),
                wasConnected: status.configured
            )
        }
        beat = .consent
        moveMascot(to: layout.mascotAsideCenter)
        #if DEBUG
        // `NOTCH_DEBUG_INTRO_ANSWER=later` answers "not now" by itself, so the whole intro can be
        // watched with `LiveCapture` without a click and without touching any agent config.
        if ProcessInfo.processInfo.environment["NOTCH_DEBUG_INTRO_ANSWER"] == "later" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                notNow()
            }
        }
        #endif
        let accepted = await withCheckedContinuation { answer = $0 }

        if accepted {
            fx.hopBigMascot(14)
            let declined = Set(rows.filter { !$0.isOn && !$0.wasConnected }.map(\.agent))
            let install = Task { await integrations.connect(excluding: declined) }
            let mascotCenter = panelPoint(layout.mascotAsideCenter)
            for (index, row) in rows.enumerated() where row.isOn && !row.wasConnected {
                let delay = Double(index) * 0.12
                let landing = reduceMotion
                    ? delay
                    : fx.stream(from: mascotCenter, to: checkboxCenter(index), tint: Theme.Colors.Status.done, delay: delay)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(landing))
                    guard index < rows.count else { return }
                    rows[index].connectedAt = NotchFX.now
                    fx.flashBigMascot()
                }
            }
            await pause(beats.connectStream)
            await install.value
            for index in rows.indices {
                rows[index].error = integrations.statuses.first { $0.provider == rows[index].agent }?.error
            }
            afterwordIsGood = !rows.contains { $0.error != nil }
            afterword = afterwordIsGood
                ? "connected. i'll tap you when they need you."
                : "couldn't hook one of them. settings › connections."
        } else {
            integrations.decline()
            fx.bigMascot?.status = .idle
            afterwordIsGood = false
            afterword = "no worries. settings › connections, any time."
        }
        afterwordAt = NotchFX.now
        await pause(beats.afterwordHold)

        // Goodbye: the mascot comes apart and rebuilds itself on the shoulder as the band closes.
        beat = .leaving
        fx.bigMascot?.followsPointer = false
        fx.bigMascot?.status = .waitingForInput
        moveMascot(to: layout.mascotCenter)
        fx.hidden.insert(.shoulder)
        coordinator.isWelcoming = true
        await pause(beats.toDissolve)
        if let mascot = fx.bigMascot {
            let shoulderPixel = (Theme.Metrics.Agents.mascotCollapsedSize / CGFloat(AgentActivityGlyph.rows)).rounded(.down)
            let collapsed = fx.silhouette(coordinator.collapsedSize)
            fx.bigMascot = nil
            if !reduceMotion {
                fx.transit(
                    cells: NotchFX.restingCells,
                    from: (mascot.origin(at: NotchFX.now), mascot.pixel),
                    to: .shoulder,
                    fallback: (CGPoint(x: collapsed.minX + 12, y: collapsed.minY + 6), shoulderPixel),
                    tint: Theme.Colors.ink,
                    upward: true
                )
            }
        }
        fx.fadeStars(over: 0.4)
        await pause(beats.dissolveLead)
        stage.change(.collapsed, Theme.Motion.bandClose)
        await pause(beats.landing)
        coordinator.setOnboarding(false)
        fx.hidden.remove(.shoulder)

        // The hint drips off the notch, waits, and is drunk back up.
        await pause(beats.beforeHint)
        fx.showPill(line: settings.expandOnHover ? "hover the notch to open" : "click the notch to open")
        await pause(beats.hintDwell)
        fx.hidePill()
        await pause(beats.afterHint)
        coordinator.isWelcoming = false
        settings.hasSeenIntro = true
    }

    private func pause(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}
