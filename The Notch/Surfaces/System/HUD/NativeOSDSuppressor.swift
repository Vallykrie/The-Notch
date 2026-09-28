import Darwin
import Foundation

/// Stops and resumes `OSDUIHelper`, the agent that draws macOS's own volume and brightness HUD.
///
/// There is no supported way to ask macOS not to draw that HUD. The alternatives were all worse:
/// swallowing the key events needs an Accessibility-privileged event tap and breaks every other
/// consumer of those keys; hiding the helper's window needs Screen Recording and still shows a
/// frame; and letting both HUDs appear at once is the defect this exists to fix. Suspending the
/// process is the one approach that is instant, total, and exactly reversible.
///
/// **This is a system-wide change for the lifetime of the app.** It is restored on terminate, and
/// it self-heals: `suppress()` is only ever paired with a `restore()` at launch, so a previous
/// force-quit that skipped the `SIGCONT` cannot leave the helper stopped forever.
enum NativeOSDSuppressor {
    /// Suspending the helper is a two-step operation, and the first step is the one that is easy
    /// to miss.
    ///
    /// `OSDUIHelper` is an on-demand `LaunchAgent`: at login, and at the moment this app starts,
    /// it is simply **not running** — `launchctl print` reports `state = not running`. Signalling
    /// it then does nothing at all, and the suppression looks like it worked right up until the
    /// user presses a volume key, launchd spawns the helper, and the native HUD appears anyway.
    /// So it is kickstarted into existence first and suspended immediately afterwards, before it
    /// has anything to draw.
    static func suppress() {
        kickstart()
        signalHelper(SIGSTOP, named: "SIGSTOP")
    }

    static func restore() {
        signalHelper(SIGCONT, named: "SIGCONT")
    }

    private static let helperName = "OSDUIHelper"
    private static var serviceTarget: String { "gui/\(getuid())/com.apple.OSDUIHelper" }

    /// Bring the agent up so there is a process to suspend. `kickstart` is the one launchctl
    /// verb that works here without privilege; `launchctl kill` does not, see `signalHelper`.
    private static func kickstart() {
        run("/bin/launchctl", ["kickstart", serviceTarget])
    }

    /// `kill(2)` against the pids found by name, and deliberately **not** `launchctl kill`.
    ///
    /// Addressing the service target would be the tidier form — the helper's pid changes every
    /// time launchd re-spawns it — but it does not work: `launchctl kill SIGSTOP` against this
    /// service fails with *"Not privileged to signal service"*, because System Integrity
    /// Protection guards Apple's own launch agents from being signalled through launchd. A plain
    /// signal to the pid is not covered by that restriction and succeeds; the process is left in
    /// state `T`, which is exactly what is wanted.
    ///
    /// The pid changing across a re-spawn is not a problem in practice: a suspended process still
    /// holds the agent's Mach service, so launchd has no reason to start a second one, and the
    /// pid is looked up fresh on each call regardless.
    ///
    /// Every failure is swallowed and logged. The helper may not be running, may already be in
    /// the target state, or may have been renamed by a future OS — none of which is a reason to
    /// prevent the app from launching or, much worse, from quitting.
    private static func signalHelper(_ signal: Int32, named name: String) {
        let pids = helperProcessIDs()
        guard !pids.isEmpty else {
            NSLog("The Notch: no \(helperName) process to send \(name) to.")
            return
        }

        for pid in pids where kill(pid, signal) != 0 {
            NSLog(
                "The Notch: could not \(name) \(helperName) (pid \(pid)): "
                    + String(cString: strerror(errno))
            )
        }
    }

    /// `pgrep -x` rather than a `sysctl(KERN_PROC_ALL)` walk. The walk is the dependency-free
    /// option, but it means reserving and re-reading a `kinfo_proc` buffer that can change size
    /// between the sizing call and the fetch — a race, for a lookup that happens twice per app
    /// lifetime. `-x` anchors the match so nothing else named similarly is ever signalled.
    private static func helperProcessIDs() -> [pid_t] {
        guard let output = run("/usr/bin/pgrep", ["-x", helperName], capturing: true) else {
            return []
        }
        return output.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }

    /// Synchronous on purpose. This runs a handful of times per app lifetime — once at launch and
    /// once during `applicationWillTerminate`, where an async completion would not be delivered
    /// before the process is gone.
    @discardableResult
    private static func run(
        _ path: String,
        _ arguments: [String],
        capturing: Bool = false
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = capturing ? Pipe() : nil
        process.standardOutput = pipe ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            // Read before waiting. A `pgrep` whose output filled the pipe buffer would block on
            // write while we blocked on exit, and this runs on the main thread during launch and
            // termination — the two moments a deadlock is least recoverable.
            let data = pipe?.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data.map { String(decoding: $0, as: UTF8.self) }
        } catch {
            NSLog("The Notch: could not run \(path) \(arguments.joined(separator: " ")): \(error)")
            return nil
        }
    }
}
