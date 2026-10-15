import AppKit
import Combine
import Foundation

private struct ParsedStatus: Sendable {
    let player: NowPlayingStatus.Player
    let status: NowPlayingStatus
    let spotifyArtworkURL: URL?
}

private enum TransportCommand: Equatable, Sendable {
    case playPause
    case nextTrack
    case previousTrack
    case seek(seconds: TimeInterval)
}

/// Where now-playing data comes from. Decided once per launch.
private enum Backend: Equatable {
    /// The adapter's `test` is still running. Nothing is published yet (it takes ~70 ms).
    case probing
    /// MediaRemote through the bundled adapter: every app, browsers included, and no
    /// Automation permission.
    case mediaRemote
    /// AppleScript against Spotify and Music: the fallback when the adapter is missing, fails
    /// its test, or keeps crashing.
    case appleScript
}

private enum CommandOutcome: Equatable, Sendable {
    case succeeded
    case permissionDenied
    case failed
}

@MainActor
final class NowPlayingMonitor: ObservableObject {
    @Published private(set) var status: NowPlayingStatus

    private let runner: AppleScriptRunner
    private let isPreview: Bool
    private var workspaceObservers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt = 0
    private var pendingCommandGeneration: UInt?
    private var deniedPlayers: Set<NowPlayingStatus.Player> = []
    private var cachedArtworkIdentity: String?
    private var cachedArtwork: Data?
    private var isSleeping = false
    /// The media feature is switched off. Nothing is polled or scripted while this is set.
    private var isSuspended = false
    /// The sources the user lets The Notch show. On the AppleScript path a player left out is
    /// treated as if it were not running, so it is never addressed from AppleScript. Browsers
    /// and other apps only ever come from MediaRemote.
    private var allowedSources = Set(MediaSourceKind.allCases)
    private var allowedPlayers: Set<NowPlayingStatus.Player> {
        Set(Self.playerPreference.filter { allowedSources.contains($0.sourceKind) })
    }

    private var backend: Backend
    private let adapter: MediaRemoteAdapter?
    private var adapterStream: MediaRemoteAdapterStream?
    /// Identifies the current stream, so callbacks from a stopped one are ignored.
    private var adapterStreamToken: UInt = 0
    private var adapterRestarts = 0
    private var adapterRestartTask: Task<Void, Never>?
    /// The latest item the stream reported, kept even while a command owns the UI.
    private var adapterTrack: AdapterTrack?
    private var adapterItemChangedAt = Date.distantPast
    private var lastAdapterItemKey: String?
    private var inactiveDebounceTask: Task<Void, Never>?
    private var artworkGraceTask: Task<Void, Never>?
    private var elapsedTicker: Timer?

    /// These are defensive engineering limits rather than visual tuning, so they stay with
    /// the network boundary instead of becoming design tokens in `Theme`.
    private static let artworkRequestTimeout: TimeInterval = 3
    private static let maximumArtworkByteCount = 4 * 1_024 * 1_024

    /// MediaRemote reports an empty item for a moment whenever the source changes (track to
    /// track, ad to video). Going inactive only after this long keeps the notch from collapsing
    /// and reopening on every change.
    private static let inactiveDebounce: Duration = .milliseconds(300)
    /// A new item's artwork arrives in a later update than its title. The previous artwork is
    /// kept this long rather than flashing an empty tile.
    private static let artworkGrace: TimeInterval = 1.5
    /// MediaRemote does not tick, so the elapsed position is re-derived this often while
    /// something plays. Matches the precision of the `m:ss` label.
    private static let elapsedTickInterval: TimeInterval = 1
    /// After a command completes, the stream's confirming update lands within its 100 ms
    /// debounce. Holding the optimistic value this long keeps it from snapping back first.
    private static let commandSettle: Duration = .milliseconds(400)
    /// Backoff before restarting a stream that exited on its own. After the last one the
    /// monitor gives up on MediaRemote for the session and falls back to AppleScript.
    private static let adapterRestartDelays: [Duration] = [.seconds(1), .seconds(5), .seconds(30)]

