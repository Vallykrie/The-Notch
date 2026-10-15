import Foundation

nonisolated struct NowPlayingStatus: Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case active
        case inactive
    }

    enum Player: Equatable, Hashable, Sendable {
        case spotify
        case music
        /// Any other app holding the system's media controls: a browser playing YouTube,
        /// YouTube Music or Spotify Web, a podcast app, a video player. Only the MediaRemote
        /// path reports these; AppleScript knows only the two players above.
        case app(bundleIdentifier: String)

        init(bundleIdentifier: String) {
            switch bundleIdentifier {
            case "com.spotify.client": self = .spotify
            case "com.apple.Music": self = .music
            default: self = .app(bundleIdentifier: bundleIdentifier)
            }
        }
    }

    /// The player's repeat setting. MediaRemote numbers it 1 off, 2 one, 3 all; AppleScript
    /// reports Spotify's `repeating` as a bool and Music's `song repeat` as off/all/one.
    enum RepeatMode: Equatable, Sendable {
        case off
        case all
        case one

        init?(mediaRemoteValue: Double) {
            switch mediaRemoteValue {
            case 1: self = .off
            case 2: self = .one
            case 3: self = .all
            default: return nil
            }
        }

        /// Spotify's `repeating as text` ("true"/"false") or Music's `song repeat as text`.
        init?(appleScriptValue: String) {
            switch appleScriptValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "false", "off": self = .off
            case "true", "all": self = .all
            case "one": self = .one
            default: return nil
            }
        }

        var mediaRemoteValue: Int {
            switch self {
            case .off: 1
            case .one: 2
            case .all: 3
            }
        }

        /// Off, all, one, off. A player that cannot repeat one track (Spotify's AppleScript
        /// only has a bool) toggles between off and all.
        func next(includingOne: Bool) -> RepeatMode {
            switch self {
            case .off: .all
            case .all: includingOne ? .one : .off
            case .one: .off
            }
        }
    }

    let availability: Availability
    let player: Player?
    let title: String
    let artist: String
    let isPlaying: Bool
    let elapsedPosition: TimeInterval?
    let duration: TimeInterval?
    /// Encoded image bytes (PNG or JPEG) for the current track, or nil when the player did
    /// not supply any.
    let artwork: Data?
    /// Stable identity for that artwork — used for equality and for SwiftUI view identity.
    let artworkIdentity: String?
    /// Nil when the source reports no repeat setting (browsers, most other apps): the control
    /// is drawn disabled rather than guessing.
    let repeatMode: RepeatMode?

    var isActive: Bool {
        availability == .active
    }

    /// Progress stays derived from the two source values so a malformed player reply cannot
    /// leave a stale fraction behind. Players occasionally report a position just outside the
    /// track while changing songs or completing a seek, so a valid ratio is clamped rather
    /// than hidden for that poll.
    var progress: Double? {
        guard let elapsedPosition,
              let duration,
              elapsedPosition.isFinite,
              duration.isFinite,
              duration > 0
        else { return nil }

        return min(max(elapsedPosition / duration, 0), 1)
    }

    init(
        player: Player,
        title: String,
        artist: String,
        isPlaying: Bool,
        elapsedPosition: TimeInterval? = nil,
        duration: TimeInterval? = nil,
        artwork: Data? = nil,
        artworkIdentity: String? = nil,
        repeatMode: RepeatMode? = nil
    ) {
        availability = .active
        self.player = player
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
        self.elapsedPosition = elapsedPosition
        self.duration = duration
        self.artwork = artwork
        self.artworkIdentity = artworkIdentity ?? Self.artworkIdentity(
            player: player,
            title: title,
            artist: artist
        )
        self.repeatMode = repeatMode
    }

    private init(availability: Availability) {
        self.availability = availability
        player = nil
        title = ""
        artist = ""
        isPlaying = false
        elapsedPosition = nil
        duration = nil
        artwork = nil
        artworkIdentity = nil
        repeatMode = nil
    }

    static func == (lhs: NowPlayingStatus, rhs: NowPlayingStatus) -> Bool {
        // Polling republishes this value every two seconds. Synthesised equality would compare
        // hundreds of kilobytes of encoded artwork on every poll, so identity stands in for
        // the bytes while every other semantic field is still compared directly.
        lhs.availability == rhs.availability
            && lhs.player == rhs.player
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.isPlaying == rhs.isPlaying
            && lhs.elapsedPosition == rhs.elapsedPosition
            && lhs.duration == rhs.duration
            && lhs.artworkIdentity == rhs.artworkIdentity
            && lhs.repeatMode == rhs.repeatMode
    }

    private static func artworkIdentity(
        player: Player,
        title: String,
        artist: String
    ) -> String {
        let playerIdentity = switch player {
        case .spotify: "spotify"
        case .music: "music"
        case let .app(bundleIdentifier): bundleIdentifier
        }
        return [playerIdentity, title, artist].joined(separator: "\u{1F}")
    }

    static let inactive = NowPlayingStatus(availability: .inactive)
}
