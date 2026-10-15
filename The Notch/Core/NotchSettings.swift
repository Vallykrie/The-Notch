import Combine
import Foundation
import ServiceManagement

/// Every user-facing preference, and the defaults that define "The Notch as shipped".
///
/// One object rather than a preference read at each call site, for two reasons. The obvious one
/// is `restoreDefaults()`: "put it back the way it was" is only implementable if something knows
/// the whole set. The less obvious one is that most of these preferences change something
/// *outside* SwiftUI — a CoreAudio listener, an event tap, a login item — so a change has to be
/// announced to `AppDelegate` as well as re-rendered. ``revision`` and ``onChange`` are those two
/// channels, and both fire from the same place so they can never disagree.
///
/// Storage is `UserDefaults`, keyed by the `Key` enum below. Nothing else in the app may write
/// those keys; `SoundEffects` owns `NotchSoundEffectsEnabled` and this object mirrors it rather
/// than duplicating it — see ``soundCuesEnabled``.
@MainActor
final class NotchSettings: ObservableObject {
    // MARK: Features
    //
    // A feature switched off is *off*, not hidden: its tab goes, its shoulder goes, and the
    // monitor behind it stops — no player is scripted, no price socket is open, and the hook
    // socket closes so agent hooks fail open straight back to the agent's own prompt. Someone
    // who installed The Notch for one of the three should not pay for the other two.

    /// Now playing: the media tab, its shoulder, the lyric pill, and the player polling.
    @Published var mediaEnabled: Bool { didSet { commit(mediaEnabled, .mediaEnabled) } }

    /// Coding agents: the agents tab, its shoulder, approvals, and the hook socket.
    @Published var agentsEnabled: Bool { didSet { commit(agentsEnabled, .agentsEnabled) } }

    /// The crypto watchlist: its tab, the pinned price, and the price feed.
    @Published var cryptoEnabled: Bool { didSet { commit(cryptoEnabled, .cryptoEnabled) } }

    /// The calendar: its tab and the EventKit observers behind it.
    @Published var calendarEnabled: Bool { didSet { commit(calendarEnabled, .calendarEnabled) } }

    // MARK: Calendar

    /// Whether all-day events (holidays, birthdays, "Out of office") are listed.
    @Published var calendarShowsAllDay: Bool { didSet { commit(calendarShowsAllDay, .calendarShowsAllDay) } }

    // MARK: Media

    /// Whether media earns a collapsed shoulder at all.
    @Published var showMediaActivity: Bool { didSet { commit(showMediaActivity, .showMediaActivity) } }

    /// Whether a *paused* player still counts as live.
    ///
    /// Defaults to true, which is the behaviour the app ships with: a paused track is not an
    /// activity, and leaving the shoulders out for it parks a widened silhouette over the menu
    /// bar for as long as the player happens to be open — which is the exact failure the
    /// "shoulders are earned" rule in `LiveActivityLayout` exists to prevent.
    @Published var hideMediaWhenPaused: Bool { didSet { commit(hideMediaWhenPaused, .hideMediaWhenPaused) } }

    /// Whether the sung line floats in the pill under the collapsed notch. The lyrics button in
    /// the media panel still decides whether lyrics are fetched at all; this only keeps them
    /// off the desktop for someone who wants them in the panel and nowhere else.
    @Published var lyricsOnNotch: Bool { didSet { commit(lyricsOnNotch, .lyricsOnNotch) } }

    /// Which players The Notch reads. A player left out is never scripted, so it never raises
    /// an Automation prompt either.
    @Published var mediaPlayers: MediaPlayers { didSet { commit(mediaPlayers.rawValue, .mediaPlayers) } }

    // MARK: Agents

    /// Whether agent sessions earn a collapsed shoulder.
    @Published var showAgentActivity: Bool { didSet { commit(showAgentActivity, .showAgentActivity) } }

    /// The travelling light around the silhouette while an approval is blocking.
    @Published var showAttentionRing: Bool { didSet { commit(showAttentionRing, .showAttentionRing) } }

