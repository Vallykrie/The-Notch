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

    init(enabled: Bool = true) {
        #if DEBUG
        let allowed = false
        #else
        let allowed = enabled && Self.hasPublicKey
        #endif
        controller = allowed
            ? SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            : nil
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
