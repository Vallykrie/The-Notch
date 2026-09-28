import AppKit

/// Captures the *running* app's own window to disk, on demand, via a signal.
///
/// This exists because the two obvious ways to look at the notch both fail:
/// `FrameDump` renders detached `SwiftUI` views, so it can never show real state, real window
/// layout, or an animation in flight; and screen capture is unavailable to an `LSUIElement`
/// agent — it cannot be added to a screen-recording allowlist, and the notch band is excluded
/// from captures anyway. Relying on `FrameDump` alone is how an app that snapped open with no
/// animation, and showed no agent data at all, kept looking correct in review.
///
/// `cacheDisplay(in:to:)` draws the live view tree into a bitmap. It is not the compositor's
/// output — no drop shadow onto the desktop, no wallpaper behind the transparent panel — but it
/// is the real window, at its real current size, with whatever data and animation state the app
/// actually has right now. That is the part that was missing.
///
/// Enabled only when `NOTCH_LIVE_CAPTURE` names an output directory.
/// - `kill -USR1 <pid>` writes one frame of the current state.
/// - `kill -USR2 <pid>` toggles collapsed/expanded through the real transition and samples the
///   window for the length of the gesture, which is the only way to check that the spring is
///   actually running rather than snapping.
@MainActor
enum LiveCapture {
    static var requestedDirectory: String? {
        ProcessInfo.processInfo.environment["NOTCH_LIVE_CAPTURE"]
    }

    /// Sampled for a little longer than the slowest spring so the tail of the settle is visible.
    private static let sampleDuration: TimeInterval = 0.85
    private static let sampleInterval: TimeInterval = 1.0 / 60.0

    private static var window: NSWindow?
    private static var coordinator: NotchCoordinator?
    private static var directory: URL?
    private static var sources: [DispatchSourceSignal] = []
    private static var sequence = 0

    static func start(window: NSWindow, coordinator: NotchCoordinator, directory path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        self.window = window
        self.coordinator = coordinator
        self.directory = url

        install(SIGUSR1) { captureOnce(label: "state") }
        install(SIGUSR2) { captureTransition() }

        FileHandle.standardError.write(
            Data("LiveCapture: armed, pid \(ProcessInfo.processInfo.processIdentifier)\n".utf8)
        )
    }

    /// `signal(_:SIG_IGN)` first: `DispatchSourceSignal` observes, it does not consume, so the
    /// default disposition would still terminate the process.
    private static func install(_ number: Int32, handler: @escaping @MainActor () -> Void) {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated(handler) }
        source.resume()
        sources.append(source)
    }

    private static func captureOnce(label: String) {
        sequence += 1
        write(name: String(format: "live-%02d-%@.png", sequence, label))
    }

    /// Drives the real hover transition and samples throughout, so the frames show whatever the
    /// gesture actually does — spring, or instant jump.
    private static func captureTransition() {
        guard let coordinator else { return }
        sequence += 1
        let run = sequence
        let target: NotchState = coordinator.state == .expanded ? .collapsed : .expanded

        write(name: String(format: "live-%02d-t000.png", run))
        NotchRootView.transition(coordinator, to: target)

        var elapsed: TimeInterval = 0
        Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { timer in
            MainActor.assumeIsolated {
                elapsed += sampleInterval
                let milliseconds = Int(elapsed * 1000)
                write(name: String(format: "live-%02d-t%03d.png", run, milliseconds))
                if elapsed >= sampleDuration {
                    timer.invalidate()
                    FileHandle.standardError.write(
                        Data("LiveCapture: transition run \(run) complete\n".utf8)
                    )
                }
            }
        }
    }

    private static func write(name: String) {
        guard let window, let directory, let view = window.contentView else { return }

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: directory.appendingPathComponent(name))
    }
}
