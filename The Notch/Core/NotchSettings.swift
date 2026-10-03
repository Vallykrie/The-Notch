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

    // MARK: Agents

    /// Whether agent sessions earn a collapsed shoulder.
    @Published var showAgentActivity: Bool { didSet { commit(showAgentActivity, .showAgentActivity) } }

    /// The travelling light around the silhouette while an approval is blocking.
    @Published var showAttentionRing: Bool { didSet { commit(showAttentionRing, .showAttentionRing) } }

    /// Whether a session row names its model (`Opus 4.5`) beside the app it runs in. Off by
    /// default: the app is what tells two sessions apart at a glance, and the model is detail
    /// most people only want once they run several models side by side.
    @Published var showAgentModel: Bool { didSet { commit(showAgentModel, .showAgentModel) } }

    /// Mirrors `SoundEffects.isEnabled` rather than shadowing it. That object already owns the
    /// key and reads it on every cue; a second copy here would go stale the moment either side
    /// wrote without the other.
    @Published var soundCuesEnabled: Bool {
        didSet {
            SoundEffects.shared.isEnabled = soundCuesEnabled
            bump()
        }
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

    // MARK: Change notification

    /// Bumped on every change. Views observe this one value rather than eleven separate ones.
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
        showMediaActivity = defaults.bool(forKey: Key.showMediaActivity.rawValue)
        hideMediaWhenPaused = defaults.bool(forKey: Key.hideMediaWhenPaused.rawValue)
        showAgentActivity = defaults.bool(forKey: Key.showAgentActivity.rawValue)
        showAttentionRing = defaults.bool(forKey: Key.showAttentionRing.rawValue)
        showAgentModel = defaults.bool(forKey: Key.showAgentModel.rawValue)
        soundCuesEnabled = defaults.bool(forKey: SoundEffects.enabledDefaultsKey)
        finishedRetention = FinishedRetention(
            rawValue: defaults.string(forKey: Key.finishedRetention.rawValue) ?? ""
        ) ?? .default
        replaceSystemHUD = defaults.bool(forKey: Key.replaceSystemHUD.rawValue)
        hudDwell = HUDDwell(
            rawValue: defaults.string(forKey: Key.hudDwell.rawValue) ?? ""
        ) ?? .default
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

    /// "The Notch as shipped." The Restore Defaults button in the settings panel puts every
    /// value below back, and this dictionary is also what `UserDefaults.register` seeds a first
    /// launch with — so there is exactly one statement of what the default behaviour is.
    ///
    /// `launchAtLogin` is deliberately absent: it is not a stored preference, and restoring
    /// defaults must not silently unregister a login item the user set up on purpose.
    private static var registeredDefaults: [String: Any] {
        [
            Key.showMediaActivity.rawValue: true,
            Key.hideMediaWhenPaused.rawValue: true,
            Key.showAgentActivity.rawValue: true,
            Key.showAttentionRing.rawValue: true,
            Key.showAgentModel.rawValue: false,
            Key.replaceSystemHUD.rawValue: true,
            Key.expandOnHover.rawValue: true,
            Key.finishedRetention.rawValue: FinishedRetention.default.rawValue,
            Key.hudDwell.rawValue: HUDDwell.default.rawValue,
            Key.hoverSensitivity.rawValue: HoverSensitivity.default.rawValue,
            SoundEffects.enabledDefaultsKey: true,
        ]
    }

    /// Whether every preference currently matches the shipped behaviour. The Restore Defaults
    /// button reads this so it can dim itself rather than pretending there is something to undo.
    var isAtDefaults: Bool {
        showMediaActivity
            && hideMediaWhenPaused
            && showAgentActivity
            && showAttentionRing
            && !showAgentModel
            && soundCuesEnabled
            && finishedRetention == .default
            && replaceSystemHUD
            && hudDwell == .default
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
        showMediaActivity = true
        hideMediaWhenPaused = true
        showAgentActivity = true
        showAttentionRing = true
        showAgentModel = false
        soundCuesEnabled = true
        finishedRetention = .default
        replaceSystemHUD = true
        hudDwell = .default
        expandOnHover = true
        hoverSensitivity = .default
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
        guard showMediaActivity, status.isActive else { return false }
        return status.isPlaying || !hideMediaWhenPaused
    }

    func showsAgents(sessionCount: Int) -> Bool {
        showAgentActivity && sessionCount > 0
    }

    // MARK: Storage

    private enum Key: String, CaseIterable {
        case showMediaActivity = "NotchShowMediaActivity"
        case hideMediaWhenPaused = "NotchHideMediaWhenPaused"
        case showAgentActivity = "NotchShowAgentActivity"
        case showAttentionRing = "NotchShowAttentionRing"
        case showAgentModel = "NotchShowAgentModel"
        case finishedRetention = "NotchFinishedSessionRetention"
        case replaceSystemHUD = "NotchReplaceSystemHUD"
        case hudDwell = "NotchHUDDwell"
        case expandOnHover = "NotchExpandOnHover"
        case hoverSensitivity = "NotchHoverSensitivity"
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
