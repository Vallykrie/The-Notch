import Foundation

nonisolated struct NowPlayingStatus: Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case active
        case inactive
    }

    enum Player: Equatable, Hashable, Sendable {
        case spotify
        case music
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
        artworkIdentity: String? = nil
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
    }

    private static func artworkIdentity(
        player: Player,
        title: String,
        artist: String
    ) -> String {
        let playerIdentity = switch player {
        case .spotify: "spotify"
        case .music: "music"
        }
        return [playerIdentity, title, artist].joined(separator: "\u{1F}")
    }

    static let inactive = NowPlayingStatus(availability: .inactive)
}