    /// Whether a session row names its model (`Opus 4.5`) beside the app it runs in. Off by
    /// default: the app is what tells two sessions apart at a glance, and the model is detail
    /// most people only want once they run several models side by side.
    @Published var showAgentModel: Bool { didSet { commit(showAgentModel, .showAgentModel) } }

    /// Whether an approval or a question opens the notch by itself. Off, the notch stays
    /// closed and the attention ring and the sound carry the request instead — for someone
    /// who would rather not have a panel spring open over what they are reading.
    @Published var openOnApproval: Bool { didSet { commit(openOnApproval, .openOnApproval) } }

    /// Mirrors `SoundEffects.isEnabled` rather than shadowing it. That object already owns the
    /// key and reads it on every cue; a second copy here would go stale the moment either side
    /// wrote without the other.
    @Published var soundCuesEnabled: Bool {
        didSet {
            SoundEffects.shared.isEnabled = soundCuesEnabled
            bump()
        }
    }

    /// Whether a run finishing breathes the notch out and drops confetti. It never opens the
    /// notch. Off leaves only the sound cue — for someone running agents
    /// back to back, a celebration every few minutes is a lot.
    @Published var celebrateFinishedRuns: Bool {
        didSet { commit(celebrateFinishedRuns, .celebrateFinishedRuns) }
    }

    /// How long a finished session stays in the panel before it is pruned.
    @Published var finishedRetention: FinishedRetention {
        didSet { commit(finishedRetention.rawValue, .finishedRetention) }
    }

    // MARK: System HUD

    /// Whether the notch replaces macOS's own volume and brightness readout.
    ///
    /// Turning this off stops the level monitor *and* the media-key tap, so the system draws its
    /// own HUD again. It does not restore `OSDUIHelper` on its own — `AppDelegate` does that,
    /// because the suppression is a machine-wide side effect and only one place should own it.
    @Published var replaceSystemHUD: Bool { didSet { commit(replaceSystemHUD, .replaceSystemHUD) } }

    /// How long the level readout stays after the last change.
    @Published var hudDwell: HUDDwell { didSet { commit(hudDwell.rawValue, .hudDwell) } }

    // MARK: Appearance

    /// How big the expanded panel is. Large is the panel as designed; the others scale it down
    /// whole — see `Theme.Metrics.panelScaleSmall`. The collapsed notch never changes size: it
    /// is drawn to the hardware cutout, and a smaller one would leave the camera uncovered.
    @Published var panelSize: PanelSize { didSet { commit(panelSize.rawValue, .panelSize) } }

    /// Whether the panel opens and closes with motion at all. Off, it appears and disappears
    /// outright, and the attention flourishes (pops, drips, confetti) are skipped — the same
    /// treatment the system Reduce Motion setting gets.
    @Published var animationsEnabled: Bool { didSet { commit(animationsEnabled, .animationsEnabled) } }

    /// How fast the panel opens and closes.
    @Published var animationSpeed: AnimationSpeed {
        didSet { commit(animationSpeed.rawValue, .animationSpeed) }
    }

    /// The soft shadow the open panel casts onto the desktop.
    @Published var panelShadow: Bool { didSet { commit(panelShadow, .panelShadow) } }

    // MARK: Behaviour

    /// Whether the pointer arriving over the notch expands it. With this off the notch only
    /// opens when it is clicked, which is the right trade for someone whose menu bar is busy
    /// enough that they cross the notch constantly.
    @Published var expandOnHover: Bool { didSet { commit(expandOnHover, .expandOnHover) } }

    /// How eagerly hover expansion fires, and how long the grace zone lasts on the way out.
    @Published var hoverSensitivity: HoverSensitivity {
        didSet { commit(hoverSensitivity.rawValue, .hoverSensitivity) }
    }

    /// Registered with `SMAppService`, so this is a real login item and not a preference the app
    /// merely remembers. The setter reflects what the service *actually* reports afterwards —
    /// registration can be refused, and a switch that lies about it is worse than no switch.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != Self.isRegisteredAsLoginItem() else { bump(); return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    // MARK: First launch and consent
    //
    // State the app records about the user rather than preferences they set, so Restore
    // Defaults leaves all three alone: putting the switches back must not replay the intro or
    // forget that the user said no to having their agent config touched.

