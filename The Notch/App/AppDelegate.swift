import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: NotchCoordinator?
    private var notchWindow: NotchWindow?
    private var bridge: AgentBridgeController?
    private var services: SystemServices?
    private var screenParametersObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if RuntimeDiagnostics.runIfRequested() { return }

        // Must happen before any view builds. The bundled font is registered per-process rather
        // than installed system-wide, and `Font.custom` silently falls back to San Francisco if
        // the family is not yet known — which looks like a styling bug, not a missing font.
        Typography.registerBundledFonts()

        // Offscreen render mode: dump animation frames and quit without ever showing a panel
        // or touching the agent socket.
        if let directory = FrameDump.requestedDirectory {
            FrameDump.run(directory: directory)
            NSApp.terminate(nil)
            return
        }

        // The same, but writing frame *sequences* to be assembled into GIFs — the only way to
        // watch any of this motion without being at the machine, since the notch band is
        // excluded from screen capture.
        if let directory = FrameDump.requestedAnimationDirectory {
            FrameDump.runAnimation(directory: directory)
            NSApp.terminate(nil)
            return
        }

        // Unconditionally, and before anything decides whether to suppress it again. A previous
        // run that was force-killed never got its `applicationWillTerminate`, so the system HUD
        // helper can still be stopped from last time; restoring at launch makes that self-heal
        // instead of requiring a logout. Restoring a helper that is already running is a no-op.
        NativeOSDSuppressor.restore()

        observeScreenParameters()
        installOrRepositionNotch()
    }

    /// Pushes the user's preferences into the things SwiftUI cannot re-render: the level
    /// monitor, the media-key tap, the machine-wide OSD suppression, and the session store's
    /// retention window.
    ///
    /// Runs at launch and on every settings change, and is written to be idempotent — `start()`
    /// and `stop()` on both monitors already are, and the two writes below are plain
    /// assignments. That is what lets one function serve both the initial configuration and
    /// every subsequent edit, instead of a launch path and a change path that drift apart.
    private func applyPreferences() {
        guard let services else { return }
        let settings = services.settings

        services.systemHUD.dwell = Theme.Metrics.HUD.dwell(settings.hudDwell)

        if let store = bridge?.store {
            store.doneSessionRetention = settings.finishedRetention.interval
            // Applied to what is already on screen, not just to future events. Shortening the
            // window and watching yesterday's finished sessions sit there until the next hook
            // fires would look like the preference had not taken.
            store.pruneDoneSessions(olderThan: settings.finishedRetention.interval)
        }

        if settings.replaceSystemHUD {
            services.systemHUD.start()
            // The interceptor is what actually replaces the system HUD; the monitor above only
            // reads the levels.
            services.mediaKeys.requestPermissionIfNeeded()
            services.mediaKeys.start()
        } else {
            services.systemHUD.stop()
            services.mediaKeys.stop()
            // Unconditionally, and not only when the suppression was applied here: the user has
            // just asked for macOS's own readout back, and leaving `OSDUIHelper` stopped would
            // mean neither HUD appears. Restoring a helper that is already running is a no-op.
            NativeOSDSuppressor.restore()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Non-negotiable: the user's brightness and volume HUD must come back when this app
        // is not running. Restoring it first means a hang draining the bridge below cannot
        // leave the system without its own readout.
        NativeOSDSuppressor.restore()
        services?.mediaKeys.stop()
        services?.integrations.stop()
        services?.trading.stop()

        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }

        // The socket must be unlinked before we exit, otherwise the next launch finds a stale
        // path. `stop()` is async, so drain the main queue until it completes rather than
        // letting termination race it.
        if let bridge {
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await bridge.stop()
                done.signal()
            }
            while done.wait(timeout: .now()) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        }
    }

    private func observeScreenParameters() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.installOrRepositionNotch()
            }
        }
    }

    private func installOrRepositionNotch() {
        guard let screen = ScreenGeometry.preferredScreen() else { return }
        let geometry = ScreenGeometry.resolve(for: screen)

        if let notchWindow, let coordinator {
            notchWindow.apply(geometry, coordinator: coordinator)
            notchWindow.orderFrontRegardless()
            return
        }

        let coordinator = NotchCoordinator(collapsedSize: geometry.collapsedNotchSize)
        let bridge = AgentBridgeController(coordinator: coordinator)
        let services = SystemServices()
        let notchWindow = NotchWindow(
            geometry: geometry,
            coordinator: coordinator,
            store: bridge.store,
            services: services
        )
        self.coordinator = coordinator
        self.bridge = bridge
        self.services = services
        self.notchWindow = notchWindow
        notchWindow.orderFrontRegardless()

        bridge.start()
        services.integrations.start()
        services.trading.start()

        // Everything a preference configures outside SwiftUI is applied from one place, at
        // launch and again on every change. Nothing here starts a monitor directly — a second
        // start path is how the app ends up intercepting media keys with the preference off.
        services.settings.onChange = { [weak self] in
            self?.applyPreferences()
        }
        applyPreferences()

        // First launch: the notch introduces itself and asks before hooking into any agent.
        // Hooks used to be installed silently here; now nothing is until the user says yes.
        if !services.settings.hasSeenIntro {
            coordinator.requestOnboarding()
        }

        if let directory = LiveCapture.requestedDirectory {
            LiveCapture.start(
                window: notchWindow,
                coordinator: coordinator,
                directory: directory
            )
        }

        // Nothing at launch requests a TCC permission, and nothing here needs to. The
        // now-playing monitor only scripts a media player that is already running, and only
        // once one appears — so Automation consent is asked for at the moment the user starts
        // playing something, not while the app is coming up.
    }
}