    init(runner: AppleScriptRunner = AppleScriptRunner()) {
        self.runner = runner
        isPreview = false
        status = .inactive
        adapter = MediaRemoteAdapter()
        backend = adapter == nil ? .appleScript : .probing
        installWorkspaceObservers()
        if let adapter {
            Task { @MainActor [weak self] in
                let isUsable = await adapter.probe()
                guard let self, backend == .probing else { return }
                backend = isUsable ? .mediaRemote : .appleScript
                reconcilePolling()
            }
        }
        reconcilePolling()
    }

    /// A monitor pinned to a fixed status, for previews and `FrameDump`. It never polls,
    /// never observes the workspace, and never addresses another application.
    init(previewStatus: NowPlayingStatus) {
        runner = AppleScriptRunner()
        isPreview = true
        status = previewStatus
        adapter = nil
        backend = .appleScript
    }

    func playPause() {
        issue(.playPause)
    }

    func nextTrack() {
        issue(.nextTrack)
    }

    func previousTrack() {
        issue(.previousTrack)
    }

    /// `fraction` is 0...1 of the current track's duration.
    func seek(toFraction fraction: Double) {
        guard fraction.isFinite,
              let duration = status.duration,
              duration.isFinite,
              duration > 0
        else { return }

        issue(.seek(seconds: min(max(fraction, 0), 1) * duration))
    }

    isolated deinit {
        timer?.invalidate()
        refreshTask?.cancel()
        elapsedTicker?.invalidate()
        adapterRestartTask?.cancel()
        inactiveDebounceTask?.cancel()
        artworkGraceTask?.cancel()
        adapterStream?.stop()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
    }

    private func issue(_ command: TransportCommand) {
        guard !isPreview else { return }
        if backend == .mediaRemote {
            issueThroughAdapter(command)
            return
        }
        guard let player = controlledPlayer() else { return }

        // A poll already inside `osascript` can return the pre-command state. Give it a stale
        // generation before publishing the optimistic value so it can never snap the UI back.
        refreshGeneration &+= 1
        let commandGeneration = refreshGeneration
        pendingCommandGeneration = commandGeneration
        refreshTask?.cancel()
        refreshTask = nil

        let script = Self.commandScript(command, for: player)
        let runner = runner
        let commandTask = Task.detached(priority: .userInitiated) {
            do {
                _ = try await runner.run(script)
                return CommandOutcome.succeeded
            } catch AppleScriptRunnerError.automationPermissionDenied {
                return CommandOutcome.permissionDenied
            } catch {
                return CommandOutcome.failed
            }
        }

        switch command {
        case .playPause:
            publish(status.withPlaybackState(!status.isPlaying))
        case let .seek(seconds):
            publish(status.withElapsedPosition(seconds))
        case .nextTrack, .previousTrack:
            break
        }

        Task { @MainActor [weak self] in
            let outcome = await commandTask.value
            guard let self else { return }
            if outcome == .permissionDenied {
                deniedPlayers.insert(player)
            }
            guard pendingCommandGeneration == commandGeneration else { return }
            pendingCommandGeneration = nil
            // Even failures reconcile silently: the player's actual state wins, and a denial
            // may expose another eligible player without surfacing an alert.
            reconcilePolling()
        }
    }

    private func controlledPlayer() -> NowPlayingStatus.Player? {
        guard status.isActive,
              let player = status.player,
              eligibleRunningPlayers().contains(player)
        else { return nil }
        return player
    }

    /// Applies the media preferences. Idempotent, so it can run on every settings change.
    func configure(suspended: Bool, allowedSources: Set<MediaSourceKind>) {
        guard suspended != isSuspended || allowedSources != self.allowedSources else { return }
        isSuspended = suspended
        self.allowedSources = allowedSources
        reconcilePolling()
    }