    /// Whether the first-launch intro has played to the end.
    @Published var hasSeenIntro: Bool {
        didSet { defaults.set(hasSeenIntro, forKey: StateKey.hasSeenIntro.rawValue) }
    }

    /// Whether the user has agreed to The Notch adding its hook to their agents' config.
    ///
    /// Nothing is installed until this is `.granted`. It used to be implied: every detected
    /// agent was hooked up on launch, which wrote to `~/.claude/settings.json` before the user
    /// had seen a single pixel of the app.
    @Published var agentHookConsent: AgentHookConsent {
        didSet {
            defaults.set(agentHookConsent.rawValue, forKey: StateKey.agentHookConsent.rawValue)
            bump()
        }
    }

    /// Agents the user unticked when they agreed. Consent is for the set they left ticked.
    @Published var declinedAgentHooks: Set<String> {
        didSet {
            defaults.set(declinedAgentHooks.sorted(), forKey: StateKey.declinedAgentHooks.rawValue)
            bump()
        }
    }

    // MARK: Change notification

    /// Bumped on every change. Views observe this one value rather than one per preference.
    @Published private(set) var revision: Int = 0

    /// Called after `revision` is bumped, for the things SwiftUI cannot re-render: the level
    /// monitor, the media-key tap, and the session store's retention window.
    var onChange: (() -> Void)?

    private let defaults: UserDefaults

