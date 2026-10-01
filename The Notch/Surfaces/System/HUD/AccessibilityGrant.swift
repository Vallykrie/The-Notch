import Foundation
import Security

/// Which build of the app last held the Accessibility grant, and which build was last asked
/// for it.
///
/// An ad-hoc signed app is known to TCC by its code-directory hash and nothing else, so every
/// new build loses the grant — while System Settings goes on showing the old entry switched on.
/// Without a record, "never granted" and "granted, then lost to an update" look identical from
/// inside the app, and the HUD replacement just stops working with no explanation. Only the
/// second case deserves another prompt: someone who declined once should not be asked again on
/// every release.
struct AccessibilityGrant {
    private let defaults: UserDefaults
    let currentBuild: String

    init(defaults: UserDefaults = .standard, currentBuild: String = Self.runningBuild()) {
        self.defaults = defaults
        self.currentBuild = currentBuild
    }

    private var grantedBuild: String? { defaults.string(forKey: Key.granted) }
    private var promptedBuild: String? { defaults.string(forKey: Key.prompted) }

    /// A different build held the grant and this one does not. Not true when the grant
    /// belongs to *this* build and is missing — that is the user revoking it, not an update
    /// losing it.
    func isLost(isTrusted: Bool) -> Bool {
        guard !isTrusted, let grantedBuild else { return false }
        return grantedBuild != currentBuild
    }

    /// At most once per build. A build that was never asked under this scheme is asked once —
    /// which includes everyone upgrading from the old once-per-machine flag, because that flag
    /// cannot say whether the grant it led to has since been lost.
    func shouldPrompt(isTrusted: Bool) -> Bool {
        guard !isTrusted, promptedBuild != currentBuild else { return false }
        return promptedBuild == nil || isLost(isTrusted: isTrusted)
    }

    func recordTrusted() {
        guard grantedBuild != currentBuild else { return }
        defaults.set(currentBuild, forKey: Key.granted)
    }

    func recordPrompted() {
        defaults.set(currentBuild, forKey: Key.prompted)
    }

    /// The running slice's code-directory hash — the exact value TCC matches an ad-hoc grant
    /// against. The bundle version is only a fallback for an unsigned binary: two builds of the
    /// same version have different hashes, and TCC treats them as different apps.
    static func runningBuild() -> String {
        if let hash = codeDirectoryHash() { return hash }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static func codeDirectoryHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let information = information as? [String: Any],
              let hash = information[kSecCodeInfoUnique as String] as? Data
        else {
            return nil
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private enum Key {
        static let granted = "AccessibilityGrantedBuild"
        static let prompted = "AccessibilityPromptedBuild"
    }
}
