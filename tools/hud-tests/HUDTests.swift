import Foundation

@main
struct HUDTests {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        print("\(condition ? "PASS" : "FAIL"): \(name)")
        if !condition { failures += 1 }
    }

    static func main() {
        let suite = "com.thenotch.hud-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AccessibilityGrant(defaults: defaults, currentBuild: "build-a")
        check(first.shouldPrompt(isTrusted: false), "a fresh install is asked once")
        check(!first.isLost(isTrusted: false), "a fresh install has no grant to lose")
        first.recordPrompted()
        check(!first.shouldPrompt(isTrusted: false), "the same build is never asked twice")

        let declined = AccessibilityGrant(defaults: defaults, currentBuild: "build-b")
        check(!declined.shouldPrompt(isTrusted: false), "an update does not re-ask someone who never granted")

        declined.recordTrusted()
        check(!declined.shouldPrompt(isTrusted: true), "a trusted build is never asked")
        check(!declined.isLost(isTrusted: false), "revoking the current build's grant is respected, not re-asked")
        check(!declined.shouldPrompt(isTrusted: false), "revoking the current build's grant does not prompt")

        let updated = AccessibilityGrant(defaults: defaults, currentBuild: "build-c")
        check(updated.isLost(isTrusted: false), "an update that lost the grant is reported as lost")
        check(updated.shouldPrompt(isTrusted: false), "an update that lost the grant is asked again")
        updated.recordPrompted()
        check(!updated.shouldPrompt(isTrusted: false), "the lost grant is asked about once per build")
        check(updated.isLost(isTrusted: false), "the lost state persists until the grant is restored")
        check(!updated.isLost(isTrusted: true), "a restored grant is not lost")
        updated.recordTrusted()
        check(!updated.isLost(isTrusted: false), "restoring the grant moves it to the current build")

        let legacySuite = suite + ".legacy"
        let legacyDefaults = UserDefaults(suiteName: legacySuite)!
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        legacyDefaults.set(true, forKey: "HasPromptedForAccessibility")
        let legacy = AccessibilityGrant(defaults: legacyDefaults, currentBuild: "build-a")
        check(legacy.shouldPrompt(isTrusted: false), "a build from before grants were recorded is asked once more")

        let running = AccessibilityGrant.runningBuild()
        check(
            running.count == 40 && running.allSatisfy { $0.isHexDigit && !$0.isUppercase },
            "the running build is identified by its code-directory hash"
        )

        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
        print("all checks passed")
    }
}