    // MARK: Lifecycle

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Self.registeredDefaults)

        // Direct assignment inside `init` does not run `didSet`, which is exactly what is wanted
        // here: loading stored values must not write them straight back, nor announce a change
        // to an `onChange` that has not been installed yet.
        mediaEnabled = defaults.bool(forKey: Key.mediaEnabled.rawValue)
        agentsEnabled = defaults.bool(forKey: Key.agentsEnabled.rawValue)
        cryptoEnabled = defaults.bool(forKey: Key.cryptoEnabled.rawValue)
        calendarEnabled = defaults.bool(forKey: Key.calendarEnabled.rawValue)
        calendarShowsAllDay = defaults.bool(forKey: Key.calendarShowsAllDay.rawValue)
        showMediaActivity = defaults.bool(forKey: Key.showMediaActivity.rawValue)
        hideMediaWhenPaused = defaults.bool(forKey: Key.hideMediaWhenPaused.rawValue)
        lyricsOnNotch = defaults.bool(forKey: Key.lyricsOnNotch.rawValue)
        mediaPlayers = MediaPlayers(
            rawValue: defaults.string(forKey: Key.mediaPlayers.rawValue) ?? ""
        ) ?? .default
        showAgentActivity = defaults.bool(forKey: Key.showAgentActivity.rawValue)
        showAttentionRing = defaults.bool(forKey: Key.showAttentionRing.rawValue)
        showAgentModel = defaults.bool(forKey: Key.showAgentModel.rawValue)
        openOnApproval = defaults.bool(forKey: Key.openOnApproval.rawValue)
        celebrateFinishedRuns = defaults.bool(forKey: Key.celebrateFinishedRuns.rawValue)
        hasSeenIntro = defaults.bool(forKey: StateKey.hasSeenIntro.rawValue)
        agentHookConsent = AgentHookConsent(
            rawValue: defaults.string(forKey: StateKey.agentHookConsent.rawValue) ?? ""
        ) ?? .undecided
        declinedAgentHooks = Set(defaults.stringArray(forKey: StateKey.declinedAgentHooks.rawValue) ?? [])
        soundCuesEnabled = defaults.bool(forKey: SoundEffects.enabledDefaultsKey)
        finishedRetention = FinishedRetention(
            rawValue: defaults.string(forKey: Key.finishedRetention.rawValue) ?? ""
        ) ?? .default
        replaceSystemHUD = defaults.bool(forKey: Key.replaceSystemHUD.rawValue)
        hudDwell = HUDDwell(
            rawValue: defaults.string(forKey: Key.hudDwell.rawValue) ?? ""
        ) ?? .default
        panelSize = PanelSize(
            rawValue: defaults.string(forKey: Key.panelSize.rawValue) ?? ""
        ) ?? .default
        animationsEnabled = defaults.bool(forKey: Key.animationsEnabled.rawValue)
        animationSpeed = AnimationSpeed(
            rawValue: defaults.string(forKey: Key.animationSpeed.rawValue) ?? ""
        ) ?? .default
        panelShadow = defaults.bool(forKey: Key.panelShadow.rawValue)
        expandOnHover = defaults.bool(forKey: Key.expandOnHover.rawValue)
        hoverSensitivity = HoverSensitivity(
            rawValue: defaults.string(forKey: Key.hoverSensitivity.rawValue) ?? ""
        ) ?? .default
        // Never persisted. The login-item database is the truth, and a remembered "true" against
        // a registration the user revoked in System Settings would show a switch that is on
        // while the app does not launch.
        launchAtLogin = Self.isRegisteredAsLoginItem()
    }

    /// A settings object that writes nowhere. Used by `FrameDump` and previews, which build real
    /// views and must not leave preferences behind on the machine that rendered them.
    static func ephemeral() -> NotchSettings {
        NotchSettings(
            defaults: UserDefaults(suiteName: "com.thenotch.TheNotch.ephemeral") ?? .standard
        )
    }

    // MARK: Defaults

    /// "The Notch as shipped." The Restore defaults button in the settings panel puts every
    /// value below back, and this dictionary is also what `UserDefaults.register` seeds a first
    /// launch with — so there is exactly one statement of what the default behaviour is.
    ///
    /// `launchAtLogin` is deliberately absent: it is not a stored preference, and restoring
    /// defaults must not silently unregister a login item the user set up on purpose.
    private static var registeredDefaults: [String: Any] {
        [
            Key.mediaEnabled.rawValue: true,
            Key.agentsEnabled.rawValue: true,
            Key.cryptoEnabled.rawValue: true,
            Key.calendarEnabled.rawValue: true,
            Key.calendarShowsAllDay.rawValue: true,
            Key.showMediaActivity.rawValue: true,
            Key.hideMediaWhenPaused.rawValue: true,
            Key.lyricsOnNotch.rawValue: true,
            Key.mediaPlayers.rawValue: MediaPlayers.default.rawValue,
            Key.openOnApproval.rawValue: true,
            Key.showAgentActivity.rawValue: true,
            Key.showAttentionRing.rawValue: true,
            Key.showAgentModel.rawValue: false,
            Key.celebrateFinishedRuns.rawValue: true,
            Key.replaceSystemHUD.rawValue: true,
            Key.panelSize.rawValue: PanelSize.default.rawValue,
            Key.animationsEnabled.rawValue: true,
            Key.animationSpeed.rawValue: AnimationSpeed.default.rawValue,
            Key.panelShadow.rawValue: true,
            Key.expandOnHover.rawValue: true,
            Key.finishedRetention.rawValue: FinishedRetention.default.rawValue,
            Key.hudDwell.rawValue: HUDDwell.default.rawValue,
            Key.hoverSensitivity.rawValue: HoverSensitivity.default.rawValue,
            SoundEffects.enabledDefaultsKey: true,
        ]
    }

    /// Whether every preference currently matches the shipped behaviour. The Restore defaults
    /// button reads this so it can dim itself rather than pretending there is something to undo.
    var isAtDefaults: Bool {
        mediaEnabled
            && agentsEnabled
            && cryptoEnabled
            && calendarEnabled
            && calendarShowsAllDay
            && showMediaActivity
            && hideMediaWhenPaused
            && lyricsOnNotch
            && mediaPlayers == .default
            && openOnApproval
            && showAgentActivity
            && showAttentionRing
            && !showAgentModel
            && celebrateFinishedRuns
            && soundCuesEnabled
            && finishedRetention == .default
            && replaceSystemHUD
            && hudDwell == .default
            && panelSize == .default
            && animationsEnabled
            && animationSpeed == .default
            && panelShadow
            && expandOnHover
            && hoverSensitivity == .default
    }

    func restoreDefaults() {
        for key in Key.allCases {
            defaults.removeObject(forKey: key.rawValue)
        }
        defaults.removeObject(forKey: SoundEffects.enabledDefaultsKey)
        defaults.register(defaults: Self.registeredDefaults)

        // Assigned through the properties, not the backing store, so every observer sees the
        // reset. `bump()` fires once per assignment; that is a handful of no-op refreshes on a
        // button the user presses once, which is cheaper than a second write path to get wrong.
        mediaEnabled = true
        agentsEnabled = true
        cryptoEnabled = true
        calendarEnabled = true
        calendarShowsAllDay = true
        showMediaActivity = true
        hideMediaWhenPaused = true
        lyricsOnNotch = true
        mediaPlayers = .default
        openOnApproval = true
        showAgentActivity = true
        showAttentionRing = true
        showAgentModel = false
        celebrateFinishedRuns = true
        soundCuesEnabled = true
        finishedRetention = .default
        replaceSystemHUD = true
        hudDwell = .default
        panelSize = .default
        animationsEnabled = true
        animationSpeed = .default
        panelShadow = true
        expandOnHover = true
        hoverSensitivity = .default
    }

    /// The motion preferences, as the shell consumes them.
    var motion: Theme.Motion.Preference {
        Theme.Motion.Preference(isAnimated: animationsEnabled, speed: animationSpeed)
    }

    /// How much the expanded panel is scaled from its designed size.
    var panelScale: CGFloat {
        switch panelSize {
        case .small: Theme.Metrics.panelScaleSmall
        case .medium: Theme.Metrics.panelScaleMedium
        case .large: 1
        }
    }

    // MARK: Derived policy
    //
    // The rules below live here rather than in the views that ask them, because more than one
    // surface asks and a second copy is how the collapsed silhouette and its content come to
    // disagree — see `LiveActivityLayout`'s header for what that costs.

    /// Whether this now-playing state earns a collapsed shoulder.
    ///
    /// A paused player is not, by default, an activity. `NowPlayingStatus.isActive` only says a
    /// supported player is running with a track loaded, which stays true for hours after the
    /// music stops.
    func showsMedia(_ status: NowPlayingStatus) -> Bool {
        guard mediaEnabled, showMediaActivity, status.isActive else { return false }
        return status.isPlaying || !hideMediaWhenPaused
    }

    func showsAgents(sessionCount: Int) -> Bool {
        agentsEnabled && showAgentActivity && sessionCount > 0
    }

    /// Whether a surface's feature is switched on. A surface whose feature is off has no tab.
    func isEnabled(_ surface: NotchSurface) -> Bool {
        switch surface {
        case .media: mediaEnabled
        case .agents: agentsEnabled
        case .trading: cryptoEnabled
        case .calendar: calendarEnabled
        }
    }

    /// The tabs the expanded panel offers, in tab-bar order.
    var enabledSurfaces: [NotchSurface] {
        NotchSurface.allCases.filter(isEnabled)
    }

    // MARK: Storage

    private enum Key: String, CaseIterable {
        case mediaEnabled = "NotchMediaEnabled"
        case agentsEnabled = "NotchAgentsEnabled"
        case cryptoEnabled = "NotchCryptoEnabled"
        case calendarEnabled = "NotchCalendarEnabled"
        case calendarShowsAllDay = "NotchCalendarShowsAllDay"
        case showMediaActivity = "NotchShowMediaActivity"
        case hideMediaWhenPaused = "NotchHideMediaWhenPaused"
        case lyricsOnNotch = "NotchLyricsOnNotch"
        case mediaPlayers = "NotchMediaPlayers"
        case openOnApproval = "NotchOpenOnApproval"
        case showAgentActivity = "NotchShowAgentActivity"
        case showAttentionRing = "NotchShowAttentionRing"
        case showAgentModel = "NotchShowAgentModel"
        case celebrateFinishedRuns = "NotchCelebrateFinishedRuns"
        case finishedRetention = "NotchFinishedSessionRetention"
        case replaceSystemHUD = "NotchReplaceSystemHUD"
        case hudDwell = "NotchHUDDwell"
        case panelSize = "NotchPanelSize"
        case animationsEnabled = "NotchAnimationsEnabled"
        case animationSpeed = "NotchAnimationSpeed"
        case panelShadow = "NotchPanelShadow"
        case expandOnHover = "NotchExpandOnHover"
        case hoverSensitivity = "NotchHoverSensitivity"
    }

    /// Not in `Key`, so `restoreDefaults()` never touches them — see "First launch and consent".
    private enum StateKey: String {
        case hasSeenIntro = "NotchHasSeenIntro"
        case agentHookConsent = "NotchAgentHookConsent"
        case declinedAgentHooks = "NotchDeclinedAgentHooks"
    }

    private func commit(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
        bump()
    }

    private func bump() {
        revision &+= 1
        onChange?()
    }

    // MARK: Login item

    private static func isRegisteredAsLoginItem() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registration is asynchronous in the sense that it can fail *and* leave the switch on, so
    /// the published value is rewritten from the service afterwards either way. Rewriting it
    /// re-enters `didSet`, which is why the setter's first line short-circuits when the value
    /// already agrees with the service.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("The Notch: could not change the login item: \(error.localizedDescription)")
        }
        launchAtLogin = Self.isRegisteredAsLoginItem()
    }
}

