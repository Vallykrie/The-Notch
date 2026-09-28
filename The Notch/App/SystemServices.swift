import Foundation

/// The long-lived system monitors the surfaces read from.
///
/// Grouped so the app builds them once and threads a single reference down to the views,
/// rather than each surface owning its own monitor.
///
/// This once also carried a `BatteryMonitor` and a `CalendarService`. Both were removed: they
/// were commodity menu-bar widgets that had nothing to do with what this app is for, and they
/// were taking up the expanded panel that the media and agent surfaces need.
@MainActor
final class SystemServices {
    let nowPlaying: NowPlayingMonitor
    /// Brightness and volume levels, which the notch draws instead of macOS's own HUD.
    let systemHUD: SystemHUDMonitor
    /// "Instead of" is only true because of this: the monitor *reads* the levels, and the
    /// interceptor is what stops macOS drawing its own readout beside ours. It is not a view
    /// dependency, so nothing below `AppDelegate` ever sees it.
    let mediaKeys = MediaKeyInterceptor()
    let integrations = AgentIntegrationManager()
    /// Every user preference. It rides here rather than being threaded separately because the
    /// surfaces that read it are the same surfaces that already receive `SystemServices`, and
    /// because half the preferences configure the monitors sitting beside it.
    let settings: NotchSettings
    let trading: TradingStore

    /// Built inside the initializer body rather than as a default argument: default arguments
    /// are evaluated in a nonisolated context and the monitors are `@MainActor`.
    init() {
        nowPlaying = NowPlayingMonitor()
        systemHUD = SystemHUDMonitor()
        settings = NotchSettings()
        trading = TradingStore()
        mediaKeys.onHandledEvent = { [weak systemHUD] event in
            systemHUD?.presentIntercepted(event)
        }
    }

    /// Injection point for previews and tests.
    ///
    /// `systemHUD` deliberately has no default value. A default argument is evaluated in a
    /// nonisolated context — the same rule the comment above records for the monitors — so
    /// `= SystemHUDMonitor()` does not compile against a `@MainActor` type. Callers pass one.
    init(nowPlaying: NowPlayingMonitor, systemHUD: SystemHUDMonitor, trading: TradingStore? = nil) {
        self.nowPlaying = nowPlaying
        self.systemHUD = systemHUD
        // Ephemeral, and deliberately not the shared store: `FrameDump` builds real views
        // through this initializer, and a render on a build agent must not read — or leave
        // behind — the preferences of whoever is running it.
        settings = NotchSettings.ephemeral()
        self.trading = trading ?? TradingPreviewData.emptyStore()
    }
}