    private func installWorkspaceObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification,
        ]

        workspaceObservers = names.map { name in
            // `Notification` is not `Sendable`, so it cannot cross into the `Task`. Nothing
            // here needs the payload — only which notification fired — and `name` is captured
            // from the loop rather than read back off the notification for the same reason.
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleWorkspaceNotification(named: name)
                }
            }
        }
    }

    private func handleWorkspaceNotification(named name: Notification.Name) {
        switch name {
        case NSWorkspace.willSleepNotification:
            isSleeping = true
            stopPolling()
            stopAdapterStream()
            publish(.inactive)
        case NSWorkspace.didWakeNotification:
            isSleeping = false
            reconcilePolling()
        case NSWorkspace.didLaunchApplicationNotification,
             NSWorkspace.didTerminateApplicationNotification:
            reconcilePolling()
        default:
            break
        }
    }

    /// Process discovery is the gate in front of AppleScript, not merely an optimisation.
    /// Addressing a non-running application from AppleScript can launch it and can surface an
    /// Automation prompt for an interaction the user never requested.
    private func reconcilePolling() {
        guard !isPreview else { return }

        switch backend {
        case .probing:
            return
        case .mediaRemote:
            reconcileAdapter()
            return
        case .appleScript:
            break
        }

        guard !isSleeping, !isSuspended else {
            stopPolling()
            publish(.inactive)
            return
        }

        let players = eligibleRunningPlayers()
        guard !players.isEmpty else {
            stopPolling()
            publish(.inactive)
            return
        }

        installTimerIfNeeded()
        requestRefresh(for: players)
    }

    private func installTimerIfNeeded() {
        guard timer == nil else { return }

        let timer = Timer(
            timeInterval: Theme.Metrics.LiveActivity.pollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcilePolling()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        // Keep the handle until the canceled task reaches its own `defer`. Clearing it here
        // lets a rapid terminate/relaunch start a second refresh, after which the older task
        // can wake from `osascript` and erase the newer handle.
    }

    private func requestRefresh(for players: [NowPlayingStatus.Player]) {
        // A command owns the state until it returns. Polling sooner can observe the player's
        // pre-command value and undo the optimistic response while the command is still in
        // flight.
        guard refreshTask == nil, pendingCommandGeneration == nil else { return }

        let generation = refreshGeneration
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await refresh(players: players, generation: generation)
        }
    }

    private func refresh(players: [NowPlayingStatus.Player], generation: UInt) async {
        defer {
            if generation == refreshGeneration {
                refreshTask = nil
                stopTimerIfNoEligiblePlayerIsRunning()
            }
        }

        var candidates: [ParsedStatus] = []
        for player in players where !Task.isCancelled {
            do {
                let output = try await runner.run(Self.script(for: player))
                if let candidate = Self.parse(output.standardOutput, player: player) {
                    candidates.append(candidate)
                }
            } catch AppleScriptRunnerError.automationPermissionDenied {
                // TCC denial is sticky for the session. Continuing to ask would create a prompt
                // loop and turn an optional status surface into an interruption.
                deniedPlayers.insert(player)
            } catch {
                // Now playing is ambient information. Timeouts, process races, and malformed
                // replies all fail to an invisible idle surface and are retried silently.
            }
        }

        guard !Task.isCancelled, generation == refreshGeneration else { return }
        await publishPreferredStatus(from: candidates, generation: generation)
    }

    private func publishPreferredStatus(
        from candidates: [ParsedStatus],
        generation: UInt
    ) async {
        var remainingCandidates = candidates

        while let candidate = Self.preferredStatus(from: remainingCandidates) {
            do {
                let artwork = try await artwork(for: candidate)
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                publish(candidate.status.withArtwork(artwork))
                return
            } catch AppleScriptRunnerError.automationPermissionDenied {
                // The secondary Music artwork request is still Automation and must inherit
                // the same session-sticky denial behaviour as the main status request.
                deniedPlayers.insert(candidate.player)
                remainingCandidates.removeAll { $0.player == candidate.player }
            } catch {
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                publish(candidate.status.withArtwork(nil))
                return
            }
        }

        guard !Task.isCancelled, generation == refreshGeneration else { return }
        publish(.inactive)
    }

    private func artwork(for candidate: ParsedStatus) async throws -> Data? {
        guard let identity = candidate.status.artworkIdentity else { return nil }
        if cachedArtworkIdentity == identity {
            return cachedArtwork
        }

        let artwork: Data?
        switch candidate.player {
        case .spotify:
            artwork = await Self.spotifyArtwork(from: candidate.spotifyArtworkURL)
        case .music:
            do {
                artwork = try await musicArtwork()
            } catch AppleScriptRunnerError.automationPermissionDenied {
                throw AppleScriptRunnerError.automationPermissionDenied
            } catch {
                // Music raises an AppleScript error for tracks without artwork. That is an
                // ordinary absent value, not a reason to discard the rest of the poll.
                artwork = nil
            }
        case .app:
            // AppleScript never polls other apps; only MediaRemote reports them.
            artwork = nil
        }

        try Task.checkCancellation()
        cachedArtworkIdentity = identity
        cachedArtwork = artwork
        return artwork
    }

    private static func spotifyArtwork(from url: URL?) async -> Data? {
        guard let url, url.scheme?.lowercased() == "https" else { return nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = artworkRequestTimeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            // This is the app's one network call. The URL is supplied by Spotify itself and
            // points at Spotify's artwork CDN; stream it so even a bad response cannot grow
            // beyond the defensive byte cap in memory.
            let (bytes, response) = try await session.bytes(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  response.url?.scheme?.lowercased() == "https",
                  response.expectedContentLength <= Int64(maximumArtworkByteCount)
            else { return nil }

            var data = Data()
            if response.expectedContentLength > 0 {
                data.reserveCapacity(Int(response.expectedContentLength))
            }
            for try await byte in bytes {
                guard data.count < maximumArtworkByteCount else { return nil }
                data.append(byte)
            }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    private func musicArtwork() async throws -> Data? {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("the-notch-music-artwork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pathLiteral = AppleScriptLiteral.string(fileURL.path)
        let script = """
        if application "Music" is running then
            tell application "Music"
                set artworkData to data of artwork 1 of current track
            end tell
            set artworkFile to open for access POSIX file \(pathLiteral) with write permission
            try
                set eof artworkFile to 0
                write artworkData to artworkFile
                close access artworkFile
                return \(pathLiteral)
            on error errorMessage number errorNumber
                try
                    close access artworkFile
                end try
                error errorMessage number errorNumber
            end try
        end if
        return ""
        """

        let output = try await runner.run(script)
        let returnedPath = output.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard returnedPath == fileURL.path else { return nil }

        let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = resourceValues.fileSize,
              fileSize > 0,
              fileSize <= Self.maximumArtworkByteCount
        else { return nil }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumArtworkByteCount + 1) ?? Data()
        guard !data.isEmpty, data.count <= Self.maximumArtworkByteCount else { return nil }
        return data
    }

    private func stopTimerIfNoEligiblePlayerIsRunning() {
        let hasEligiblePlayer = !eligibleRunningPlayers().isEmpty
        guard !hasEligiblePlayer else { return }
        timer?.invalidate()
        timer = nil
    }

    private func publish(_ newStatus: NowPlayingStatus) {
        guard status != newStatus else { return }
        status = newStatus
    }

    private func runningPlayers() -> [NowPlayingStatus.Player] {
        let bundleIdentifiers = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        return Self.playerPreference.filter {
            bundleIdentifiers.contains(Self.bundleIdentifier(for: $0))
        }
    }

    private func eligibleRunningPlayers() -> [NowPlayingStatus.Player] {
        runningPlayers().filter { !deniedPlayers.contains($0) && allowedPlayers.contains($0) }
    }

    private static let playerPreference: [NowPlayingStatus.Player] = [.spotify, .music]

    private static func bundleIdentifier(for player: NowPlayingStatus.Player) -> String {
        switch player {
        case .spotify:
            "com.spotify.client"
        case .music:
            "com.apple.Music"
        case let .app(bundleIdentifier):
            bundleIdentifier
        }
    }

    private static func applicationName(for player: NowPlayingStatus.Player) -> String {
        switch player {
        case .spotify:
            "Spotify"
        case .music:
            "Music"
        case .app:
            // Never scripted: `playerPreference` is the only source of scripted players. An
            // empty name makes any script a no-op (`application "" is running` is false).
            ""
        }
    }

    private static func script(for player: NowPlayingStatus.Player) -> String {
        let applicationName = applicationName(for: player)
        let artworkSetup = switch player {
        case .spotify:
            """
                set artworkURL to ""
                try
                    set artworkURL to artwork url of current track as text
                end try
            """
        case .music, .app:
            ""
        }
        var returnedFields = [
            "(player state as text)",
            "(name of current track as text)",
            "(artist of current track as text)",
            "trackPosition",
            "trackDuration",
        ]
        if player == .spotify {
            returnedFields.append("artworkURL")
        }
        let result = returnedFields.joined(separator: " & (ASCII character 9) & ")
        // Both times are returned as **whole milliseconds**, not as the players' own numbers.
        //
        // `player position` is a real, and `as text` renders a real through the *user's locale*
        // — on an `en_ID` Mac it comes back as `142,753997802734`. `Double(_:)` parses only the
        // C locale, so the position silently became `nil` on every poll and the panel showed
        // `--:--` for the elapsed time while the duration (an integer on Spotify) rendered
        // fine. Multiplying into an integer removes the decimal separator from the wire
        // entirely, which is the only fix that does not depend on the reader's locale.
        //
        // Spotify's `duration` is already milliseconds and every other property here is
        // seconds; scaling each one where it is read is what lets the parser treat both fields
        // identically.
        let durationExpression = switch player {
        case .spotify: "(duration of current track)"
        case .music, .app: "((duration of current track) * 1000)"
        }
        return """
        if application "\(applicationName)" is running then
            tell application "\(applicationName)"
                set trackPosition to ""
                set trackDuration to ""
                try
                    set trackPosition to (((player position) * 1000) as integer) as text
                end try
                try
                    set trackDuration to (\(durationExpression) as integer) as text
                end try
        \(artworkSetup)
                return \(result)
            end tell
        end if
        return ""
        """
    }

    private static func commandScript(
        _ command: TransportCommand,
        for player: NowPlayingStatus.Player
    ) -> String {
        let statement = switch command {
        case .playPause:
            "playpause"
        case .nextTrack:
            "next track"
        case .previousTrack:
            "previous track"
        case let .seek(seconds):
            // Both players accept seconds here. Spotify's duration property is the odd one
            // out: it reports milliseconds and is normalised while parsing the poll response.
            "set player position to \(seconds)"
        }
        let applicationName = applicationName(for: player)
        return """
        if application "\(applicationName)" is running then
            tell application "\(applicationName)"
                \(statement)
            end tell
        end if
        """
    }

    private static func parse(
        _ output: String,
        player: NowPlayingStatus.Player
    ) -> ParsedStatus? {
        let fields = output.components(separatedBy: "\t")
        let expectedFieldCount = player == .spotify ? 6 : 5
        guard fields.count == expectedFieldCount else { return nil }

        let state = fields[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let title = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        // Both fields arrive as whole milliseconds — see `script(for:)` for why.
        let elapsedPosition = finiteNumber(in: fields[3]).map { $0 / 1_000 }
        let duration = finiteNumber(in: fields[4]).map { $0 / 1_000 }
        guard !title.isEmpty, !artist.isEmpty else { return nil }

        let isPlaying: Bool
        switch state {
        case "playing":
            isPlaying = true
        case "paused":
            isPlaying = false
        default:
            return nil
        }

        let artworkURL = player == .spotify
            ? URL(string: fields[5].trimmingCharacters(in: .whitespacesAndNewlines))
            : nil
        return ParsedStatus(
            player: player,
            status: NowPlayingStatus(
                player: player,
                title: title,
                artist: artist,
                isPlaying: isPlaying,
                elapsedPosition: elapsedPosition,
                duration: duration
            ),
            spotifyArtworkURL: artworkURL
        )
    }

    /// Position is optional ambient data, unlike the title and playback state. A player can
    /// return an empty or non-numeric field while changing tracks; preserving the metadata and
    /// drawing an empty bar is less disruptive than dropping the whole live activity.
    /// Belt and braces alongside the integer milliseconds the script now returns: a decimal
    /// comma left by a localised AppleScript reply is normalised before the second attempt, so
    /// a locale can never make a time silently unreadable again.
    private static func finiteNumber(in field: String) -> Double? {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let value = Double(trimmed)
            ?? Double(trimmed.replacingOccurrences(of: ",", with: "."))
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func preferredStatus(from candidates: [ParsedStatus]) -> ParsedStatus? {
        candidates.first(where: { $0.status.isPlaying }) ?? candidates.first
    }
}

// MARK: - MediaRemote backend

extension NowPlayingMonitor {
    private func reconcileAdapter() {
        guard !isSleeping, !isSuspended else {
            stopAdapterStream()
            publish(.inactive)
            return
        }
        startAdapterStreamIfNeeded()
        publishAdapterTrack()
    }

    private func startAdapterStreamIfNeeded() {
        guard adapterStream == nil, adapterRestartTask == nil, let adapter else { return }

        adapterStreamToken &+= 1
        let token = adapterStreamToken
        let stream = adapter.stream(
            onUpdate: { [weak self] track in
                Task { @MainActor [weak self] in
                    self?.receiveAdapterTrack(track, token: token)
                }
            },
            onExit: { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.adapterStreamExited(status: status, token: token)
                }
            }
        )
        guard let stream else {
            adapterStreamExited(status: -1, token: token)
            return
        }
        adapterStream = stream
    }

    private func stopAdapterStream() {
        // A new token first, so the stopped stream's exit callback is ignored.
        adapterStreamToken &+= 1
        adapterStream?.stop()
        adapterStream = nil
        adapterRestartTask?.cancel()
        adapterRestartTask = nil
        adapterTrack = nil
        inactiveDebounceTask?.cancel()
        inactiveDebounceTask = nil
        stopElapsedTicker()
    }

    private func receiveAdapterTrack(_ track: AdapterTrack?, token: UInt) {
        guard token == adapterStreamToken else { return }
        // A stream that delivers data is healthy; only consecutive failures count.
        adapterRestarts = 0

        let itemKey = track.map { "\($0.sourceBundleIdentifier)\u{1F}\($0.itemIdentifier ?? $0.title)" }
        if itemKey != lastAdapterItemKey {
            lastAdapterItemKey = itemKey
            adapterItemChangedAt = Date()
        }
        adapterTrack = track
        publishAdapterTrack()
    }

    private func adapterStreamExited(status: Int32, token: UInt) {
        guard token == adapterStreamToken else { return }
        adapterStream = nil

        guard adapterRestarts < Self.adapterRestartDelays.count else {
            // MediaRemote keeps failing. AppleScript for the rest of the session, as upstream
            // asks: never keep re-invoking a broken adapter.
            backend = .appleScript
            adapterTrack = nil
            stopElapsedTicker()
            publish(.inactive)
            reconcilePolling()
            return
        }

        let delay = Self.adapterRestartDelays[adapterRestarts]
        adapterRestarts += 1
        adapterRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            adapterRestartTask = nil
            reconcilePolling()
        }
    }

    /// Publishes the latest item as a status: filtered by the user's sources, with the elapsed
    /// position extrapolated to now, and with the previous artwork held across an item change.
    private func publishAdapterTrack() {
        // A command owns the UI until it settles; its completion publishes the latest item.
        guard pendingCommandGeneration == nil else { return }

        guard let track = adapterTrack, isAllowed(track.player) else {
            stopElapsedTicker()
            scheduleInactive()
            return
        }

        inactiveDebounceTask?.cancel()
        inactiveDebounceTask = nil

        var newStatus = track.nowPlayingStatus(at: Date())
        if newStatus.artwork == nil,
           status.isActive,
           status.artwork != nil,
           Date().timeIntervalSince(adapterItemChangedAt) < Self.artworkGrace {
            newStatus = newStatus.withArtwork(status.artwork, identity: status.artworkIdentity)
            scheduleArtworkGraceExpiry()
        }
        publish(newStatus)

        if track.isPlaying {
            startElapsedTickerIfNeeded()
        } else {
            stopElapsedTicker()
        }
    }

    private func isAllowed(_ player: NowPlayingStatus.Player) -> Bool {
        allowedSources.contains(player.sourceKind)
    }

    private func scheduleInactive() {
        guard status.isActive, inactiveDebounceTask == nil else { return }
        inactiveDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.inactiveDebounce)
            guard let self, !Task.isCancelled else { return }
            inactiveDebounceTask = nil
            guard pendingCommandGeneration == nil,
                  adapterTrack.map({ !self.isAllowed($0.player) }) ?? true
            else { return }
            publish(.inactive)
        }
    }

    /// Drops held artwork once the grace window ends, if the new item never sent its own.
    private func scheduleArtworkGraceExpiry() {
        guard artworkGraceTask == nil else { return }
        let remaining = max(Self.artworkGrace - Date().timeIntervalSince(adapterItemChangedAt), 0)
        artworkGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard let self, !Task.isCancelled else { return }
            artworkGraceTask = nil
            publishAdapterTrack()
        }
    }

    private func startElapsedTickerIfNeeded() {
        guard elapsedTicker == nil else { return }
        let ticker = Timer(timeInterval: Self.elapsedTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishAdapterTrack()
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        elapsedTicker = ticker
    }

    private func stopElapsedTicker() {
        elapsedTicker?.invalidate()
        elapsedTicker = nil
    }

    private func issueThroughAdapter(_ command: TransportCommand) {
        guard status.isActive, let adapter else { return }

        let adapterCommand: MediaRemoteAdapter.Command = switch command {
        case .playPause: status.isPlaying ? .pause : .play
        case .nextTrack: .nextTrack
        case .previousTrack: .previousTrack
        case let .seek(seconds): .seek(seconds: seconds)
        }

        refreshGeneration &+= 1
        let commandGeneration = refreshGeneration
        pendingCommandGeneration = commandGeneration
        inactiveDebounceTask?.cancel()
        inactiveDebounceTask = nil
        stopElapsedTicker()

        switch command {
        case .playPause:
            // Freeze at the extrapolated position, not the last one-second tick, so pausing
            // does not visibly jump forward when the stream confirms.
            var optimistic = status.withPlaybackState(!status.isPlaying)
            if let elapsed = adapterTrack?.elapsed(at: Date()) {
                optimistic = optimistic.withElapsedPosition(elapsed)
            }
            publish(optimistic)
        case let .seek(seconds):
            publish(status.withElapsedPosition(seconds))
        case .nextTrack, .previousTrack:
            break
        }

        Task { @MainActor [weak self] in
            _ = await adapter.send(adapterCommand)
            try? await Task.sleep(for: Self.commandSettle)
            guard let self, pendingCommandGeneration == commandGeneration else { return }
            pendingCommandGeneration = nil
            // Success or not, the stream's view of the player wins.
            publishAdapterTrack()
        }
    }
}