/// Whether The Notch may add its hook to the user's agent config. See
/// `NotchSettings.agentHookConsent`.
enum AgentHookConsent: String {
    case undecided
    case granted
    case declined
}

// MARK: - Multi-choice options
//
// Each of these is a small closed set rather than a slider, because every value has to be one
// the app was actually tuned at. The concrete durations live in `Theme` and in
// `AgentSessionStore` alongside the code that consumes them; these enums only name the choices.

nonisolated enum FinishedRetention: String, CaseIterable, Identifiable, Sendable {
    case short
    case standard
    case long
    case keep

    static let `default` = FinishedRetention.standard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .short: "5 min"
        case .standard: "15 min"
        case .long: "1 hour"
        case .keep: "Keep"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .short: 5 * 60
        case .standard: AgentSessionStore.defaultDoneSessionRetention
        case .long: 60 * 60
        // Not `.infinity`: `Date.addingTimeInterval(-.infinity)` is not a usable date, and the
        // prune cutoff is computed by subtraction. A decade outlives any session.
        case .keep: 10 * 365 * 24 * 60 * 60
        }
    }
}

nonisolated enum MediaPlayers: String, CaseIterable, Identifiable, Sendable {
    case all
    case music
    case spotify

    static let `default` = MediaPlayers.all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .music: "Music"
        case .spotify: "Spotify"
        }
    }

    var players: Set<NowPlayingStatus.Player> {
        switch self {
        case .all: [.music, .spotify]
        case .music: [.music]
        case .spotify: [.spotify]
        }
    }

    /// Browsers and every other app MediaRemote reports. "All" means all of them; picking one
    /// player means only that player.
    var allowsOtherApps: Bool {
        self == .all
    }
}

nonisolated enum HUDDwell: String, CaseIterable, Identifiable, Sendable {
    case brief
    case standard
    case long

    static let `default` = HUDDwell.standard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .brief: "0.8s"
        case .standard: "1.5s"
        case .long: "3.0s"
        }
    }
}

nonisolated enum HoverSensitivity: String, CaseIterable, Identifiable, Sendable {
    case instant
    case standard
    case relaxed

    static let `default` = HoverSensitivity.standard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .instant: "Instant"
        case .standard: "Normal"
        case .relaxed: "Relaxed"
        }
    }
}

nonisolated enum PanelSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    static let `default` = PanelSize.large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        }
    }
}

nonisolated enum AnimationSpeed: String, CaseIterable, Identifiable, Sendable {
    case slow
    case normal
    case fast

    static let `default` = AnimationSpeed.normal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .slow: "Slow"
        case .normal: "Normal"
        case .fast: "Fast"
        }
    }

    /// Passed to `Animation.speed(_:)`: above 1 runs faster.
    var multiplier: Double {
        switch self {
        case .slow: 0.7
        case .normal: 1
        case .fast: 1.5
        }
    }
}
