import AppKit
import Combine

/// Runs the real `NowPlayingMonitor` headless and prints every status it publishes, so the
/// media path can be checked from a terminal while another copy of the app owns the notch.
///
///     "The Notch.app/Contents/MacOS/The Notch" --media-diagnostics 60
///
/// Prints one line per published status, then quits after the given number of seconds
/// (default 30). Never opens a window and writes no settings. With `--exercise` it also drives
/// the player through the monitor's own controls: play/pause at 4s, seek to 30% at 8s, next
/// track at 12s, play/pause at 18s. With `--exercise-repeat` it presses repeat every 3s until
/// the setting is back where it started (at most three presses).
@MainActor
enum MediaDiagnostics {
    private static var monitor: NowPlayingMonitor?
    private static var subscription: AnyCancellable?

    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--media-diagnostics") else { return false }
        let seconds = arguments.dropFirst(flag + 1).first.flatMap(TimeInterval.init) ?? 30

        let started = Date()
        let monitor = NowPlayingMonitor()
        self.monitor = monitor
        subscription = monitor.$status.sink { status in
            let time = String(format: "%6.2f", Date().timeIntervalSince(started))
            print("[media \(time)s] \(describe(status))")
            fflush(stdout)
        }

        if arguments.contains("--exercise") {
            Task { @MainActor in
                let steps: [(Double, String, () -> Void)] = [
                    (4, "playPause", { monitor.playPause() }),
                    (8, "seek 30%", { monitor.seek(toFraction: 0.3) }),
                    (12, "nextTrack", { monitor.nextTrack() }),
                    (18, "playPause", { monitor.playPause() }),
                ]
                var elapsed = 0.0
                for (at, name, action) in steps {
                    try? await Task.sleep(for: .seconds(at - elapsed))
                    elapsed = at
                    print("[media] >>> \(name)")
                    action()
                }
            }
        }

        if arguments.contains("--exercise-repeat") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                let start = monitor.status.repeatMode
                for _ in 0..<3 {
                    print("[media] >>> cycleRepeat")
                    monitor.cycleRepeat()
                    try? await Task.sleep(for: .seconds(3))
                    if monitor.status.repeatMode == start { break }
                }
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            subscription = nil
            self.monitor = nil
            NSApp.terminate(nil)
        }
        return true
    }

    private static func describe(_ status: NowPlayingStatus) -> String {
        guard status.isActive, let player = status.player else { return "inactive" }
        let identifier = switch player {
        case .spotify: "com.spotify.client"
        case .music: "com.apple.Music"
        case let .app(bundleIdentifier): bundleIdentifier
        }
        let source = "\(player.displayName) [\(player.sourceKind.rawValue), \(identifier)]"
        let elapsed = status.elapsedPosition.map { String(format: "%.1f", $0) } ?? "-"
        let duration = status.duration.map { String(format: "%.1f", $0) } ?? "-"
        let artwork = status.artwork.map { "\($0.count / 1_024) KB" } ?? "none"
        return [
            source,
            status.isPlaying ? "playing" : "paused",
            "\"\(status.title)\" by \"\(status.artist)\"",
            "\(elapsed)/\(duration)s",
            "artwork \(artwork)",
            "repeat \(status.repeatMode.map { "\($0)" } ?? "unsupported")",
        ].joined(separator: " | ")
    }
}