private extension NowPlayingStatus {
    func withArtwork(_ artwork: Data?, identity: String?) -> NowPlayingStatus {
        guard let player else { return self }
        return NowPlayingStatus(
            player: player,
            title: title,
            artist: artist,
            isPlaying: isPlaying,
            elapsedPosition: elapsedPosition,
            duration: duration,
            artwork: artwork,
            artworkIdentity: identity
        )
    }

    func withArtwork(_ artwork: Data?) -> NowPlayingStatus {
        guard let player else { return self }
        return NowPlayingStatus(
            player: player,
            title: title,
            artist: artist,
            isPlaying: isPlaying,
            elapsedPosition: elapsedPosition,
            duration: duration,
            artwork: artwork,
            artworkIdentity: artworkIdentity
        )
    }

    func withPlaybackState(_ isPlaying: Bool) -> NowPlayingStatus {
        guard let player else { return self }
        return NowPlayingStatus(
            player: player,
            title: title,
            artist: artist,
            isPlaying: isPlaying,
            elapsedPosition: elapsedPosition,
            duration: duration,
            artwork: artwork,
            artworkIdentity: artworkIdentity
        )
    }

    func withElapsedPosition(_ elapsedPosition: TimeInterval) -> NowPlayingStatus {
        guard let player else { return self }
        return NowPlayingStatus(
            player: player,
            title: title,
            artist: artist,
            isPlaying: isPlaying,
            elapsedPosition: elapsedPosition,
            duration: duration,
            artwork: artwork,
            artworkIdentity: artworkIdentity
        )
    }
}
