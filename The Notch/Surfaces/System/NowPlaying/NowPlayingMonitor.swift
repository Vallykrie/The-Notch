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

    /// These are defensive engineering limits rather than visual tuning, so they stay with
    /// the network boundary instead of becoming design tokens in `Theme`.
    private static let artworkRequestTimeout: TimeInterval = 3
    private static let maximumArtworkByteCount = 4 * 1_024 * 1_024

    init(runner: AppleScriptRunner = AppleScriptRunner()) {
        self.runner = runner
        isPreview = false
        status = .inactive
        installWorkspaceObservers()
        reconcilePolling()
    }

    /// A monitor pinned to a fixed status, for previews and `FrameDump`. It never polls,
    /// never observes the workspace, and never addresses another application.
    init(previewStatus: NowPlayingStatus) {
        runner = AppleScriptRunner()
        isPreview = true
        status = previewStatus
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

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
    }

    private func issue(_ command: TransportCommand) {
        guard !isPreview else { return }
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

        guard !isSleeping else {
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
        runningPlayers().filter { !deniedPlayers.contains($0) }
    }

    private static let playerPreference: [NowPlayingStatus.Player] = [.spotify, .music]

    private static func bundleIdentifier(for player: NowPlayingStatus.Player) -> String {
        switch player {
        case .spotify:
            "com.spotify.client"
        case .music:
            "com.apple.Music"
        }
    }

    private static func applicationName(for player: NowPlayingStatus.Player) -> String {
        switch player {
        case .spotify:
            "Spotify"
        case .music:
            "Music"
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
        case .music:
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
        case .music: "((duration of current track) * 1000)"
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

private extension NowPlayingStatus {
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
