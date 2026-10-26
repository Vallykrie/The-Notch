import Foundation

/// The long-lived system monitors the surfaces read from.
///
/// Grouped so the app builds them once and threads a single reference down to the views,
/// rather than each surface owning its own monitor.
///
/// This once also carried a `BatteryMonitor` and a `CalendarService`. Both were removed as
/// commodity widgets taking space from the media and agent surfaces. The calendar came back as
/// `CalendarStore` on user request — as its own tab with its own on/off switch, so it costs
/// nothing to anyone who does not want it.
@MainActor
final class SystemServices {
    let nowPlaying: NowPlayingMonitor
    /// Brightness and volume levels, which the notch draws instead of macOS's own HUD.
    let systemHUD: SystemHUDMonitor
    /// "Instead of" is only true because of this: the monitor *reads* the levels, and the
    /// interceptor is what stops macOS drawing its own readout beside ours. It is not a view
    /// dependency, so nothing below `AppDelegate` ever sees it.
    let mediaKeys = MediaKeyInterceptor()
    let integrations: AgentIntegrationManager
    /// Every user preference. It rides here rather than being threaded separately because the
    /// surfaces that read it are the same surfaces that already receive `SystemServices`, and
    /// because half the preferences configure the monitors sitting beside it.
    let settings: NotchSettings
    let trading: TradingStore
    /// Upcoming events from every calendar account on the Mac. Idle until calendar access is
    /// granted, and suspended while the feature is off.
    let calendar: CalendarStore
    /// The scratchpad's pages. Kept whether or not the feature is on, so switching it off and
    /// back loses nothing.
    let notes: NotesStore
    /// Lyrics for the playing track, read by both the media panel and the collapsed notch.
    let lyrics: LyricsController
    /// Scheduled and manual update checks. Inert in Debug builds and when no public key is set.
    let updater: AppUpdater

    /// Built inside the initializer body rather than as a default argument: default arguments
    /// are evaluated in a nonisolated context and the monitors are `@MainActor`.
    init() {
        nowPlaying = NowPlayingMonitor()
        systemHUD = SystemHUDMonitor()
        settings = NotchSettings()
        trading = TradingStore()
        calendar = CalendarStore()
        notes = NotesStore()
        lyrics = LyricsController(nowPlaying: nowPlaying)
        integrations = AgentIntegrationManager(settings: settings)
        updater = AppUpdater()
        mediaKeys.onHandledEvent = { [weak systemHUD] event in
            systemHUD?.presentIntercepted(event)
        }
    }

    /// Injection point for previews and tests.
    ///
    /// `systemHUD` deliberately has no default value. A default argument is evaluated in a
    /// nonisolated context — the same rule the comment above records for the monitors — so
    /// `= SystemHUDMonitor()` does not compile against a `@MainActor` type. Callers pass one.
    init(
        nowPlaying: NowPlayingMonitor,
        systemHUD: SystemHUDMonitor,
        trading: TradingStore? = nil,
        calendar: CalendarStore? = nil,
        notes: NotesStore? = nil
    ) {
        self.nowPlaying = nowPlaying
        self.systemHUD = systemHUD
        // Ephemeral, and deliberately not the shared store: `FrameDump` builds real views
        // through this initializer, and a render on a build agent must not read — or leave
        // behind — the preferences of whoever is running it.
        settings = NotchSettings.ephemeral()
        self.trading = trading ?? TradingPreviewData.emptyStore()
        self.calendar = calendar ?? CalendarPreviewData.emptyStore()
        self.notes = notes ?? NotesStore(defaults: nil)
        lyrics = LyricsController(nowPlaying: nowPlaying)
        integrations = AgentIntegrationManager()
        updater = AppUpdater(enabled: false)
    }
}
