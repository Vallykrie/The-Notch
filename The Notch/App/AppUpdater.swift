import Sparkle

/// The Sparkle updater: the scheduled background check, and the manual "Check for Updates".
///
/// Stays inert in three cases, and `isAvailable` is false in each:
/// - a Debug build, which must never offer to replace itself with the release feed;
/// - a build with no `SUPublicEDKey` in its Info.plist (see `Config/Info.plist`). Sparkle would
///   refuse every update it cannot verify, and a half-configured updater is harder to notice
///   than a missing menu item;
/// - previews and frame dumps, which pass `enabled: false`.
@MainActor
final class AppUpdater {
    private let controller: SPUStandardUpdaterController?
    /// Held here because Sparkle keeps only a weak reference to its delegate.
    private let delegate = InstallNowDelegate()

    init(enabled: Bool = true) {
        // The whole branch is compiled out of Debug, not gated on a `false` constant: a constant
        // condition leaves the updater construction as code the compiler warns can never run.
        #if DEBUG
        controller = nil
        #else
        controller = enabled && Self.hasPublicKey
            ? SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: delegate,
                userDriverDelegate: nil
            )
            : nil
        #endif
    }

    /// Whether the header should offer "Check for Updates" at all.
    var isAvailable: Bool { controller != nil }

    /// Whether a check can start right now. Sparkle refuses a second check while one is running.
    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    private static var hasPublicKey: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.isEmpty == false
    }
}

/// Installs a downloaded update right away instead of waiting for the app to quit.
///
/// `SUAutomaticallyUpdate` downloads silently and installs on quit, but the notch app lives in
/// the menu bar and is rarely quit, so an update could sit unapplied for weeks. Taking the
/// immediate-install path relaunches into the new version within a second or two.
private final class InstallNowDelegate: NSObject, SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        immediateInstallHandler()
        return true
    }
}
