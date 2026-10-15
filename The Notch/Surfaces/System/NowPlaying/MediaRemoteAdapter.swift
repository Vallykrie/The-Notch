import Darwin
import Foundation

/// Reads and controls the system's Now Playing item through the vendored MediaRemoteAdapter.
///
/// MediaRemote only answers processes with a `com.apple.*` identity since macOS 15.4, so the app
/// never calls it directly. It runs Apple's `/usr/bin/perl` on the bundled script, which loads
/// the bundled framework into that entitled process. See Vendor/MediaRemoteAdapter/VENDORED.md.
///
/// Every failure here is quiet: a missing bundle file, a failed `test`, a crashed stream. The
/// monitor falls back to AppleScript, so a broken adapter never breaks the media surface.
nonisolated struct MediaRemoteAdapter: Sendable {
    enum Command: Sendable {
        case play
        case pause
        case nextTrack
        case previousTrack
        case seek(seconds: TimeInterval)
        case setRepeat(NowPlayingStatus.RepeatMode)

        /// `send` takes an MRCommand number; `seek` takes microseconds; `repeat` takes an
        /// MRARepeatMode number.
        fileprivate var arguments: [String] {
            switch self {
            case .play: ["send", "0"]
            case .pause: ["send", "1"]
            case .nextTrack: ["send", "4"]
            case .previousTrack: ["send", "5"]
            case let .seek(seconds): ["seek", String(Int64((max(seconds, 0) * 1_000_000).rounded()))]
            case let .setRepeat(mode): ["repeat", String(mode.mediaRemoteValue)]
            }
        }
    }

    private static let perl = URL(filePath: "/usr/bin/perl")
    private static let probeTimeout: TimeInterval = 3
    private static let commandTimeout: TimeInterval = 3

    let script: URL
    let framework: URL
    let testClient: URL

    /// The adapter inside this app, or nil when any piece of it is missing from the bundle.
    init?(bundle: Bundle = .main) {
        let contents = bundle.bundleURL.appending(path: "Contents")
        script = contents.appending(path: "Resources/mediaremote-adapter.pl")
        framework = contents.appending(path: "Frameworks/MediaRemoteAdapter.framework")
        testClient = contents.appending(path: "Helpers/MediaRemoteAdapterTestClient")

        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: Self.perl.path),
              fileManager.fileExists(atPath: script.path),
              fileManager.fileExists(atPath: framework.appending(path: "MediaRemoteAdapter").path),
              fileManager.isExecutableFile(atPath: testClient.path)
        else { return nil }
    }

    /// Upstream's `test`: exit 0 means MediaRemote answers and every command is supported.
    /// It briefly registers a fake now-playing item, so it runs once per launch, never per poll.
    func probe() async -> Bool {
        await Self.run(
            [script.path, framework.path, testClient.path, "test"],
            timeout: Self.probeTimeout
        ) == 0
    }

    func send(_ command: Command) async -> Bool {
        await Self.run(
            [script.path, framework.path] + command.arguments,
            timeout: Self.commandTimeout
        ) == 0
    }

    /// Starts streaming. `onUpdate` receives the current item (nil when nothing is playing)
    /// after each change; `onExit` receives the exit status once the process ends for any
    /// reason. Both are called on a private serial queue.
    func stream(
        onUpdate: @escaping @Sendable (AdapterTrack?) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) -> MediaRemoteAdapterStream? {
        MediaRemoteAdapterStream(
            arguments: [script.path, framework.path, "stream", "--micros", "--debounce=100"],
            onUpdate: onUpdate,
            onExit: onExit
        )
    }

    /// Runs perl to completion on a worker queue. Returns the exit status, or nil if it could
    /// not launch or was killed at the timeout.
    private static func run(_ arguments: [String], timeout: TimeInterval) async -> Int32? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = perl
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 0.25)
                    if process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                    process.waitUntilExit()
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }
}

/// One running `stream` process. Stopping it, or its exiting on its own, is final: the monitor
/// starts a new one rather than reviving this.
nonisolated final class MediaRemoteAdapterStream: @unchecked Sendable {
    // `queue` owns `buffer`, `snapshot` and `lastTrack`; the pipe and process callbacks hop
    // onto it, which is what makes the `@unchecked Sendable` sound.
    private let queue = DispatchQueue(label: "the-notch.mediaremote-adapter.stream")
    private let process = Process()
    private var buffer = Data()
    private var snapshot = AdapterSnapshot()
    private var lastTrack: AdapterTrack?
    private var hasReportedTrack = false
    private let artworkStore = ArtworkStore()
    /// Items already looked up on disk this session, found or not, so a miss is not re-read
    /// on every line.
    private var storeLookups: Set<String> = []

    /// A line longer than this is not one upstream writes (artwork is capped well below it);
    /// it is dropped rather than grown without bound.
    private static let maximumLineByteCount = 8 * 1_024 * 1_024

    fileprivate init?(
        arguments: [String],
        onUpdate: @escaping @Sendable (AdapterTrack?) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/perl")
        process.arguments = arguments
        process.standardOutput = output
        // Upstream treats stderr lines as non-fatal diagnostics. Nothing reads them here.
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            queue.async {
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                self.consume(chunk, onUpdate: onUpdate)
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            guard let self else {
                onExit(status)
                return
            }
            // After any output still queued, so the last update is delivered before the exit.
            queue.async { onExit(status) }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }
    }

    private func consume(_ chunk: Data, onUpdate: @Sendable (AdapterTrack?) -> Void) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty, snapshot.apply(line: Data(line)) else { continue }

            var track = snapshot.track
            if let key = snapshot.itemKey {
                if snapshot.lastLineCarriedArtwork, let artwork = track?.artwork {
                    artworkStore.save(artwork, for: key)
                    storeLookups.insert(key)
                } else if track?.artwork == nil, storeLookups.insert(key).inserted,
                          let stored = artworkStore.artwork(for: key) {
                    snapshot.remember(stored, for: key)
                    track = snapshot.track
                }
            }
            guard !hasReportedTrack || track != lastTrack else { continue }
            hasReportedTrack = true
            lastTrack = track
            onUpdate(track)
        }
        if buffer.count > Self.maximumLineByteCount {
            buffer.removeAll()
        }
    }
}
